// Storage manager — quota enforcement, optional zstd compression, JPEG lifecycle.

#![allow(dead_code)]

use anyhow::Result;
use chrono::{DateTime, Utc};
use std::path::PathBuf;

pub const DEFAULT_QUOTA_BYTES: u64 = 5 * 1024 * 1024 * 1024; // 5 GB

pub struct StorageConfig {
    /// Keep JPEG bytes on disk after OCR completes.
    pub raw_storage:  bool,
    /// zstd-compress the JPEG when raw_storage = true.
    pub compress_raw: bool,
    pub quota_bytes:  u64,
    pub data_dir:     PathBuf,
}

impl Default for StorageConfig {
    fn default() -> Self {
        Self {
            raw_storage:  false,
            compress_raw: false,
            quota_bytes:  DEFAULT_QUOTA_BYTES,
            data_dir:     dirs::home_dir()
                .unwrap_or_default()
                .join(".cortex"),
        }
    }
}

pub struct StorageManager {
    config: StorageConfig,
}

impl StorageManager {
    pub fn new(config: StorageConfig) -> Self {
        Self { config }
    }

    /// Called after OCR has completed on a captured JPEG.
    ///
    /// Behaviour driven by config:
    /// - raw_storage = false → delete the JPEG.
    /// - raw_storage = true, compress_raw = true → zstd-compress in place (.jpg.zst).
    /// - raw_storage = true, compress_raw = false → keep JPEG as-is.
    pub fn post_ocr_cleanup(&self, jpeg_path: &PathBuf) -> Result<()> {
        if !jpeg_path.exists() {
            return Ok(());
        }

        if !self.config.raw_storage {
            std::fs::remove_file(jpeg_path)?;
            return Ok(());
        }

        if self.config.compress_raw {
            // requires: zstd = "0.13"
            let data = std::fs::read(jpeg_path)?;
            let compressed = zstd::encode_all(std::io::Cursor::new(data), 3)?;

            let new_path = jpeg_path.with_extension("jpg.zst");
            std::fs::write(&new_path, compressed)?;
            std::fs::remove_file(jpeg_path)?;
        }
        // else: raw_storage=true, compress_raw=false → do nothing (keep as-is).

        Ok(())
    }

    /// Check disk usage.  Returns (used_bytes, over_quota).
    pub fn check_quota(&self) -> (u64, bool) {
        let used = self.used_bytes();
        (used, used > self.config.quota_bytes)
    }

    /// Persist raw JPEG bytes to `data_dir/captures/YYYY-MM-DD/HH-MM-SS-{ts}.jpg`.
    /// Creates directories as needed.  Returns the path written.
    pub fn save_frame(&self, jpeg_bytes: &[u8], timestamp: i64) -> Result<PathBuf> {
        let dt: DateTime<Utc> =
            DateTime::from_timestamp(timestamp, 0).unwrap_or_else(Utc::now);

        let date_dir = self
            .config
            .data_dir
            .join("captures")
            .join(dt.format("%Y-%m-%d").to_string());

        std::fs::create_dir_all(&date_dir)?;

        let filename = format!("{}-{}.jpg", dt.format("%H-%M-%S"), timestamp);
        let path = date_dir.join(filename);
        std::fs::write(&path, jpeg_bytes)?;
        Ok(path)
    }

    /// Walk data_dir and sum file sizes.
    pub fn used_bytes(&self) -> u64 {
        walkdir::WalkDir::new(&self.config.data_dir)
            .into_iter()
            .filter_map(|e| e.ok())
            .filter(|e| e.file_type().is_file())
            .filter_map(|e| e.metadata().ok())
            .map(|m| m.len())
            .sum()
    }
}
