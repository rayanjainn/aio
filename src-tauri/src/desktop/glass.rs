//! Liquid Glass backdrop for Cortex windows.
//!
//! macOS 26+: a native `NSGlassEffectView` (the real Liquid Glass material —
//! refraction, specular edges, adaptive tint) is placed behind the transparent
//! webview. Older macOS / Windows: the system vibrancy material via tauri
//! window effects. The webview only adds rim highlights in CSS, since a
//! transparent WKWebView cannot see (or refract) the desktop behind it.

use tauri::WebviewWindow;

/// Apply the best available glass to `win` with the given corner radius.
pub fn apply(win: &WebviewWindow, radius: f64) {
    #[cfg(target_os = "macos")]
    {
        if mac::has_native_glass() {
            let w = win.clone();
            let _ = win.run_on_main_thread(move || {
                if !mac::install(&w, radius) {
                    let _ = w.set_effects(Some(fallback(radius)));
                }
            });
            return;
        }
    }
    let _ = win.set_effects(Some(fallback(radius)));
}

/// System vibrancy (NSVisualEffectView HUD material / Windows acrylic).
pub fn fallback(radius: f64) -> tauri::utils::config::WindowEffectsConfig {
    use tauri::window::{Effect, EffectState};
    tauri::utils::config::WindowEffectsConfig {
        effects: vec![Effect::HudWindow, Effect::Acrylic],
        state:   Some(EffectState::Active),
        radius:  Some(radius),
        color:   None,
    }
}

#[cfg(target_os = "macos")]
mod mac {
    use objc2::{rc::Retained, runtime::{AnyClass, NSObjectProtocol}, ClassType, MainThreadMarker, MainThreadOnly};
    use objc2_app_kit::{NSAutoresizingMaskOptions, NSGlassEffectView, NSView, NSWindow, NSWindowOrderingMode};

    /// NSGlassEffectView only exists on macOS 26 (Tahoe) and later; messaging
    /// a missing class would abort, so look it up dynamically first.
    pub fn has_native_glass() -> bool {
        AnyClass::get(c"NSGlassEffectView").is_some()
    }

    /// Insert the glass view at the bottom of the window's content view.
    /// Must run on the main thread. Returns false if anything is missing.
    pub fn install(win: &tauri::WebviewWindow, radius: f64) -> bool {
        let Some(mtm) = MainThreadMarker::new() else { return false };
        let Ok(ptr) = win.ns_window() else { return false };
        if ptr.is_null() { return false; }
        // SAFETY: live NSWindow* owned by tauri; we are on the main thread.
        let ns: &NSWindow = unsafe { &*(ptr as *const NSWindow) };
        let Some(content) = ns.contentView() else { return false };
        // Idempotent: re-applying (e.g. after a layer change) must not stack views.
        for sub in content.subviews().iter() {
            if sub.isKindOfClass(NSGlassEffectView::class()) { return true; }
        }
        let glass: Retained<NSGlassEffectView> =
            NSGlassEffectView::initWithFrame(NSGlassEffectView::alloc(mtm), content.bounds());
        glass.setCornerRadius(radius);
        glass.setAutoresizingMask(NSAutoresizingMaskOptions::ViewWidthSizable | NSAutoresizingMaskOptions::ViewHeightSizable);
        let view: &NSView = &glass;
        content.addSubview_positioned_relativeTo(view, NSWindowOrderingMode::Below, None);
        true
    }
}
