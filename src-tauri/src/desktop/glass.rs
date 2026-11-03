//! Glass backdrops for Cortex windows.
//!
//! Two materials, chosen per window:
//! * `Liquid` — macOS 26+ `NSGlassEffectView`, the real Liquid Glass. AppKit
//!   renders it in a foggy "inactive" style whenever the window isn't key, so
//!   it is used only for windows you type into (palette, Studio).
//! * `Vivid` — an `NSVisualEffectView` forced to `.active`. It never dims, so
//!   desktop widgets, the dock and the island (never key windows) stay crisp.
//!
//! Both views are inserted behind the transparent webview and can be inset to a
//! sub-rectangle (the dock keeps transparent headroom for magnification).
//! The webview adds only specular rims and highlights in CSS — a transparent
//! WKWebView cannot see the desktop behind it.

use tauri::WebviewWindow;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Material {
    Liquid,
    Vivid,
}

/// Apply glass with the given corner radius (Liquid falls back to Vivid).
pub fn apply(win: &WebviewWindow, radius: f64) {
    apply_material(win, radius, Material::Liquid);
}

pub fn apply_material(win: &WebviewWindow, radius: f64, material: Material) {
    #[cfg(target_os = "macos")]
    {
        let w = win.clone();
        let _ = win.run_on_main_thread(move || {
            let ok = match material {
                Material::Liquid if mac::has_native_glass() => mac::install_liquid(&w, radius),
                _ => mac::install_vivid(&w, radius),
            };
            if !ok { let _ = w.set_effects(Some(fallback(radius))); }
        });
        return;
    }
    #[allow(unreachable_code)]
    { let _ = material; let _ = win.set_effects(Some(fallback(radius))); }
}

/// True when the real Liquid Glass material is available (macOS 26+).
pub fn native_available() -> bool {
    #[cfg(target_os = "macos")]
    { return mac::has_native_glass(); }
    #[allow(unreachable_code)]
    false
}

/// Shrink the glass to a sub-rectangle of the window (points from each edge).
pub fn set_inset(win: &WebviewWindow, top: f64, right: f64, bottom: f64, left: f64) {
    #[cfg(target_os = "macos")]
    {
        let w = win.clone();
        let _ = win.run_on_main_thread(move || mac::inset(&w, top, right, bottom, left));
    }
    #[cfg(not(target_os = "macos"))]
    let _ = (win, top, right, bottom, left);
}

/// What the frontend should draw on top. `native` → a system material is
/// behind the page (Liquid Glass in focused windows, vivid vibrancy in
/// widgets/dock/island), so CSS only adds rims.
#[tauri::command]
pub fn glass_info() -> serde_json::Value {
    serde_json::json!({ "native": cfg!(target_os = "macos"), "liquid": native_available() })
}

/// System vibrancy via tauri (Windows acrylic / last-resort macOS path).
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
    use objc2_app_kit::{
        NSAutoresizingMaskOptions, NSGlassEffectView, NSView, NSVisualEffectBlendingMode, NSVisualEffectMaterial,
        NSVisualEffectState, NSVisualEffectView, NSWindow, NSWindowOrderingMode,
    };
    use objc2_foundation::{NSPoint, NSRect, NSSize};

    /// NSGlassEffectView only exists on macOS 26+; messaging a missing class
    /// would abort, so look it up dynamically first.
    pub fn has_native_glass() -> bool {
        AnyClass::get(c"NSGlassEffectView").is_some()
    }

    fn content(win: &tauri::WebviewWindow) -> Option<Retained<NSView>> {
        let ptr = win.ns_window().ok()?;
        if ptr.is_null() { return None; }
        // SAFETY: live NSWindow* owned by tauri; callers run on the main thread.
        let ns: &NSWindow = unsafe { &*(ptr as *const NSWindow) };
        ns.contentView()
    }

    fn is_backdrop(v: &NSView) -> bool {
        v.isKindOfClass(NSVisualEffectView::class())
            || (has_native_glass() && v.isKindOfClass(NSGlassEffectView::class()))
    }

    fn already_installed(content: &NSView) -> bool {
        content.subviews().iter().any(|s| is_backdrop(&s))
    }

    fn insert_below(content: &NSView, view: &NSView) {
        view.setAutoresizingMask(NSAutoresizingMaskOptions::ViewWidthSizable | NSAutoresizingMaskOptions::ViewHeightSizable);
        content.addSubview_positioned_relativeTo(view, NSWindowOrderingMode::Below, None);
    }

    pub fn install_liquid(win: &tauri::WebviewWindow, radius: f64) -> bool {
        let Some(mtm) = MainThreadMarker::new() else { return false };
        let Some(content) = content(win) else { return false };
        if already_installed(&content) { return true; }
        let glass: Retained<NSGlassEffectView> =
            NSGlassEffectView::initWithFrame(NSGlassEffectView::alloc(mtm), content.bounds());
        glass.setCornerRadius(radius);
        insert_below(&content, &glass);
        true
    }

    /// Classic vibrancy pinned to `.active`: identical whether or not the
    /// window is key (widgets, dock and island are never key).
    pub fn install_vivid(win: &tauri::WebviewWindow, radius: f64) -> bool {
        let Some(mtm) = MainThreadMarker::new() else { return false };
        let Some(content) = content(win) else { return false };
        if already_installed(&content) { return true; }
        let fx: Retained<NSVisualEffectView> =
            NSVisualEffectView::initWithFrame(NSVisualEffectView::alloc(mtm), content.bounds());
        fx.setMaterial(NSVisualEffectMaterial::HUDWindow);
        fx.setBlendingMode(NSVisualEffectBlendingMode::BehindWindow);
        fx.setState(NSVisualEffectState::Active);
        fx.setWantsLayer(true);
        if let Some(layer) = fx.layer() {
            layer.setCornerRadius(radius);
            layer.setMasksToBounds(true);
        }
        insert_below(&content, &fx);
        true
    }

    /// Resize the backdrop to the window bounds minus the given margins.
    /// Content views are not flipped: y grows upward, so `bottom` is the origin.
    pub fn inset(win: &tauri::WebviewWindow, top: f64, right: f64, bottom: f64, left: f64) {
        let Some(content) = content(win) else { return };
        let b = content.bounds();
        let frame = NSRect::new(
            NSPoint::new(left, bottom),
            NSSize::new((b.size.width - left - right).max(0.0), (b.size.height - top - bottom).max(0.0)),
        );
        for sub in content.subviews().iter() {
            if is_backdrop(&sub) { sub.setFrame(frame); }
        }
    }
}
