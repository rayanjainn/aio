//! Glass backdrops for Cortex windows.
//!
//! Two materials:
//! * `Liquid` — macOS 26+ `NSGlassEffectView`, the real Liquid Glass (lensing,
//!   specular edge, adaptive tint). AppKit draws it in a flat "inactive" style
//!   when its window isn't the key window of the frontmost app — and desktop
//!   widgets, the dock and the Island never are. There is no public switch for
//!   that (NSVisualEffectView has `state`, NSGlassEffectView does not), but
//!   AppKit's private `-[NSWindow _setForceMainAppearance:]` keeps a window drawn
//!   as active; it's called only if the window responds to it, so if a future
//!   macOS drops it the glass simply behaves as before.
//! * `Frosted` — `NSVisualEffectView` pinned to `.active` (public API, never
//!   dims). Also the automatic fallback before macOS 26.
//!
//! Either view sits behind the transparent webview and can be inset to a
//! sub-rectangle (the dock keeps transparent headroom for magnification). The
//! webview only adds rims and highlights in CSS: a transparent WKWebView cannot
//! see the desktop behind it.

use tauri::WebviewWindow;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Material {
    Liquid,
    Frosted,
}

impl Material {
    pub fn from_setting(s: &str) -> Self { if s == "frosted" { Material::Frosted } else { Material::Liquid } }
    pub fn as_str(self) -> &'static str { match self { Material::Liquid => "liquid", Material::Frosted => "frosted" } }
}

/// The user's choice (Settings → Appearance → Glass), default Liquid.
pub fn preferred() -> Material {
    let cfg = crate::config_ipc::load_config();
    Material::from_setting(cfg.ui.get("glassMaterial").and_then(|v| v.as_str()).unwrap_or("liquid"))
}

/// Apply the preferred glass with the given corner radius.
pub fn apply(win: &WebviewWindow, radius: f64) {
    apply_material(win, radius, preferred());
}

pub fn apply_material(win: &WebviewWindow, radius: f64, material: Material) {
    #[cfg(target_os = "macos")]
    {
        let w = win.clone();
        let _ = win.run_on_main_thread(move || {
            let ok = match material {
                Material::Liquid if mac::has_native_glass() => mac::install_liquid(&w, radius),
                _ => mac::install_frosted(&w, radius),
            };
            if !ok { let _ = w.set_effects(Some(fallback(radius))); }
        });
        return;
    }
    #[allow(unreachable_code)]
    { let _ = material; let _ = win.set_effects(Some(fallback(radius))); }
}

/// Swap the backdrop of every Cortex window after the setting changed.
pub fn reapply_all(app: &tauri::AppHandle, radius_for: impl Fn(&str) -> f64 + Send + 'static) {
    #[cfg(target_os = "macos")]
    {
        use tauri::Manager;
        let material = preferred();
        for (label, win) in app.webview_windows() {
            let r = radius_for(&label);
            let w = win.clone();
            let _ = win.run_on_main_thread(move || {
                mac::remove_backdrops(&w);
                let ok = match material {
                    Material::Liquid if mac::has_native_glass() => mac::install_liquid(&w, r),
                    _ => mac::install_frosted(&w, r),
                };
                let _ = ok;
            });
        }
    }
    #[cfg(not(target_os = "macos"))]
    let _ = (app, radius_for);
}

/// True when the real Liquid Glass is available (macOS 26+).
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

/// What the frontend should draw on top.
#[tauri::command]
pub fn glass_info() -> serde_json::Value {
    serde_json::json!({
        "native": cfg!(target_os = "macos"),
        "liquid": native_available(),
        "material": preferred().as_str(),
    })
}

/// Settings → Appearance: switch every window between Liquid Glass and Frosted.
#[tauri::command]
pub async fn set_glass_material(kind: String, app: tauri::AppHandle) -> Result<(), String> {
    let kind = if kind == "frosted" { "frosted" } else { "liquid" };
    tokio::task::spawn_blocking(move || {
        let mut cfg = crate::config_ipc::load_config();
        cfg.ui.insert("glassMaterial".into(), serde_json::json!(kind));
        crate::config_ipc::save_config(&cfg).map_err(|e| e.to_string())
    }).await.map_err(|e| e.to_string())??;
    reapply_all(&app, |label| match label {
        "main" => 14.0,
        "dock" => 28.0,
        l if l.starts_with("widget-") => 22.0,
        _ => 0.0,
    });
    Ok(())
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
    use objc2::{
        msg_send,
        rc::Retained,
        runtime::{AnyClass, Bool, NSObjectProtocol},
        sel, ClassType, MainThreadMarker, MainThreadOnly,
    };
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

    fn ns_window(win: &tauri::WebviewWindow) -> Option<&'static NSWindow> {
        let ptr = win.ns_window().ok()?;
        if ptr.is_null() { return None; }
        // SAFETY: live NSWindow* owned by tauri/tao; callers run on the main thread
        // and the reference is not kept past the closure.
        Some(unsafe { &*(ptr as *const NSWindow) })
    }

    fn content(win: &tauri::WebviewWindow) -> Option<Retained<NSView>> {
        ns_window(win)?.contentView()
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

    /// Keep the window drawn as active so Liquid Glass doesn't flatten to grey
    /// when the window isn't key. Private selector, called only if present.
    fn keep_active_look(win: &NSWindow) {
        let sel = sel!(_setForceMainAppearance:);
        // SAFETY: respondsToSelector: is always valid; the setter takes one BOOL.
        unsafe {
            let responds: Bool = msg_send![win, respondsToSelector: sel];
            if responds.as_bool() {
                let _: () = msg_send![win, _setForceMainAppearance: Bool::YES];
            }
        }
    }

    pub fn install_liquid(win: &tauri::WebviewWindow, radius: f64) -> bool {
        let Some(mtm) = MainThreadMarker::new() else { return false };
        let (Some(content), Some(ns)) = (content(win), ns_window(win)) else { return false };
        if already_installed(&content) { keep_active_look(ns); return true; }
        let glass: Retained<NSGlassEffectView> =
            NSGlassEffectView::initWithFrame(NSGlassEffectView::alloc(mtm), content.bounds());
        glass.setCornerRadius(radius);
        insert_below(&content, &glass);
        keep_active_look(ns);
        true
    }

    /// Classic vibrancy pinned to `.active`: identical whether or not the window is key.
    pub fn install_frosted(win: &tauri::WebviewWindow, radius: f64) -> bool {
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

    pub fn remove_backdrops(win: &tauri::WebviewWindow) {
        let Some(content) = content(win) else { return };
        for sub in content.subviews().iter() {
            if is_backdrop(&sub) { sub.removeFromSuperview(); }
        }
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
