//! macOS Automation (Apple Events) plumbing.
//!
//! Everything that talks to other apps (Music, Spotify, browsers) goes through
//! AppleScript, which macOS gates behind the Automation permission. Three
//! things have to be true for that to work, all of which v0.2.0 got wrong:
//!   1. `NSAppleEventsUsageDescription` in Info.plist (present),
//!   2. the app is not signed with the hardened runtime *without* the
//!      `com.apple.security.automation.apple-events` entitlement — otherwise
//!      macOS answers -1743 and never shows a prompt (fixed in tauri.conf.json
//!      + Entitlements.plist),
//!   3. the target app is installed — a script that names an app that isn't
//!      there fails to compile (or shows a "Choose Application" dialog), so each
//!      player gets its own script and is only scripted while it is running.
//!
//! `AEDeterminePermissionToAutomateTarget` lets us ask "may I control X?" and
//! trigger the system prompt deliberately instead of guessing from script errors.

use serde::Serialize;

pub const MUSIC: &str = "com.apple.Music";
pub const SPOTIFY: &str = "com.spotify.client";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Permission {
    /// Allowed.
    Ok,
    /// The user said no (or it was never granted and macOS won't ask again).
    Denied,
    /// Not decided yet — macOS will prompt on first use.
    Ask,
    /// Target app isn't running, so macOS can't tell.
    NotRunning,
    Unknown,
}

impl Permission {
    pub fn from_status(code: i32) -> Self {
        match code {
            0 => Permission::Ok,
            -1743 => Permission::Denied,
            -1744 => Permission::Ask,
            -600 => Permission::NotRunning,
            _ => Permission::Unknown,
        }
    }
}

/// Is an app with this bundle id running? (NSWorkspace — microseconds, no permissions.)
pub fn is_running(bundle_id: &str) -> bool {
    #[cfg(target_os = "macos")]
    {
        use objc2_app_kit::NSWorkspace;
        let ws = NSWorkspace::sharedWorkspace();
        return ws.runningApplications().iter().any(|a| {
            a.bundleIdentifier().map(|b| b.to_string() == bundle_id).unwrap_or(false)
        });
    }
    #[allow(unreachable_code)]
    { let _ = bundle_id; false }
}

/// Permission to send Apple Events to `bundle_id`. With `ask`, macOS shows its
/// consent dialog now (blocks until answered) if the decision is still open.
pub fn permission(bundle_id: &str, ask: bool) -> Permission {
    #[cfg(target_os = "macos")]
    { return Permission::from_status(ae::determine(bundle_id, ask)); }
    #[allow(unreachable_code)]
    { let _ = (bundle_id, ask); Permission::Unknown }
}

#[cfg(target_os = "macos")]
mod ae {
    use std::ffi::c_void;

    #[repr(C)]
    struct AEDesc { descriptor_type: u32, data_handle: *mut c_void }

    #[link(name = "CoreServices", kind = "framework")]
    extern "C" {
        fn AECreateDesc(type_code: u32, data_ptr: *const c_void, data_size: isize, result: *mut AEDesc) -> i16;
        fn AEDisposeDesc(desc: *mut AEDesc) -> i16;
        fn AEDeterminePermissionToAutomateTarget(target: *const AEDesc, event_class: u32, event_id: u32, ask_user_if_needed: u8) -> i32;
    }

    const TYPE_APPLICATION_BUNDLE_ID: u32 = u32::from_be_bytes(*b"bund");
    const TYPE_WILD_CARD: u32 = u32::from_be_bytes(*b"****");

    /// Raw OSStatus: 0 allowed, -1743 denied, -1744 would need consent, -600 not running.
    pub fn determine(bundle_id: &str, ask: bool) -> i32 {
        let mut desc = AEDesc { descriptor_type: 0, data_handle: std::ptr::null_mut() };
        // SAFETY: `desc` is a valid out-pointer; the bundle id bytes outlive the call
        // (AECreateDesc copies them); the descriptor is disposed on every path.
        unsafe {
            let err = AECreateDesc(TYPE_APPLICATION_BUNDLE_ID, bundle_id.as_ptr() as *const c_void, bundle_id.len() as isize, &mut desc);
            if err != 0 { return err as i32; }
            let status = AEDeterminePermissionToAutomateTarget(&desc, TYPE_WILD_CARD, TYPE_WILD_CARD, ask as u8);
            AEDisposeDesc(&mut desc);
            status
        }
    }
}

/* ─── IPC ───────────────────────────────────────────────── */

/// Current Automation permission for a target app (never prompts).
#[tauri::command]
pub async fn automation_status(bundle: String) -> Permission {
    tokio::task::spawn_blocking(move || {
        if !is_running(&bundle) { return Permission::NotRunning; }
        permission(&bundle, false)
    }).await.unwrap_or(Permission::Unknown)
}

/// Show the system consent dialog for a target app (it must be running).
#[tauri::command]
pub async fn automation_request(bundle: String) -> Permission {
    tokio::task::spawn_blocking(move || permission(&bundle, true)).await.unwrap_or(Permission::Unknown)
}

/// Open the matching System Settings → Privacy & Security pane.
#[tauri::command]
pub async fn open_privacy_pane(pane: String) -> Result<(), String> {
    let anchor = match pane.as_str() {
        "automation"    => "Privacy_Automation",
        "accessibility" => "Privacy_Accessibility",
        "screen"        => "Privacy_ScreenCapture",
        "files"         => "Privacy_AllFiles",
        "microphone"    => "Privacy_Microphone",
        "camera"        => "Privacy_Camera",
        _ => return Err(format!("unknown pane {pane}")),
    };
    let url = format!("x-apple.systempreferences:com.apple.preference.security?{anchor}");
    tokio::task::spawn_blocking(move || opener::open(url).map_err(|e| e.to_string())).await.map_err(|e| e.to_string())?
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn status_codes_map() {
        assert_eq!(Permission::from_status(0), Permission::Ok);
        assert_eq!(Permission::from_status(-1743), Permission::Denied);
        assert_eq!(Permission::from_status(-1744), Permission::Ask);
        assert_eq!(Permission::from_status(-600), Permission::NotRunning);
        assert_eq!(Permission::from_status(-50), Permission::Unknown);
    }

    #[test]
    fn four_char_codes() {
        assert_eq!(u32::from_be_bytes(*b"bund"), 0x6275_6E64);
        assert_eq!(u32::from_be_bytes(*b"****"), 0x2A2A_2A2A);
    }
}
