// Privacy guard — blocklist, secure field detection, pause hotkey, nightly cleanup.

#![allow(dead_code)]

use std::{
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
};

/// Bundle IDs that must never be captured.
pub const BLOCKED_BUNDLE_IDS: &[&str] = &[
    "com.agilebits.onepassword",
    "com.bitwarden.desktop",
    "com.apple.keychainaccess",
    "com.apple.systempreferences",
    "com.lastpass.lastpassmacdesktop",
    "com.signal.desktop",
    "org.whispersystems.signal-desktop",
    "com.wire.wire-macos",
    "org.telegram.desktop",
];

/// App display names that must never be captured.
pub const BLOCKED_APP_NAMES: &[&str] = &[
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
    "System Preferences",
    "System Settings",
];

pub struct PrivacyGuard {
    paused:         Arc<AtomicBool>,
    data_dir:       PathBuf,
    retention_days: u32,
    /// User-configured blocked app names (from Settings), lowercased.
    extra_blocked:  Vec<String>,
}

impl PrivacyGuard {
    pub fn new(data_dir: PathBuf, retention_days: u32, extra_blocked: Vec<String>) -> Self {
        Self {
            paused: Arc::new(AtomicBool::new(false)),
            data_dir,
            retention_days,
            extra_blocked: extra_blocked.into_iter().map(|s| s.to_lowercase()).filter(|s| !s.is_empty()).collect(),
        }
    }

    /// Returns true when this app/bundle is allowed to be captured.
    pub fn is_allowed(&self, app_name: &str, bundle_id: &str) -> bool {
        if self.is_paused() {
            return false;
        }
        if BLOCKED_BUNDLE_IDS.iter().any(|b| *b == bundle_id) {
            return false;
        }
        if BLOCKED_APP_NAMES.iter().any(|b| app_name.contains(b)) {
            return false;
        }
        let al = app_name.to_lowercase();
        if self.extra_blocked.iter().any(|b| al.contains(b)) {
            return false;
        }
        true
    }

    pub fn pause(&self) {
        self.paused.store(true, Ordering::SeqCst);
    }

    pub fn resume(&self) {
        self.paused.store(false, Ordering::SeqCst);
    }

    pub fn is_paused(&self) -> bool {
        self.paused.load(Ordering::SeqCst)
    }

    /// Delete frames (DB rows) and JPEG files older than retention_days.
    /// Intended to be called from a 24-hour background loop.
    /// Returns the number of DB rows deleted.
    pub async fn run_nightly_cleanup(
        &self,
        db_path: &PathBuf,
    ) -> anyhow::Result<usize> {
        let cutoff = chrono::Utc::now().timestamp()
            - (self.retention_days as i64 * 86_400);

        // ---- DB cleanup (sync, run in spawn_blocking) ----
        let db_path_owned = db_path.clone();
        let deleted = tokio::task::spawn_blocking(move || -> anyhow::Result<usize> {
            let conn = rusqlite::Connection::open(&db_path_owned)?;
            let rows = conn.execute(
                "DELETE FROM frames WHERE timestamp < ?1",
                rusqlite::params![cutoff],
            )?;
            Ok(rows)
        })
        .await??;

        // ---- JPEG file cleanup ----
        let captures_dir = self.data_dir.join("captures");
        if captures_dir.exists() {
            for entry in walkdir::WalkDir::new(&captures_dir)
                .into_iter()
                .filter_map(|e| e.ok())
                .filter(|e| e.file_type().is_file())
            {
                let path = entry.path();
                let ext = path.extension().and_then(|e| e.to_str()).unwrap_or("");
                // Only touch JPEG and compressed JPEG files.
                if ext != "jpg" && ext != "zst" {
                    continue;
                }
                if let Ok(meta) = std::fs::metadata(path) {
                    if let Ok(modified) = meta.modified() {
                        let mtime = modified
                            .duration_since(std::time::UNIX_EPOCH)
                            .unwrap_or_default()
                            .as_secs() as i64;
                        if mtime < cutoff {
                            let _ = std::fs::remove_file(path);
                        }
                    }
                }
            }
        }

        Ok(deleted)
    }

    /// Returns true if the currently focused UI element is a password/secure
    /// text field — meaning we must skip capture.
    #[cfg(target_os = "macos")]
    pub fn is_secure_field_active() -> bool {
        use std::process::Command;

        let script = r#"
tell application "System Events"
    try
        set frontApp to name of first process whose frontmost is true
        tell process frontApp
            set focEl to value of attribute "AXFocusedUIElement" of (first window)
            set elRole to value of attribute "AXRole" of focEl
            if elRole is "AXTextField" then
                set isSecure to value of attribute "AXSecureTextEntry" of focEl
                return isSecure as string
            end if
        end tell
    end try
    return "false"
end tell"#;

        Command::new("osascript")
            .arg("-e")
            .arg(script)
            .output()
            .map(|o| String::from_utf8_lossy(&o.stdout).trim() == "true")
            .unwrap_or(false)
    }

    #[cfg(not(target_os = "macos"))]
    pub fn is_secure_field_active() -> bool {
        false
    }
}
