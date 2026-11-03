//! Small, fast AppKit queries (no subprocesses): the frontmost app and the
//! screens' usable frames, in the top-left-origin coordinates Accessibility
//! and tauri use.

#[derive(Debug, Clone, Default)]
pub struct FrontApp {
    pub name: String,
    pub pid:  i32,
    pub path: String,
}

/// Rectangle in global top-left-origin points.
#[derive(Debug, Clone, Copy, Default, PartialEq, serde::Serialize)]
pub struct Rect { pub x: f64, pub y: f64, pub w: f64, pub h: f64 }

impl Rect {
    pub fn contains(&self, px: f64, py: f64) -> bool {
        px >= self.x && px < self.x + self.w && py >= self.y && py < self.y + self.h
    }
}

#[derive(Debug, Clone, Default, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ScreenInfo {
    pub frame:   Rect,
    /// Excludes the menu bar and the Dock.
    pub visible: Rect,
    /// Notch width in points (0 on screens without one).
    pub notch_width: f64,
    pub menu_bar_height: f64,
}

/// The frontmost application (microseconds; NSWorkspace is thread-safe).
#[cfg(target_os = "macos")]
pub fn frontmost_app() -> Option<FrontApp> {
    use objc2_app_kit::NSWorkspace;
    let ws = NSWorkspace::sharedWorkspace();
    let app = ws.frontmostApplication()?;
    Some(FrontApp {
        name: app.localizedName().map(|s| s.to_string()).unwrap_or_default(),
        pid:  app.processIdentifier(),
        path: app.bundleURL().and_then(|u| u.path()).map(|p| p.to_string()).unwrap_or_default(),
    })
}

#[cfg(not(target_os = "macos"))]
pub fn frontmost_app() -> Option<FrontApp> { None }

/// All screens. Must run on the main thread (NSScreen).
#[cfg(target_os = "macos")]
pub fn screens_main_thread() -> Vec<ScreenInfo> {
    use objc2::MainThreadMarker;
    use objc2_app_kit::NSScreen;
    let Some(mtm) = MainThreadMarker::new() else { return vec![] };
    let screens = NSScreen::screens(mtm);
    let Some(primary) = screens.iter().next() else { return vec![] };
    // Cocoa's origin is the bottom-left of the primary screen; flip to top-left.
    let ph = primary.frame().size.height;
    let flip = |r: objc2_foundation::NSRect| Rect { x: r.origin.x, y: ph - (r.origin.y + r.size.height), w: r.size.width, h: r.size.height };
    screens.iter().map(|s| {
        let frame = s.frame();
        let visible = s.visibleFrame();
        let top_inset = s.safeAreaInsets().top;
        let (l, r) = (s.auxiliaryTopLeftArea(), s.auxiliaryTopRightArea());
        let notch_width = if top_inset > 0.0 && l.size.width > 0.0 && r.size.width > 0.0 {
            (frame.size.width - l.size.width - r.size.width).max(0.0)
        } else { 0.0 };
        let menu = (frame.origin.y + frame.size.height) - (visible.origin.y + visible.size.height);
        ScreenInfo {
            frame: flip(frame),
            visible: flip(visible),
            notch_width,
            menu_bar_height: if top_inset > 0.0 { top_inset } else { menu.clamp(0.0, 40.0) },
        }
    }).collect()
}

/// All screens, from any thread (hops to the main thread and waits).
pub fn screens(app: &tauri::AppHandle) -> Vec<ScreenInfo> {
    #[cfg(target_os = "macos")]
    {
        // Already on the main thread (setup, sync commands): hopping and waiting
        // would deadlock until the timeout and report "no notch".
        if objc2::MainThreadMarker::new().is_some() { return screens_main_thread(); }
        let (tx, rx) = std::sync::mpsc::channel();
        if app.run_on_main_thread(move || { let _ = tx.send(screens_main_thread()); }).is_ok() {
            if let Ok(v) = rx.recv_timeout(std::time::Duration::from_millis(500)) { return v; }
        }
    }
    // Portable fallback from tauri's monitor list.
    app.available_monitors().unwrap_or_default().iter().map(|m| {
        let s = m.scale_factor();
        let r = Rect { x: m.position().x as f64 / s, y: m.position().y as f64 / s, w: m.size().width as f64 / s, h: m.size().height as f64 / s };
        let wa = m.work_area();
        ScreenInfo {
            frame: r,
            visible: Rect { x: wa.position.x as f64 / s, y: wa.position.y as f64 / s, w: wa.size.width as f64 / s, h: wa.size.height as f64 / s },
            notch_width: 0.0,
            menu_bar_height: 0.0,
        }
    }).collect()
}

#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RunningApp { pub name: String, pub path: String, pub bundle_id: String, pub active: bool }

/// Regular (Dock-visible) running apps, frontmost first. NSWorkspace answers in
/// microseconds and needs no permission — the old System Events AppleScript
/// needed Automation access and ~150 ms per call.
#[cfg(target_os = "macos")]
pub fn running_apps() -> Vec<RunningApp> {
    use objc2_app_kit::{NSApplicationActivationPolicy, NSWorkspace};
    let me = std::process::id() as i32;
    let mut out: Vec<RunningApp> = NSWorkspace::sharedWorkspace().runningApplications().iter().filter_map(|a| {
        if a.activationPolicy() != NSApplicationActivationPolicy::Regular || a.processIdentifier() == me { return None; }
        let path = a.bundleURL().and_then(|u| u.path()).map(|p| p.to_string())?;
        let name = a.localizedName().map(|n| n.to_string())
            .or_else(|| std::path::Path::new(&path).file_stem().map(|s| s.to_string_lossy().to_string()))?;
        Some(RunningApp { name, path, bundle_id: a.bundleIdentifier().map(|b| b.to_string()).unwrap_or_default(), active: a.isActive() })
    }).collect();
    out.sort_by_key(|a| !a.active); // stable: frontmost first, launch order otherwise
    out
}

#[cfg(not(target_os = "macos"))]
pub fn running_apps() -> Vec<RunningApp> { vec![] }
