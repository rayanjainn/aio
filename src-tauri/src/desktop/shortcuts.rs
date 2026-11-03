//! Configurable global shortcuts. Every hotkey (⌘K included) lives in one
//! table, stored in `config.json → shortcuts` (missing = default, "" = off),
//! and is re-registered live when changed from Settings.

use std::{collections::HashMap, sync::Mutex};
use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager};
use tauri_plugin_global_shortcut::{GlobalShortcutExt, Shortcut};

/// (id, label, group, default accelerator)
pub const DEFAULTS: &[(&str, &str, &str, &str)] = &[
    ("palette",  "Open Cortex",                "General", "CommandOrControl+K"),
    ("pause",    "Pause / resume screen memory","General", "CommandOrControl+Shift+P"),
    ("island",   "Expand the Island",          "General", "Control+Alt+Space"),
    ("widgets",  "Show / hide widgets",        "General", "Control+Alt+W"),
    ("studio",   "Widgets & Dock studio",      "General", ""),
    ("window.left",          "Left Half",        "Windows", "Control+Alt+ArrowLeft"),
    ("window.right",         "Right Half",       "Windows", "Control+Alt+ArrowRight"),
    ("window.top",           "Top Half",         "Windows", "Control+Alt+ArrowUp"),
    ("window.bottom",        "Bottom Half",      "Windows", "Control+Alt+ArrowDown"),
    ("window.topLeft",       "Top Left",         "Windows", "Control+Alt+KeyU"),
    ("window.topRight",      "Top Right",        "Windows", "Control+Alt+KeyI"),
    ("window.bottomLeft",    "Bottom Left",      "Windows", "Control+Alt+KeyJ"),
    ("window.bottomRight",   "Bottom Right",     "Windows", "Control+Alt+KeyK"),
    ("window.leftThird",     "Left Third",       "Windows", "Control+Alt+KeyD"),
    ("window.centerThird",   "Center Third",     "Windows", "Control+Alt+KeyF"),
    ("window.rightThird",    "Right Third",      "Windows", "Control+Alt+KeyG"),
    ("window.leftTwoThirds", "Left Two Thirds",  "Windows", "Control+Alt+KeyE"),
    ("window.rightTwoThirds","Right Two Thirds", "Windows", "Control+Alt+KeyT"),
    ("window.max",           "Maximize",         "Windows", "Control+Alt+Enter"),
    ("window.almostMax",     "Almost Maximize",  "Windows", "Control+Alt+Shift+Enter"),
    ("window.center",        "Center",           "Windows", "Control+Alt+KeyC"),
    ("window.fullscreen",    "Toggle Fullscreen","Windows", "Control+Alt+KeyF11"),
    ("window.restore",       "Restore",          "Windows", "Control+Alt+Backspace"),
    ("window.nextDisplay",   "Next Display",     "Windows", "Control+Alt+Super+ArrowRight"),
];

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ShortcutEntry {
    pub id: String,
    pub label: String,
    pub group: String,
    pub accel: String,
    pub default: String,
    /// Registration failed (taken by another app or invalid).
    pub error: Option<String>,
}

/// Registered shortcut id → action id.
#[derive(Default)]
pub struct Registered(pub Mutex<HashMap<u32, String>>, pub Mutex<HashMap<String, String>>);

/// Effective accelerator per action (config override or default).
pub fn effective() -> Vec<(String, String)> {
    let cfg = crate::config_ipc::load_config();
    DEFAULTS.iter().map(|(id, _, _, def)| {
        let accel = cfg.shortcuts.get(*id).cloned().unwrap_or_else(|| def.to_string());
        (id.to_string(), accel)
    }).collect()
}

/// macOS's "Fn" keys use names like F11; accept `KeyF11` too.
fn normalize(accel: &str) -> String {
    accel.split('+').map(|p| if p.starts_with("KeyF") && p.len() > 4 && p[4..].chars().all(|c| c.is_ascii_digit()) { &p[3..] } else { p })
        .collect::<Vec<_>>().join("+")
}

pub fn parse(accel: &str) -> Result<Shortcut, String> {
    normalize(accel).parse::<Shortcut>().map_err(|e| format!("“{accel}” isn't a valid shortcut: {e}"))
}

/// (Re)register every shortcut. Errors are kept per action for Settings.
pub fn register_all(app: &AppHandle) {
    let gs = app.global_shortcut();
    let _ = gs.unregister_all();
    let Some(reg) = app.try_state::<Registered>() else { return };
    let mut map = HashMap::new();
    let mut errors = HashMap::new();
    for (id, accel) in effective() {
        if accel.trim().is_empty() { continue; }
        match parse(&accel) {
            Ok(sc) => match gs.register(sc) {
                Ok(()) => { map.insert(sc.id(), id); }
                Err(e) => {
                    tracing::warn!(target: "aio_cortex_lib", "shortcut {id} ({accel}) not registered: {e}");
                    errors.insert(id, "In use by another app".to_string());
                }
            },
            Err(e) => { errors.insert(id, e); }
        }
    }
    if let Ok(mut g) = reg.0.lock() { *g = map; }
    if let Ok(mut g) = reg.1.lock() { *g = errors; };
}

/// Global-shortcut handler entry point.
pub fn handle(app: &AppHandle, shortcut: &Shortcut) {
    let Some(reg) = app.try_state::<Registered>() else { return };
    let action = reg.0.lock().ok().and_then(|m| m.get(&shortcut.id()).cloned());
    let Some(action) = action else { return };
    dispatch(app, &action);
}

pub fn dispatch(app: &AppHandle, action: &str) {
    match action {
        "palette" => {
            if let Some(w) = app.get_webview_window("main") {
                if w.is_visible().unwrap_or(false) && w.is_focused().unwrap_or(false) { let _ = w.hide(); }
                else { crate::show_main(app); }
            }
        }
        "pause" => { crate::toggle_recording(app); }
        "island" => { let _ = app.emit("island-toggle", ()); }
        "studio" => super::open_studio(app, "widgets"),
        "widgets" => {
            if let Some(st) = app.try_state::<std::sync::Arc<super::widgets::WidgetStore>>() {
                let show = !st.visible();
                st.set_visible(show);
                if show { super::widgets::show_all(app) } else { super::widgets::hide_all(app) }
                let _ = app.emit("widgets-changed", ());
            }
        }
        a if a.starts_with("window.") => {
            let action = a.trim_start_matches("window.").to_string();
            // Shortcuts act on the app in front right now; if that's Cortex
            // itself (palette open), on the app behind it.
            let pid = super::macos::frontmost_app()
                .filter(|f| f.pid != std::process::id() as i32)
                .map(|f| f.pid)
                .or_else(|| app.try_state::<crate::AppState>().and_then(|s| s.last_front.lock().ok().map(|f| f.pid)));
            let Some(pid) = pid.filter(|p| *p > 0) else { return };
            let app = app.clone();
            tauri::async_runtime::spawn_blocking(move || {
                let r = super::window::perform(&app, pid, &action);
                let (icon, text) = match &r { Ok(l) => ("window", l.clone()), Err(e) => ("warning", e.clone()) };
                let _ = app.emit("island-toast", serde_json::json!({ "icon": icon, "text": text }));
            });
        }
        _ => {}
    }
}

/* ─── IPC ───────────────────────────────────────────────── */

#[tauri::command]
pub fn shortcuts_get(app: AppHandle) -> Vec<ShortcutEntry> {
    let errors: HashMap<String, String> = match app.try_state::<Registered>() {
        Some(r) => { let g = r.1.lock().map(|g| g.clone()).unwrap_or_default(); g }
        None => HashMap::new(),
    };
    let eff: HashMap<String, String> = effective().into_iter().collect();
    DEFAULTS.iter().map(|(id, label, group, def)| ShortcutEntry {
        id: id.to_string(), label: label.to_string(), group: group.to_string(),
        accel: eff.get(*id).cloned().unwrap_or_default(), default: def.to_string(),
        error: errors.get(*id).cloned(),
    }).collect()
}

/// Set (or clear with "") one shortcut. Rejects invalid or duplicate combos.
#[tauri::command]
pub fn shortcut_set(id: String, accel: String, app: AppHandle) -> Result<Vec<ShortcutEntry>, String> {
    if !DEFAULTS.iter().any(|(k, ..)| *k == id) { return Err(format!("unknown shortcut {id}")); }
    let accel = accel.trim().to_string();
    if id == "pause" && accel.is_empty() {
        return Err("The pause shortcut can't be turned off — it's a privacy safeguard".into());
    }
    if !accel.is_empty() {
        let sc = parse(&accel)?;
        if let Some((other, _)) = effective().into_iter()
            .find(|(k, a)| *k != id && !a.is_empty() && parse(a).map(|o| o.id() == sc.id()).unwrap_or(false)) {
            let label = DEFAULTS.iter().find(|(k, ..)| *k == other).map(|(_, l, ..)| *l).unwrap_or(&other);
            return Err(format!("Already used for “{label}”"));
        }
    }
    let mut cfg = crate::config_ipc::load_config();
    let def = DEFAULTS.iter().find(|(k, ..)| *k == id).map(|(.., d)| *d).unwrap_or("");
    if accel == def { cfg.shortcuts.remove(&id); } else { cfg.shortcuts.insert(id, accel); }
    crate::config_ipc::save_config(&cfg).map_err(|e| e.to_string())?;
    register_all(&app);
    Ok(shortcuts_get(app))
}

/// Pause all hotkeys while Settings records a new combination (so pressing
/// ⌘K in the recorder doesn't toggle the palette).
#[tauri::command]
pub fn shortcuts_suspend(suspend: bool, app: AppHandle) {
    if suspend { let _ = app.global_shortcut().unregister_all(); } else { register_all(&app); }
}

#[tauri::command]
pub fn shortcut_reset_all(app: AppHandle) -> Result<Vec<ShortcutEntry>, String> {
    let mut cfg = crate::config_ipc::load_config();
    cfg.shortcuts.clear();
    crate::config_ipc::save_config(&cfg).map_err(|e| e.to_string())?;
    register_all(&app);
    Ok(shortcuts_get(app))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_default_parses_and_is_unique() {
        let mut seen = HashMap::new();
        for (id, _, _, accel) in DEFAULTS {
            if accel.is_empty() { continue; }
            let sc = parse(accel).unwrap_or_else(|e| panic!("{id}: {e}"));
            if let Some(prev) = seen.insert(sc.id(), *id) { panic!("{id} duplicates {prev}"); }
        }
    }

    #[test]
    fn rejects_garbage() {
        assert!(parse("Hyper+Banana").is_err());
        assert!(parse("Alt+Space").is_ok());
    }
}
