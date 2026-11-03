//! Non-activating panels for the dock, widgets and the Island.
//!
//! A plain NSWindow of an inactive app spends the first click activating the
//! app, so the press never reaches the page: "I have to double-click the dock".
//! `acceptsFirstMouse` is supposed to cover this but is unreliable (it fails on
//! macOS 27: tauri-apps/tauri#6781). An `NSPanel` with the non-activating style
//! never activates Cortex at all, so the first click lands — and clicking a
//! widget no longer steals focus from the app you're typing in.
//!
//! Conversion is done by `tauri-nspanel` (swizzles tao's window class to an
//! NSPanel subclass, and syncs WindowServer's "prevents activation" tag, which a
//! bare style-mask change does not).

use tauri::WebviewWindow;

#[cfg(target_os = "macos")]
tauri_nspanel::tauri_panel! {
    // Buttons only: never becomes key, so it can't take keyboard focus.
    panel!(CortexPanel {
        config: {
            can_become_key_window: false,
            can_become_main_window: false,
            is_floating_panel: true
        }
    })
    // Has a text field (sticky note, to-dos): becomes key only when one is clicked.
    panel!(CortexInputPanel {
        config: {
            can_become_key_window: true,
            can_become_main_window: false,
            becomes_key_only_if_needed: true,
            is_floating_panel: true
        }
    })
}

/// Convert `win` into a non-activating panel (idempotent). `input`: it hosts
/// text inputs. Runs on the main thread; call from any thread.
pub fn convert(win: &WebviewWindow, input: bool) {
    #[cfg(target_os = "macos")]
    {
        let w = win.clone();
        let _ = win.run_on_main_thread(move || {
            use tauri::Manager;
            use tauri_nspanel::{ManagerExt, WebviewWindowExt};
            if w.app_handle().get_webview_panel(w.label()).is_ok() { return; }
            let panel = if input { w.to_panel::<CortexInputPanel>() } else { w.to_panel::<CortexPanel>() };
            let panel = match panel {
                Ok(p) => p,
                Err(e) => { tracing::warn!(target: "aio_cortex_lib", "panel conversion failed for {}: {e}", w.label()); return; }
            };
            // Tauri owns the window; AppKit must not also release it on close.
            panel.set_released_when_closed(false);
            // Class conversion skips NSPanel's init, so state NSPanel would set
            // is set explicitly: stay visible when another app is active…
            panel.set_hides_on_deactivate(false);
            // …deliver hover events without being key (dock magnification)…
            panel.set_accepts_mouse_moved_events(true);
            // …and never activate Cortex on click.
            if let Err(e) = panel.add_style_mask(objc2_app_kit::NSWindowStyleMask::NonactivatingPanel) {
                tracing::warn!(target: "aio_cortex_lib", "non-activating style failed for {}: {e}", w.label());
            }
        });
    }
    #[cfg(not(target_os = "macos"))]
    let _ = (win, input);
}

/// Give the window back to tao as a plain NSWindow (call before destroying it).
pub fn revert(app: &tauri::AppHandle, label: &str) {
    #[cfg(target_os = "macos")]
    {
        use tauri_nspanel::ManagerExt;
        let label = label.to_string();
        let a = app.clone();
        let _ = app.run_on_main_thread(move || {
            if let Ok(panel) = a.get_webview_panel(&label) { let _ = panel.to_window(); }
        });
    }
    #[cfg(not(target_os = "macos"))]
    let _ = (app, label);
}

/// Set the whole window's opacity (native glass + web content together).
pub fn set_alpha(app: &tauri::AppHandle, label: &str, alpha: f64) {
    #[cfg(target_os = "macos")]
    {
        use tauri_nspanel::ManagerExt;
        let label = label.to_string();
        let a = app.clone();
        let _ = app.run_on_main_thread(move || {
            if let Ok(panel) = a.get_webview_panel(&label) { panel.set_alpha_value(alpha); return; }
            // Not (yet) a panel: plain NSWindow alpha.
            use tauri::Manager;
            if let Some(w) = a.get_webview_window(&label) {
                if let Ok(ptr) = w.ns_window() {
                    if !ptr.is_null() {
                        // SAFETY: live NSWindow* on the main thread.
                        let ns: &objc2_app_kit::NSWindow = unsafe { &*(ptr as *const objc2_app_kit::NSWindow) };
                        ns.setAlphaValue(alpha);
                    }
                }
            }
        });
    }
    #[cfg(not(target_os = "macos"))]
    let _ = (app, label, alpha);
}
