//! The Island — a Dynamic-Island-style live surface around the MacBook notch
//! (or centred in the menu bar on screens without one): now playing, focus
//! timer, charging, next meeting, Claude Code / Codex activity, and toasts.
//!
//! The window is a fixed transparent strip at the top of the primary screen,
//! above the menu bar. It ignores the mouse except while the pointer is over
//! the pill (reported by the frontend), so the menu bar stays usable, and it
//! never becomes key (clicks don't steal focus from your app).

use serde::{Deserialize, Serialize};
use std::{path::PathBuf, sync::{atomic::{AtomicBool, Ordering}, Arc, Mutex}, time::Duration};
use tauri::{AppHandle, Emitter, Manager, WebviewUrl, WebviewWindowBuilder};

pub const LABEL: &str = "island";
const WIN_W: f64 = 760.0;
const WIN_H: f64 = 320.0;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub struct IslandConfig {
    pub enabled: bool,
    /// "notch" (black, blends with the notch) | "glass" (Liquid Glass pill)
    pub style: String,
    pub music: bool,
    pub coding: bool,
    pub calendar: bool,
    pub battery: bool,
    pub timer: bool,
    pub toasts: bool,
    /// Expand on hover (otherwise click).
    pub hover_expand: bool,
}

impl Default for IslandConfig {
    fn default() -> Self {
        Self { enabled: true, style: "notch".into(), music: true, coding: true, calendar: true, battery: true, timer: true, toasts: true, hover_expand: true }
    }
}

pub struct IslandState {
    path: PathBuf,
    pub cfg: Mutex<IslandConfig>,
    /// Pill rect in window coordinates (x, y, w, h), from the frontend.
    pill: Mutex<(f64, f64, f64, f64)>,
    hovering: AtomicBool,
}

impl IslandState {
    fn config(&self) -> IslandConfig { self.cfg.lock().map(|c| c.clone()).unwrap_or_default() }
}

#[derive(Debug, Clone, Serialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct IslandGeometry { pub has_notch: bool, pub notch_width: f64, pub menu_bar_height: f64, pub window_width: f64 }

fn geometry(app: &AppHandle) -> (IslandGeometry, super::macos::Rect) {
    let screens = super::macos::screens(app);
    let s = screens.first().cloned().unwrap_or_default();
    let frame = if s.frame.w > 0.0 { s.frame } else { super::macos::Rect { x: 0.0, y: 0.0, w: 1440.0, h: 900.0 } };
    (IslandGeometry {
        has_notch: s.notch_width > 0.0,
        notch_width: if s.notch_width > 0.0 { s.notch_width } else { 190.0 },
        menu_bar_height: if s.menu_bar_height > 0.0 { s.menu_bar_height } else { 24.0 },
        window_width: WIN_W,
    }, frame)
}

fn open(app: &AppHandle) -> tauri::Result<()> {
    if app.get_webview_window(LABEL).is_some() { return Ok(()); }
    let (_, frame) = geometry(app);
    let win = WebviewWindowBuilder::new(app, LABEL, WebviewUrl::App("index.html#/island".into()))
        .title("Cortex Island")
        .decorations(false).transparent(true).shadow(false).resizable(false)
        .skip_taskbar(true).focused(false).focusable(false).always_on_top(true)
        .visible_on_all_workspaces(true).accept_first_mouse(true)
        .inner_size(WIN_W, WIN_H)
        .position(frame.x + (frame.w - WIN_W) / 2.0, frame.y)
        .build()?;
    let _ = win.set_ignore_cursor_events(true);
    #[cfg(target_os = "macos")]
    mac::above_menu_bar(&win);
    Ok(())
}

fn apply(app: &AppHandle) {
    let Some(st) = app.try_state::<Arc<IslandState>>() else { return };
    if st.config().enabled {
        if let Err(e) = open(app) { tracing::warn!(target: "aio_cortex_lib", "island: {e}"); }
    } else if let Some(w) = app.get_webview_window(LABEL) {
        let _ = w.destroy();
    }
}

pub fn init(app: &AppHandle, data_dir: &std::path::Path) {
    let path = data_dir.join("island.json");
    let cfg = std::fs::read_to_string(&path).ok().and_then(|s| serde_json::from_str(&s).ok()).unwrap_or_default();
    let st = Arc::new(IslandState { path, cfg: Mutex::new(cfg), pill: Mutex::new((0.0, 0.0, 0.0, 0.0)), hovering: AtomicBool::new(false) });
    app.manage(st.clone());
    apply(app);
    spawn_hover_watch(app.clone(), st);
}

/// ~30 Hz cursor poll: let the pill take the mouse only while hovered, and
/// tell the frontend so it can expand (the window ignores the mouse otherwise,
/// so it can't see hovers itself).
fn spawn_hover_watch(app: AppHandle, st: Arc<IslandState>) {
    tauri::async_runtime::spawn(async move {
        let mut away = 0u32;
        loop {
            tokio::time::sleep(Duration::from_millis(33)).await;
            let Some(win) = app.get_webview_window(LABEL) else { tokio::time::sleep(Duration::from_millis(500)).await; continue };
            let (Ok(cur), Ok(pos)) = (app.cursor_position(), win.outer_position()) else { continue };
            let scale = win.scale_factor().unwrap_or(1.0);
            let (lx, ly) = ((cur.x - pos.x as f64) / scale, (cur.y - pos.y as f64) / scale);
            let (px, py, pw, ph) = st.pill.lock().map(|p| *p).unwrap_or_default();
            let pad = 6.0;
            let inside = pw > 0.0 && lx >= px - pad && lx <= px + pw + pad && ly >= py - pad && ly <= py + ph + pad;
            let was = st.hovering.load(Ordering::Relaxed);
            if inside && !was {
                away = 0;
                st.hovering.store(true, Ordering::Relaxed);
                let _ = win.set_ignore_cursor_events(false);
                let _ = app.emit_to(LABEL, "island-hover", true);
            } else if !inside && was {
                away += 1;
                if away > 6 { // ~200 ms grace so brushing past doesn't flicker
                    st.hovering.store(false, Ordering::Relaxed);
                    let _ = win.set_ignore_cursor_events(true);
                    let _ = app.emit_to(LABEL, "island-hover", false);
                }
            } else if inside {
                away = 0;
            }
        }
    });
}

#[cfg(target_os = "macos")]
mod mac {
    use objc2_app_kit::{NSWindow, NSWindowCollectionBehavior};
    extern "C" { fn CGWindowLevelForKey(key: i32) -> i32; }
    const K_CG_STATUS_WINDOW_LEVEL_KEY: i32 = 9;

    /// Above the menu bar, on every Space, over full-screen apps.
    pub fn above_menu_bar(win: &tauri::WebviewWindow) {
        let w = win.clone();
        let _ = win.run_on_main_thread(move || {
            let Ok(ptr) = w.ns_window() else { return };
            if ptr.is_null() { return; }
            // SAFETY: live NSWindow* on the main thread.
            let ns: &NSWindow = unsafe { &*(ptr as *const NSWindow) };
            ns.setLevel(unsafe { CGWindowLevelForKey(K_CG_STATUS_WINDOW_LEVEL_KEY) } as isize + 1);
            ns.setCollectionBehavior(
                NSWindowCollectionBehavior::CanJoinAllSpaces | NSWindowCollectionBehavior::Stationary
                    | NSWindowCollectionBehavior::IgnoresCycle | NSWindowCollectionBehavior::FullScreenAuxiliary,
            );
            ns.setHasShadow(false);
        });
    }
}

/* ─── IPC ───────────────────────────────────────────────── */

#[tauri::command]
pub fn island_get_config(app: AppHandle) -> IslandConfig {
    app.try_state::<Arc<IslandState>>().map(|s| s.config()).unwrap_or_default()
}

#[tauri::command]
pub fn island_set_config(cfg: IslandConfig, app: AppHandle) -> Result<IslandConfig, String> {
    let st = app.try_state::<Arc<IslandState>>().ok_or("island not ready")?;
    if let Ok(mut g) = st.cfg.lock() { *g = cfg.clone(); }
    super::widgets::write_atomic(&st.path, &cfg).map_err(|e| e.to_string())?;
    apply(&app);
    let _ = app.emit("island-config", &cfg);
    Ok(cfg)
}

#[tauri::command]
pub fn island_geometry(app: AppHandle) -> IslandGeometry { geometry(&app).0 }

/// The pill's current rect inside the island window (points).
#[tauri::command]
pub fn island_pill(x: f64, y: f64, w: f64, h: f64, app: AppHandle) {
    if let Some(st) = app.try_state::<Arc<IslandState>>() {
        if let Ok(mut p) = st.pill.lock() { *p = (x, y, w, h); }
    }
}

/// Show a short message in the Island (from any window).
#[tauri::command]
pub fn island_toast(icon: String, text: String, app: AppHandle) {
    let _ = app.emit("island-toast", serde_json::json!({ "icon": icon, "text": text }));
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn config_defaults_fill_missing_keys() {
        let c: IslandConfig = serde_json::from_str(r#"{"style":"glass","music":false}"#).unwrap();
        assert!(c.enabled && c.coding && !c.music);
        assert_eq!(c.style, "glass");
    }
}
