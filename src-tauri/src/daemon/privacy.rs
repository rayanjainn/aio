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
        if BLOCKED_BUNDLE_IDS.iter().any(|b| b.eq_ignore_ascii_case(bundle_id)) {
            return false;
        }
        let al = app_name.to_lowercase();
        if BLOCKED_APP_NAMES.iter().any(|b| al.contains(&b.to_lowercase())) {
            return false;
        }
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

    /// Returns true if a password/secure text field is focused — meaning we
    /// must skip capture.
    ///
    /// Two signals, either one blocks capture:
    ///   1. `IsSecureEventInputEnabled()` — the system-wide flag macOS raises
    ///      whenever any secure text field (or terminal "Secure Keyboard Entry")
    ///      has focus. Needs no Accessibility permission and is authoritative.
    ///   2. Accessibility: focused element's subrole is `AXSecureTextField`.
    ///      (The old check read a non-existent `AXSecureTextEntry` attribute off
    ///      the window instead of the app, so it never fired.)
    #[cfg(target_os = "macos")]
    pub fn is_secure_field_active() -> bool {
        use std::process::Command;

        #[link(name = "Carbon", kind = "framework")]
        extern "C" {
            fn IsSecureEventInputEnabled() -> u8;
        }
        // SAFETY: argument-less Carbon query, thread-safe, no pointers involved.
        if unsafe { IsSecureEventInputEnabled() } != 0 {
            return true;
        }

        let script = r#"
tell application "System Events"
    try
        set frontApp to first application process whose frontmost is true
        set focEl to value of attribute "AXFocusedUIElement" of frontApp
        if (value of attribute "AXSubrole" of focEl) is "AXSecureTextField" then return "true"
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

#[cfg(test)]
mod tests {
    use super::*;

    fn guard(extra: &[&str]) -> PrivacyGuard {
        PrivacyGuard::new(std::env::temp_dir(), 30, extra.iter().map(|s| s.to_string()).collect())
    }

    #[test]
    fn builtin_names_blocked_case_insensitively() {
        let g = guard(&[]);
        assert!(!g.is_allowed("1Password 7", ""));
        assert!(!g.is_allowed("signal", ""));
        assert!(!g.is_allowed("SYSTEM SETTINGS", ""));
        assert!(g.is_allowed("Safari", "com.apple.Safari"));
    }

    #[test]
    fn builtin_bundle_ids_blocked() {
        let g = guard(&[]);
        assert!(!g.is_allowed("Whatever", "com.agilebits.onepassword"));
        assert!(!g.is_allowed("Whatever", "COM.BITWARDEN.DESKTOP"));
    }

    #[test]
    fn user_blocklist_applies() {
        let g = guard(&["Banking App", ""]);
        assert!(!g.is_allowed("My Banking App", ""));
        assert!(g.is_allowed("Notes", ""));
    }

    #[test]
    fn pause_blocks_everything() {
        let g = guard(&[]);
        g.pause();
        assert!(!g.is_allowed("Safari", ""));
        g.resume();
        assert!(g.is_allowed("Safari", ""));
    }
}
