// Memory daemon — orchestrates capture, context, OCR, session graph, privacy, storage.

#![allow(dead_code, unused_variables, unused_imports)]

use anyhow::Result;
use std::{
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
    time::Duration,
};
use tokio::time::sleep;

use super::{
    capture::ScreenCapturer,
    context::get_app_context,
    privacy::PrivacyGuard,
    session::SessionGraph,
    storage::{StorageConfig, StorageManager},
};
use crate::embeddings::{EmbedRequest, EmbeddingPipeline};
use crate::embed::{EmbedClient, QdrantClient};
use std::sync::Arc as StdArc;

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

pub struct CaptureConfig {
    /// How often to capture while the user is active (default: 5 000 ms).
    pub active_interval_ms: u64,
    /// How often to capture while the user is idle (default: 60 000 ms).
    pub idle_interval_ms: u64,
    /// Days to retain captured frames before nightly cleanup deletes them.
    pub retention_days: u32,
    /// Forward raw JPEGs to StorageManager after OCR (see StorageConfig).
    pub raw_storage: bool,
    /// Extra app names to never capture (from user Settings).
    pub blocked_apps: Vec<String>,
    /// Root output directory — defaults to ~/.cortex.
    pub output_dir: PathBuf,
}

impl Default for CaptureConfig {
    fn default() -> Self {
        Self {
            active_interval_ms: 5_000,
            idle_interval_ms:   60_000,
            retention_days:     30,
            raw_storage:        false,
            blocked_apps:       vec![],
            output_dir:         dirs::home_dir()
                .unwrap_or_default()
                .join(".cortex"),
        }
    }
}

// ---------------------------------------------------------------------------
// Daemon
// ---------------------------------------------------------------------------

pub struct MemoryDaemon {
    config:        CaptureConfig,
    paused:        Arc<AtomicBool>,
    running:       Arc<AtomicBool>,
    session_graph: Arc<SessionGraph>,
    privacy:       Arc<PrivacyGuard>,
    storage:       Arc<StorageManager>,
    capturer:      Arc<ScreenCapturer>,
    embedder:      Arc<EmbeddingPipeline>,
}

impl MemoryDaemon {
    pub fn new(config: CaptureConfig, session_graph: Arc<SessionGraph>) -> Self {
        let privacy = Arc::new(PrivacyGuard::new(
            config.output_dir.clone(),
            config.retention_days,
            config.blocked_apps.clone(),
        ));

        let storage_cfg = StorageConfig {
            raw_storage:  config.raw_storage,
            compress_raw: false,
            data_dir:     config.output_dir.clone(),
            ..Default::default()
        };
        let storage  = Arc::new(StorageManager::new(storage_cfg));
        let capturer = Arc::new(ScreenCapturer::new());
        let embedder = Arc::new(EmbeddingPipeline::new(
            Arc::new(EmbedClient::new()),
            Arc::new(QdrantClient::new()),
        ));

        Self {
            config,
            paused:  Arc::new(AtomicBool::new(false)),
            running: Arc::new(AtomicBool::new(false)),
            session_graph,
            privacy,
            storage,
            capturer,
            embedder,
        }
    }

    // -------------------------------------------------------------------------
    // Control
    // -------------------------------------------------------------------------

    pub fn pause(&self) {
        self.paused.store(true, Ordering::SeqCst);
        self.privacy.pause();
    }

    pub fn resume(&self) {
        self.paused.store(false, Ordering::SeqCst);
        self.privacy.resume();
    }

    /// Replace the user blocklist (Settings) — applies to the next capture tick.
    pub fn set_blocked_apps(&self, apps: Vec<String>) {
        self.privacy.set_extra_blocked(apps);
    }

    pub fn is_paused(&self) -> bool {
        self.paused.load(Ordering::SeqCst)
    }

    pub fn stop(&self) {
        self.running.store(false, Ordering::SeqCst);
    }

    /// Delete frames older than retention_days. Call periodically.
    pub async fn cleanup(&self) -> anyhow::Result<usize> {
        let db = self.config.output_dir.join("sessions/sessions.db");
        self.privacy.run_nightly_cleanup(&db).await
    }

    // -------------------------------------------------------------------------
    // Main loop
    // -------------------------------------------------------------------------

    pub async fn run(&self) -> Result<()> {
        self.running.store(true, Ordering::SeqCst);

        // Ensure the captures directory exists.
        std::fs::create_dir_all(self.config.output_dir.join("captures"))?;
        tracing::info!(target: "aio_cortex_lib", "memory daemon started — capture loop every {}ms (text-only)", self.config.active_interval_ms);

        let mut idle_ticks: u32 = 0;

        while self.running.load(Ordering::SeqCst) {
            // ---- Pause gate ----
            if self.paused.load(Ordering::SeqCst) {
                sleep(Duration::from_millis(500)).await;
                continue;
            }

            // ---- Get frontmost-app context (blocking OS calls) ----
            let ctx = tokio::task::spawn_blocking(get_app_context)
                .await
                .unwrap_or_default();

            // ---- Privacy blocklist check ----
            if !self.privacy.is_allowed(&ctx.app_name, &ctx.bundle_id) {
                sleep(Duration::from_millis(self.config.active_interval_ms)).await;
                continue;
            }

            // ---- Secure field (password input) check ----
            if PrivacyGuard::is_secure_field_active() {
                sleep(Duration::from_millis(self.config.active_interval_ms)).await;
                continue;
            }

            // ---- Quota guard: slow down if over quota ----
            let (_, over_quota) = self.storage.check_quota();
            if over_quota {
                tracing::warn!("cortex: storage quota exceeded — skipping capture");
                sleep(Duration::from_millis(self.config.idle_interval_ms)).await;
                continue;
            }

            // ---- Capture frame (sync, inside spawn_blocking) ----
            let capturer     = self.capturer.clone();
            let app_for_cap  = ctx.app_name.clone();

            let frame_result = tokio::task::spawn_blocking(move || {
                capturer.capture_frame_sync(&app_for_cap)
            })
            .await;

            let frame_opt = match frame_result {
                Ok(Ok(f))  => f,
                Ok(Err(e)) => {
                    tracing::warn!("capture error: {e}");
                    sleep(Duration::from_millis(2_000)).await;
                    continue;
                }
                Err(e) => {
                    tracing::warn!("capture task panicked: {e}");
                    sleep(Duration::from_millis(2_000)).await;
                    continue;
                }
            };

            // The user may have hit the pause hotkey (or switched to a blocked
            // app) while the capture was in flight — drop the frame if so.
            if self.paused.load(Ordering::SeqCst) {
                continue;
            }

            // ---- Session tracking ----
            let (session_id, _is_new) = self
                .session_graph
                .get_or_create_session(&ctx.app_name, &ctx.bundle_id)
                .unwrap_or_else(|_| (uuid::Uuid::new_v4().to_string(), true));

            // ---- Persist frame if one was captured ----
            if let Some(frame) = frame_opt {
                // STORAGE-EFFICIENT: OCR already ran in-memory (frame.ocr_text).
                // We persist only the extracted TEXT + metadata into the session
                // graph — the image bytes are discarded entirely unless the user
                // explicitly opted into raw_storage. So a day of capture costs a
                // few hundred KB of text, not gigabytes of JPEGs.
                match self.session_graph.insert_frame(
                    &session_id, frame.timestamp, &frame.ocr_text,
                    &ctx.app_name, &ctx.window_title, ctx.url.as_deref(),
                ) {
                    Ok(_)  => tracing::debug!(target: "aio_cortex_lib", "memory: frame [{}] {} chars OCR", ctx.app_name, frame.ocr_text.len()),
                    Err(e) => tracing::warn!(target: "aio_cortex_lib", "memory insert_frame: {e}"),
                }
                let _ = self.session_graph.touch_session(
                    &session_id, &ctx.app_name, &ctx.bundle_id, ctx.url.as_deref(),
                );

                // Only touch disk with the image if the user opted into raw storage.
                if self.config.raw_storage {
                    if let Ok(jpeg_path) = self.storage.save_frame(&frame.jpeg_bytes, frame.timestamp) {
                        if let Err(e) = self.storage.post_ocr_cleanup(&jpeg_path) {
                            tracing::warn!("post_ocr_cleanup error: {e}");
                        }
                    }
                }

                // Embed OCR text chunks → Qdrant (fire-and-forget; backs off if down).
                if !frame.ocr_text.is_empty() {
                    let embedder  = self.embedder.clone();
                    let ocr_text  = frame.ocr_text.clone();
                    let item_id   = format!("frame:{}", frame.timestamp);
                    let app_name  = ctx.app_name.clone();
                    let ts        = frame.timestamp;
                    tokio::spawn(async move {
                        embedder.index_chunked(&item_id, &ocr_text, "screen_frame", &app_name, ts).await;
                    });
                }

                idle_ticks = 0;
            } else {
                // Frame was a duplicate (same dHash) or blocked app → increment idle.
                idle_ticks = idle_ticks.saturating_add(1);
            }

            // ---- Adaptive sleep ----
            // >6 skipped ticks (~30 s at 5 s interval) → switch to idle rate.
            let interval_ms = if idle_ticks > 6 {
                self.config.idle_interval_ms
            } else {
                self.config.active_interval_ms
            };
            sleep(Duration::from_millis(interval_ms)).await;
        }

        Ok(())
    }
}
