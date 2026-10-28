// daemon/context.rs
// Active app context detector: name, bundle ID, window title, browser URL.
//
// Platform coverage:
//   macOS  — osascript (AppleScript) for all fields; URL for major browsers.
//   Linux  — xdotool for window info; no URL extraction.
//   Windows — stub (returns default); WinAPI wiring is future work.

#![allow(dead_code)]

use serde::{Deserialize, Serialize};

// ---------------------------------------------------------------------------
// Public type
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct AppContext {
    /// Human-readable application name, e.g. "Google Chrome".
    pub app_name: String,
    /// macOS bundle identifier, e.g. "com.google.Chrome". Empty on other platforms.
    pub bundle_id: String,
    /// Title of the frontmost/active window.
    pub window_title: String,
    /// Active URL for recognised browser apps; `None` for non-browser apps.
    pub url: Option<String>,
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Return context about the currently-focused application.
/// Never panics; returns `AppContext::default()` on any error.
pub fn get_app_context() -> AppContext {
    platform_get_app_context()
}

// ---------------------------------------------------------------------------
// macOS implementation
// ---------------------------------------------------------------------------

#[cfg(target_os = "macos")]
fn platform_get_app_context() -> AppContext {
    // Frontmost application name.
    let app_name = run_osascript(
        r#"tell application "System Events" to get name of first process whose frontmost is true"#,
    )
    .unwrap_or_default();

    if app_name.is_empty() {
        return AppContext::default();
    }

    // Bundle identifier (best-effort — some apps may not respond).
    let bundle_id = run_osascript(&format!(r#"id of application "{}""#, app_name))
        .unwrap_or_default();

    // Front window title (best-effort — some sandboxed apps refuse).
    let window_title = run_osascript(&format!(
        r#"tell application "{}" to get name of front window"#,
        app_name
    ))
    .unwrap_or_default();

    // Browser URL extraction — only for known Chromium/WebKit/Gecko apps.
    let url = extract_browser_url(&app_name);

    AppContext {
        app_name,
        bundle_id,
        window_title,
        url,
    }
}

/// Extract the active tab URL for known browser applications.
#[cfg(target_os = "macos")]
fn extract_browser_url(app_name: &str) -> Option<String> {
    match app_name {
        // Chromium-based: Chrome, Chromium, Brave, Arc, Edge, Cursor (embedded CEF).
        "Google Chrome"
        | "Chromium"
        | "Brave Browser"
        | "Microsoft Edge"
        | "Arc"
        | "Cursor" => {
            // Arc uses Chrome's AppleScript dictionary under the hood.
            let chrome_script = format!(
                r#"tell application "{}" to get URL of active tab of first window"#,
                // Arc needs its own bundle name for the tell block.
                if app_name == "Arc" { "Arc" } else { app_name }
            );
            run_osascript(&chrome_script).ok()
        }

        "Safari" | "Safari Technology Preview" => {
            run_osascript(r#"tell application "Safari" to get URL of front document"#).ok()
        }

        "Firefox" | "Firefox Developer Edition" | "Firefox Nightly" => {
            // Firefox AppleScript support is limited; URL access requires
            // the browser to expose it — works in standard Firefox builds.
            run_osascript(&format!(
                r#"tell application "{}" to get URL of active tab of first window"#,
                app_name
            ))
            .ok()
        }

        _ => None,
    }
}

/// Run an AppleScript one-liner and return trimmed stdout.
/// Returns `Err` if the process exits non-zero or the command cannot be spawned.
#[cfg(target_os = "macos")]
fn run_osascript(script: &str) -> anyhow::Result<String> {
    let out = std::process::Command::new("osascript")
        .arg("-e")
        .arg(script)
        .output()?;

    if out.status.success() {
        Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
    } else {
        Err(anyhow::anyhow!(
            "osascript failed ({}): {}",
            out.status,
            String::from_utf8_lossy(&out.stderr).trim()
        ))
    }
}

// ---------------------------------------------------------------------------
// Linux implementation
// ---------------------------------------------------------------------------

#[cfg(target_os = "linux")]
fn platform_get_app_context() -> AppContext {
    // Active X11 window ID.
    let window_id = run_cmd("xdotool", &["getactivewindow"]).unwrap_or_default();

    if window_id.is_empty() {
        return AppContext::default();
    }

    let window_title =
        run_cmd("xdotool", &["getwindowname", &window_id]).unwrap_or_default();

    // Process ID for the window owner.
    let pid = run_cmd("xdotool", &["getwindowpid", &window_id]).unwrap_or_default();

    // Executable name from the PID (ps -p <pid> -o comm=).
    let app_name = if pid.is_empty() {
        String::new()
    } else {
        run_cmd("ps", &["-p", &pid, "-o", "comm="]).unwrap_or_default()
    };

    // URL extraction on Linux would require native messaging or D-Bus — not yet wired.
    AppContext {
        app_name,
        bundle_id: String::new(),
        window_title,
        url: None,
    }
}

// ---------------------------------------------------------------------------
// Windows stub
// ---------------------------------------------------------------------------

#[cfg(target_os = "windows")]
fn platform_get_app_context() -> AppContext {
    // Full implementation would use GetForegroundWindow + GetWindowText via winapi/windows crate.
    // Returning default here; the rest of the pipeline still functions without context.
    AppContext::default()
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

/// Run an external command with the given arguments and return trimmed stdout.
/// Used by the Linux implementation; compiled on all platforms to avoid cfg sprawl.
fn run_cmd(program: &str, args: &[&str]) -> anyhow::Result<String> {
    let out = std::process::Command::new(program).args(args).output()?;
    Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_context_is_empty() {
        let ctx = AppContext::default();
        assert!(ctx.app_name.is_empty());
        assert!(ctx.bundle_id.is_empty());
        assert!(ctx.window_title.is_empty());
        assert!(ctx.url.is_none());
    }

    #[test]
    fn serialize_roundtrip() {
        let ctx = AppContext {
            app_name: "Safari".to_string(),
            bundle_id: "com.apple.Safari".to_string(),
            window_title: "Example – Docs".to_string(),
            url: Some("https://example.com".to_string()),
        };
        let json = serde_json::to_string(&ctx).unwrap();
        let back: AppContext = serde_json::from_str(&json).unwrap();
        assert_eq!(back.app_name, "Safari");
        assert_eq!(back.url.as_deref(), Some("https://example.com"));
    }
}
