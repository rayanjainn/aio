// daemon/capture.rs
// Full-screen capture pipeline with dHash dedup, adaptive rate, and OCR.
//
// requires: screenshots = "0.8"
// requires: image = "0.25" (with jpeg feature)

#![allow(dead_code)]

use anyhow::Result;
use chrono::Utc;
use image::DynamicImage;
use std::{
    io::Cursor,
    sync::Arc,
    time::{Duration, Instant},
};
use tokio::sync::Mutex;

// Apps whose captures are discarded before storage.
// Mirrors the BLOCKED_APPS list in memory.rs — keep in sync.
const BLOCKED_APPS: &[&str] = &[
    "cortex",            // never capture our own window — it pollutes memory
    "aio-cortex",        // dev process name
    "1Password",
    "Bitwarden",
    "Keychain Access",
    "LastPass",
    "Signal",
    "Wire",
    "Telegram",
    "WhatsApp",
    "Revolut",
    "Monzo",
    "Chase",
    "PayPal",
    "com.apple.keychainaccess",
];

/// Threshold below which two frames are considered duplicates (>90% similar).
const DHASH_SIMILARITY_THRESHOLD: u32 = 7;

/// Idle timeout: if no context change detected for this long, switch to slow poll.
const IDLE_TIMEOUT_SECS: u64 = 30;

/// Active poll interval.
const ACTIVE_INTERVAL_SECS: u64 = 5;

/// Idle poll interval.
const IDLE_INTERVAL_SECS: u64 = 60;

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

#[derive(Debug)]
pub struct FrameCapture {
    pub timestamp: i64,
    pub jpeg_bytes: Vec<u8>,
    pub ocr_text: String,
    pub app_name: String,
    pub window_title: String,
    pub url: Option<String>,
    pub dhash: u64,
}

pub struct ScreenCapturer {
    last_hash: Arc<Mutex<Option<u64>>>,
    /// Instant of the last detected context change (new app / new window).
    last_activity: Arc<Mutex<Instant>>,
}

impl ScreenCapturer {
    pub fn new() -> Self {
        Self {
            last_hash: Arc::new(Mutex::new(None)),
            last_activity: Arc::new(Mutex::new(Instant::now())),
        }
    }

    /// How long to sleep before the next capture attempt.
    pub async fn next_sleep(&self) -> Duration {
        let last = self.last_activity.lock().await;
        if last.elapsed().as_secs() > IDLE_TIMEOUT_SECS {
            Duration::from_secs(IDLE_INTERVAL_SECS)
        } else {
            Duration::from_secs(ACTIVE_INTERVAL_SECS)
        }
    }

    /// Capture the primary screen.
    ///
    /// Returns `None` when:
    /// - the active app is on the blocklist
    /// - the frame is perceptually identical to the previous one (hamming < threshold)
    /// - screen capture fails
    pub async fn capture_frame(&self, app_name: &str) -> Result<Option<FrameCapture>> {
        // Blocklist check — must happen before any pixel read.
        let app_lc = app_name.to_lowercase();
        if BLOCKED_APPS.iter().any(|b| app_lc.contains(&b.to_lowercase())) {
            return Ok(None);
        }

        // Grab the primary screen using the `screenshots` crate.
        let img = capture_primary_screen()?;

        let hash = dhash(&img);

        // Dedup: skip frames that are almost identical to the last one.
        {
            let mut last = self.last_hash.lock().await;
            if let Some(prev) = *last {
                if hamming(hash, prev) < DHASH_SIMILARITY_THRESHOLD {
                    return Ok(None);
                }
            }
            *last = Some(hash);
        }

        let jpeg_bytes = encode_jpeg(&img)?;
        let ocr_text = ocr_jpeg(&jpeg_bytes);

        let timestamp = Utc::now().timestamp();

        Ok(Some(FrameCapture {
            timestamp,
            jpeg_bytes,
            ocr_text,
            app_name: app_name.to_string(),
            window_title: String::new(), // caller fills from context::get_app_context()
            url: None,                   // caller fills from context::get_app_context()
            dhash: hash,
        }))
    }

    /// Synchronous version of capture_frame for use inside tokio::task::spawn_blocking.
    ///
    /// Behaviorally identical to capture_frame but does not require an async runtime.
    /// Uses a separate std::sync::Mutex for the last-hash state so it can be called
    /// from a blocking thread pool worker.
    pub fn capture_frame_sync(&self, app_name: &str) -> Result<Option<FrameCapture>> {
        // Blocklist check — must happen before any pixel read.
        let app_lc = app_name.to_lowercase();
        if BLOCKED_APPS.iter().any(|b| app_lc.contains(&b.to_lowercase())) {
            return Ok(None);
        }

        let img  = capture_primary_screen()?;
        let hash = dhash(&img);

        // Use blocking_lock so we can call from a sync context.
        {
            let mut last = self.last_hash.blocking_lock();
            if let Some(prev) = *last {
                if hamming(hash, prev) < DHASH_SIMILARITY_THRESHOLD {
                    return Ok(None);
                }
            }
            *last = Some(hash);
        }

        let jpeg_bytes = encode_jpeg(&img)?;
        let ocr_text   = ocr_jpeg(&jpeg_bytes);
        let timestamp  = Utc::now().timestamp();

        Ok(Some(FrameCapture {
            timestamp,
            jpeg_bytes,
            ocr_text,
            app_name:     app_name.to_string(),
            window_title: String::new(),
            url:          None,
            dhash:        hash,
        }))
    }

    /// Signal that user-detectable context has changed (resets idle timer).
    pub async fn mark_activity(&self) {
        let mut last = self.last_activity.lock().await;
        *last = Instant::now();
    }
}

// ---------------------------------------------------------------------------
// Screen grab
// ---------------------------------------------------------------------------

/// Capture the first/primary screen and return a `DynamicImage`.
/// Uses the `screenshots` crate (requires: screenshots = "0.8").
///
/// `screenshots::Screen::capture()` returns an
/// `ImageBuffer<Rgba<u8>, Vec<u8>>` (via the crate's own re-export of
/// `image`). We convert it to our own `DynamicImage` by transferring the raw
/// RGBA bytes — no PNG round-trip needed.
fn capture_primary_screen() -> Result<DynamicImage> {
    // macOS: the `screenshots` crate (CGDisplayCreateImage) is deprecated and
    // returns nothing on macOS 14+. The built-in `screencapture` CLI uses the
    // modern ScreenCaptureKit path and reliably honours the Screen-Recording
    // permission — so we shell out to it (silent, no shutter sound).
    #[cfg(target_os = "macos")]
    {
        use std::process::Command;
        let tmp = std::env::temp_dir().join("cortex_capture.jpg");
        let _ = std::fs::remove_file(&tmp);
        let status = Command::new("screencapture")
            .args(["-x", "-t", "jpg", "-m"]) // -x silent, -m main display only
            .arg(&tmp)
            .status()
            .map_err(|e| anyhow::anyhow!("screencapture spawn: {e}"))?;
        if !status.success() || !tmp.exists() {
            anyhow::bail!("screencapture failed (screen-recording permission?)");
        }
        let img = image::open(&tmp).map_err(|e| anyhow::anyhow!("decode capture: {e}"))?;
        return Ok(img);
    }

    #[cfg(not(target_os = "macos"))]
    {
        use screenshots::Screen;
        let screens = Screen::all().unwrap_or_default();
        let screen = screens.into_iter().next().ok_or_else(|| anyhow::anyhow!("no screens found"))?;
        let raw = screen.capture()?;
        let (width, height) = raw.dimensions();
        let rgba_bytes: Vec<u8> = raw.into_raw();
        let rgba_image = image::RgbaImage::from_raw(width, height, rgba_bytes)
            .ok_or_else(|| anyhow::anyhow!("failed to construct RgbaImage"))?;
        Ok(DynamicImage::ImageRgba8(rgba_image))
    }
}

// ---------------------------------------------------------------------------
// dHash
// ---------------------------------------------------------------------------

/// Difference hash — resize to 9×8 grayscale, compare each pixel to its
/// right neighbour. Produces a 64-bit fingerprint.
fn dhash(img: &DynamicImage) -> u64 {
    use image::imageops::FilterType;

    // 9 columns × 8 rows so we get 8 differences per row = 64 bits.
    let small = img.resize_exact(9, 8, FilterType::Triangle).to_luma8();

    let mut hash: u64 = 0;
    let mut bit: u64 = 1;

    for row in 0..8u32 {
        for col in 0..8u32 {
            let left = small.get_pixel(col, row)[0];
            let right = small.get_pixel(col + 1, row)[0];
            if left > right {
                hash |= bit;
            }
            bit <<= 1;
        }
    }

    hash
}

/// Hamming distance between two 64-bit hashes.
fn hamming(a: u64, b: u64) -> u32 {
    (a ^ b).count_ones()
}

// ---------------------------------------------------------------------------
// JPEG encoding
// ---------------------------------------------------------------------------

/// Encode a `DynamicImage` to JPEG at quality 75, returning raw bytes.
fn encode_jpeg(img: &DynamicImage) -> Result<Vec<u8>> {
    let mut buf = Cursor::new(Vec::new());
    let mut encoder =
        image::codecs::jpeg::JpegEncoder::new_with_quality(&mut buf, 75);
    encoder.encode_image(img)?;
    Ok(buf.into_inner())
}

// ---------------------------------------------------------------------------
// OCR — platform-specific
// ---------------------------------------------------------------------------

/// Extract text from JPEG bytes using the best available OCR backend.
/// Always returns a `String`; returns empty string on any error.
pub fn ocr_jpeg(jpeg_bytes: &[u8]) -> String {
    ocr_impl(jpeg_bytes)
}

/// Vision OCR helper, compiled ONCE into ~/.cortex/ocrhelper and reused per
/// frame. Compiling `swift -` on every 5s capture was slow + CPU-heavy; a
/// cached binary runs each frame in ~100-300ms.
#[cfg(target_os = "macos")]
fn ocr_helper() -> Option<std::path::PathBuf> {
    use std::sync::OnceLock;
    static HELPER: OnceLock<Option<std::path::PathBuf>> = OnceLock::new();
    HELPER.get_or_init(|| {
        let dir = dirs::home_dir()?.join(".cortex");
        let _ = std::fs::create_dir_all(&dir);
        let bin = dir.join("ocrhelper");
        if bin.exists() { return Some(bin); }
        let src = dir.join("ocrhelper.swift");
        let code = r#"import Vision
import Foundation
let args = CommandLine.arguments
guard args.count >= 2 else { exit(2) }
let url = URL(fileURLWithPath: args[1])
let handler = VNImageRequestHandler(url: url, options: [:])
var collected = [String]()
let req = VNRecognizeTextRequest { request, error in
    guard let obs = request.results as? [VNRecognizedTextObservation] else { return }
    for o in obs { if let t = o.topCandidates(1).first { collected.append(t.string) } }
}
req.recognitionLevel = .accurate
req.usesLanguageCorrection = true
try? handler.perform([req])
print(collected.joined(separator: "\n"))
"#;
        std::fs::write(&src, code).ok()?;
        let ok = std::process::Command::new("swiftc")
            .args(["-O"]).arg(&src).args(["-o"]).arg(&bin)
            .output().map(|o| o.status.success()).unwrap_or(false);
        if ok && bin.exists() {
            tracing::info!(target: "aio_cortex_lib", "OCR helper compiled");
            Some(bin)
        } else {
            tracing::warn!(target: "aio_cortex_lib", "OCR helper compile failed");
            None
        }
    }).clone()
}

#[cfg(target_os = "macos")]
fn ocr_impl(jpeg_bytes: &[u8]) -> String {
    use std::process::Command;
    let tmp_path = std::env::temp_dir().join("cortex_ocr.jpg");
    if std::fs::write(&tmp_path, jpeg_bytes).is_err() { return String::new(); }
    let Some(helper) = ocr_helper() else { return String::new() };
    match Command::new(&helper).arg(&tmp_path).output() {
        Ok(out) if out.status.success() => String::from_utf8_lossy(&out.stdout).trim().to_string(),
        _ => String::new(),
    }
}

#[cfg(target_os = "linux")]
fn ocr_impl(jpeg_bytes: &[u8]) -> String {
    // Primary path: leptess (Tesseract FFI) when the "ocr" feature is enabled.
    // Fallback: empty string — caller can still store the JPEG for later processing.
    #[cfg(feature = "ocr")]
    {
        // leptess::LepTess::new returns Result; handle gracefully.
        let mut lt = match leptess::LepTess::new(None, "eng") {
            Ok(lt) => lt,
            Err(_) => return String::new(),
        };
        if lt.set_image_from_mem(jpeg_bytes).is_err() {
            return String::new();
        }
        lt.get_utf8_text().unwrap_or_default()
    }
    #[cfg(not(feature = "ocr"))]
    {
        // Silence the unused-variable warning in non-ocr builds.
        let _ = jpeg_bytes;
        String::new()
    }
}

#[cfg(target_os = "windows")]
fn ocr_impl(jpeg_bytes: &[u8]) -> String {
    // Windows OCR via Windows.Media.Ocr is not yet wired up.
    // Stub returns empty string; the JPEG is still stored for future processing.
    let _ = jpeg_bytes;
    String::new()
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hamming_identical() {
        assert_eq!(hamming(0xDEADBEEF, 0xDEADBEEF), 0);
    }

    #[test]
    fn hamming_complement() {
        assert_eq!(hamming(0u64, !0u64), 64);
    }

    #[test]
    fn dhash_produces_64_bits() {
        // Solid black 18×16 image — all comparisons equal → hash 0.
        let img = DynamicImage::new_luma8(18, 16);
        let h = dhash(&img);
        assert_eq!(h, 0);
    }

    #[test]
    fn encode_jpeg_roundtrip() {
        let img = DynamicImage::new_rgb8(64, 64);
        let bytes = encode_jpeg(&img).expect("encode failed");
        // JPEG magic bytes: FF D8 FF
        assert_eq!(&bytes[..3], &[0xFF, 0xD8, 0xFF]);
    }
}
