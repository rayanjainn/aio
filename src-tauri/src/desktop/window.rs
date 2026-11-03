//! Window management — snap the focused window of the frontmost app (or the
//! app you were in before ⌘K) to halves, quarters, thirds, center, maximize…
//!
//! Uses the Accessibility API directly (AXUIElement), which is instant and
//! works with every app, unlike AppleScript `set bounds`. Requires the
//! Accessibility permission; `ax_trusted(true)` shows macOS's prompt.

use super::macos::Rect;
use std::{collections::HashMap, sync::Mutex};

pub const ACTIONS: &[(&str, &str)] = &[
    ("left", "Left Half"), ("right", "Right Half"), ("top", "Top Half"), ("bottom", "Bottom Half"),
    ("topLeft", "Top Left"), ("topRight", "Top Right"), ("bottomLeft", "Bottom Left"), ("bottomRight", "Bottom Right"),
    ("leftThird", "Left Third"), ("centerThird", "Center Third"), ("rightThird", "Right Third"),
    ("leftTwoThirds", "Left Two Thirds"), ("rightTwoThirds", "Right Two Thirds"),
    ("max", "Maximize"), ("almostMax", "Almost Maximize"), ("center", "Center"),
    ("fullscreen", "Toggle Fullscreen"), ("restore", "Restore"), ("nextDisplay", "Next Display"),
];

/// Where `action` puts a window currently at `cur` on a screen whose usable
/// area is `vis`. `None` for actions that aren't a plain frame change.
pub fn target_rect(action: &str, vis: Rect, cur: Rect) -> Option<Rect> {
    let Rect { x, y, w, h } = vis;
    let (w2, h2, w3) = ((w / 2.0).floor(), (h / 2.0).floor(), (w / 3.0).floor());
    let r = |x: f64, y: f64, w: f64, h: f64| Some(Rect { x, y, w, h });
    match action {
        "left"           => r(x, y, w2, h),
        "right"          => r(x + w - w2, y, w2, h),
        "top"            => r(x, y, w, h2),
        "bottom"         => r(x, y + h - h2, w, h2),
        "topLeft"        => r(x, y, w2, h2),
        "topRight"       => r(x + w - w2, y, w2, h2),
        "bottomLeft"     => r(x, y + h - h2, w2, h2),
        "bottomRight"    => r(x + w - w2, y + h - h2, w2, h2),
        "leftThird"      => r(x, y, w3, h),
        "centerThird"    => r(x + w3, y, w3, h),
        "rightThird"     => r(x + w - w3, y, w3, h),
        "leftTwoThirds"  => r(x, y, w - w3, h),
        "rightTwoThirds" => r(x + w3, y, w - w3, h),
        "max"            => r(x, y, w, h),
        "almostMax"      => {
            let (aw, ah) = ((w * 0.92).floor(), (h * 0.92).floor());
            r(x + ((w - aw) / 2.0).floor(), y + ((h - ah) / 2.0).floor(), aw, ah)
        }
        "center" => {
            let (cw, ch) = (cur.w.min(w), cur.h.min(h));
            r(x + ((w - cw) / 2.0).floor(), y + ((h - ch) / 2.0).floor(), cw, ch)
        }
        _ => None,
    }
}

/// Screen holding most of the window (by its centre), else the first.
pub fn screen_for(screens: &[super::macos::ScreenInfo], cur: Rect) -> usize {
    let (cx, cy) = (cur.x + cur.w / 2.0, cur.y + cur.h / 2.0);
    screens.iter().position(|s| s.frame.contains(cx, cy)).unwrap_or(0)
}

/// Window frames before the last snap, for "Restore" (keyed by pid).
fn previous() -> &'static Mutex<HashMap<i32, Rect>> {
    static P: std::sync::OnceLock<Mutex<HashMap<i32, Rect>>> = std::sync::OnceLock::new();
    P.get_or_init(Default::default)
}

/// Snap the focused window of `pid`.
pub fn perform(app: &tauri::AppHandle, pid: i32, action: &str) -> Result<String, String> {
    #[cfg(target_os = "macos")]
    {
        if !ax::trusted(false) {
            ax::trusted(true); // show the system prompt once
            return Err("Allow Cortex in System Settings → Privacy & Security → Accessibility, then try again".into());
        }
        let win = ax::focused_window(pid).ok_or("That app has no window to move")?;
        if action == "fullscreen" {
            let on = win.fullscreen();
            win.set_fullscreen(!on);
            return Ok(if on { "Exited fullscreen".into() } else { "Fullscreen".into() });
        }
        let cur = win.frame().ok_or("Couldn't read the window's frame")?;
        let screens = super::macos::screens(app);
        if screens.is_empty() { return Err("No screens".into()); }
        let idx = screen_for(&screens, cur);
        let target = match action {
            "restore" => previous().lock().ok().and_then(|p| p.get(&pid).copied()).ok_or("Nothing to restore")?,
            "nextDisplay" => {
                if screens.len() < 2 { return Err("Only one display".into()); }
                let (from, to) = (screens[idx].visible, screens[(idx + 1) % screens.len()].visible);
                // Keep the window's relative position and size.
                let fx = (cur.x - from.x) / from.w;
                let fy = (cur.y - from.y) / from.h;
                Rect { x: to.x + fx * to.w, y: to.y + fy * to.h, w: (cur.w / from.w * to.w).min(to.w), h: (cur.h / from.h * to.h).min(to.h) }
            }
            a => target_rect(a, screens[idx].visible, cur).ok_or_else(|| format!("Unknown window action “{a}”"))?,
        };
        if action != "restore" {
            if let Ok(mut p) = previous().lock() { p.insert(pid, cur); }
        }
        win.set_frame(target);
        let label = ACTIONS.iter().find(|(k, _)| *k == action).map(|(_, l)| *l).unwrap_or(action);
        return Ok(label.to_string());
    }
    #[allow(unreachable_code)]
    { let _ = (app, pid, action); Err("Window management is macOS-only".into()) }
}

#[cfg(target_os = "macos")]
pub mod ax {
    //! Minimal Accessibility + CoreFoundation FFI.
    use super::Rect;
    use std::ffi::c_void;

    type CFTypeRef = *const c_void;
    type CFStringRef = *const c_void;
    type AXUIElementRef = *const c_void;
    type AXValueRef = *const c_void;

    #[repr(C)] #[derive(Clone, Copy, Default)] struct CGPoint { x: f64, y: f64 }
    #[repr(C)] #[derive(Clone, Copy, Default)] struct CGSize { w: f64, h: f64 }

    const K_AX_VALUE_CGPOINT: u32 = 1;
    const K_AX_VALUE_CGSIZE: u32 = 2;
    const K_CF_STRING_ENCODING_UTF8: u32 = 0x0800_0100;

    #[link(name = "ApplicationServices", kind = "framework")]
    extern "C" {
        fn AXIsProcessTrustedWithOptions(options: CFTypeRef) -> bool;
        fn AXUIElementCreateApplication(pid: i32) -> AXUIElementRef;
        fn AXUIElementCopyAttributeValue(el: AXUIElementRef, attr: CFStringRef, value: *mut CFTypeRef) -> i32;
        fn AXUIElementSetAttributeValue(el: AXUIElementRef, attr: CFStringRef, value: CFTypeRef) -> i32;
        fn AXValueCreate(kind: u32, ptr: *const c_void) -> AXValueRef;
        fn AXValueGetValue(v: AXValueRef, kind: u32, ptr: *mut c_void) -> bool;
        static kAXTrustedCheckOptionPrompt: CFStringRef;
    }
    #[link(name = "CoreFoundation", kind = "framework")]
    extern "C" {
        fn CFStringCreateWithCString(alloc: CFTypeRef, s: *const i8, enc: u32) -> CFStringRef;
        fn CFRelease(v: CFTypeRef);
        fn CFDictionaryCreate(alloc: CFTypeRef, keys: *const CFTypeRef, values: *const CFTypeRef, n: isize, kcb: *const c_void, vcb: *const c_void) -> CFTypeRef;
        static kCFBooleanTrue: CFTypeRef;
        static kCFBooleanFalse: CFTypeRef;
        static kCFTypeDictionaryKeyCallBacks: c_void;
        static kCFTypeDictionaryValueCallBacks: c_void;
    }

    /// Owned CF object, released on drop.
    struct Cf(CFTypeRef);
    impl Drop for Cf { fn drop(&mut self) { if !self.0.is_null() { unsafe { CFRelease(self.0) } } } }

    fn cfstr(s: &str) -> Cf {
        let c = std::ffi::CString::new(s).unwrap_or_default();
        Cf(unsafe { CFStringCreateWithCString(std::ptr::null(), c.as_ptr(), K_CF_STRING_ENCODING_UTF8) })
    }

    /// Is Cortex allowed to control the computer? `prompt` shows the system dialog.
    pub fn trusted(prompt: bool) -> bool {
        unsafe {
            let keys = [kAXTrustedCheckOptionPrompt];
            let vals = [if prompt { kCFBooleanTrue } else { kCFBooleanFalse }];
            let dict = Cf(CFDictionaryCreate(std::ptr::null(), keys.as_ptr(), vals.as_ptr(), 1,
                &kCFTypeDictionaryKeyCallBacks as *const _ as *const c_void, &kCFTypeDictionaryValueCallBacks as *const _ as *const c_void));
            AXIsProcessTrustedWithOptions(dict.0)
        }
    }

    pub struct Window(Cf);

    pub fn focused_window(pid: i32) -> Option<Window> {
        unsafe {
            let app = Cf(AXUIElementCreateApplication(pid));
            let mut v: CFTypeRef = std::ptr::null();
            for attr in ["AXFocusedWindow", "AXMainWindow"] {
                let a = cfstr(attr);
                if AXUIElementCopyAttributeValue(app.0, a.0, &mut v) == 0 && !v.is_null() {
                    return Some(Window(Cf(v)));
                }
            }
            None
        }
    }

    impl Window {
        fn get(&self, attr: &str) -> Option<Cf> {
            let a = cfstr(attr);
            let mut v: CFTypeRef = std::ptr::null();
            (unsafe { AXUIElementCopyAttributeValue(self.0 .0, a.0, &mut v) } == 0 && !v.is_null()).then(|| Cf(v))
        }
        fn set(&self, attr: &str, v: CFTypeRef) -> bool {
            let a = cfstr(attr);
            unsafe { AXUIElementSetAttributeValue(self.0 .0, a.0, v) == 0 }
        }

        pub fn frame(&self) -> Option<Rect> {
            let (mut p, mut s) = (CGPoint::default(), CGSize::default());
            let pv = self.get("AXPosition")?;
            let sv = self.get("AXSize")?;
            unsafe {
                AXValueGetValue(pv.0, K_AX_VALUE_CGPOINT, &mut p as *mut _ as *mut c_void);
                AXValueGetValue(sv.0, K_AX_VALUE_CGSIZE, &mut s as *mut _ as *mut c_void);
            }
            Some(Rect { x: p.x, y: p.y, w: s.w, h: s.h })
        }

        /// Position → size → position: apps that clamp size to the current
        /// screen otherwise end up misplaced when moving between displays.
        pub fn set_frame(&self, r: Rect) {
            let p = CGPoint { x: r.x, y: r.y };
            let s = CGSize { w: r.w, h: r.h };
            unsafe {
                let pv = Cf(AXValueCreate(K_AX_VALUE_CGPOINT, &p as *const _ as *const c_void));
                let sv = Cf(AXValueCreate(K_AX_VALUE_CGSIZE, &s as *const _ as *const c_void));
                self.set("AXPosition", pv.0);
                self.set("AXSize", sv.0);
                self.set("AXPosition", pv.0);
            }
        }

        pub fn fullscreen(&self) -> bool {
            self.get("AXFullScreen").map(|v| unsafe { v.0 == kCFBooleanTrue }).unwrap_or(false)
        }
        pub fn set_fullscreen(&self, on: bool) {
            unsafe { self.set("AXFullScreen", if on { kCFBooleanTrue } else { kCFBooleanFalse }); }
        }
    }
}

/* ─── IPC ───────────────────────────────────────────────── */

/// Snap the window of the app you were using before Cortex opened.
#[tauri::command]
pub async fn window_snap(action: String, app: tauri::AppHandle) -> Result<String, String> {
    use tauri::Manager;
    let pid = app.try_state::<crate::AppState>()
        .and_then(|s| s.last_front.lock().ok().map(|f| f.pid))
        .filter(|p| *p > 0)
        .ok_or("Switch to an app first")?;
    tokio::task::spawn_blocking(move || perform(&app, pid, &action)).await.map_err(|e| e.to_string())?
}

#[tauri::command]
pub fn accessibility_status(prompt: Option<bool>) -> bool {
    #[cfg(target_os = "macos")]
    { return ax::trusted(prompt.unwrap_or(false)); }
    #[allow(unreachable_code)]
    { let _ = prompt; false }
}

#[cfg(test)]
mod tests {
    use super::*;
    const VIS: Rect = Rect { x: 0.0, y: 25.0, w: 1440.0, h: 875.0 };
    const CUR: Rect = Rect { x: 100.0, y: 100.0, w: 800.0, h: 600.0 };

    #[test]
    fn halves_and_quarters_tile_the_screen() {
        let l = target_rect("left", VIS, CUR).unwrap();
        let r = target_rect("right", VIS, CUR).unwrap();
        assert_eq!(l, Rect { x: 0.0, y: 25.0, w: 720.0, h: 875.0 });
        assert_eq!(l.w + r.w, VIS.w);
        let br = target_rect("bottomRight", VIS, CUR).unwrap();
        assert_eq!(br.x + br.w, VIS.w);
        assert_eq!(br.y + br.h, VIS.y + VIS.h);
    }

    #[test]
    fn thirds_cover_the_width() {
        let a = target_rect("leftThird", VIS, CUR).unwrap();
        let b = target_rect("rightTwoThirds", VIS, CUR).unwrap();
        assert_eq!(a.w + b.w, VIS.w);
        assert_eq!(b.x, a.w);
    }

    #[test]
    fn center_keeps_size_and_clamps() {
        let c = target_rect("center", VIS, CUR).unwrap();
        assert_eq!((c.w, c.h), (800.0, 600.0));
        assert_eq!(c.x, 320.0);
        let huge = Rect { w: 5000.0, h: 5000.0, ..CUR };
        let c2 = target_rect("center", VIS, huge).unwrap();
        assert_eq!((c2.w, c2.h), (VIS.w, VIS.h));
        assert!(target_rect("teleport", VIS, CUR).is_none());
    }

    #[test]
    fn picks_screen_by_window_centre() {
        let s = |x: f64| super::super::macos::ScreenInfo { frame: Rect { x, y: 0.0, w: 1000.0, h: 800.0 }, ..Default::default() };
        let screens = vec![s(0.0), s(1000.0)];
        assert_eq!(screen_for(&screens, Rect { x: 1200.0, y: 100.0, w: 300.0, h: 300.0 }), 1);
        assert_eq!(screen_for(&screens, Rect { x: 5000.0, y: 100.0, w: 10.0, h: 10.0 }), 0);
    }
}
