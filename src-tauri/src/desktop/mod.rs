//! Desktop layer: widget windows, the Cortex dock, macOS Dock preferences,
//! and the live data providers behind them.

pub mod dock;
pub mod glass;
pub mod providers;
pub mod widgets;

use std::sync::Arc;
use tauri::{AppHandle, Manager};

/// Load persisted widgets and open their windows (if widgets are visible).
pub fn init(app: &AppHandle, data_dir: &std::path::Path) {
    let store = Arc::new(widgets::WidgetStore::load(data_dir.join("widgets.json")));
    let visible = store.visible();
    app.manage(store);
    if visible {
        widgets::show_all(app);
    }
    dock::init(app, data_dir);
}

/// Window events for desktop-layer windows. Returns true when handled.
pub fn on_window_event(window: &tauri::Window, event: &tauri::WindowEvent) -> bool {
    if window.label().starts_with(widgets::LABEL_PREFIX) {
        widgets::on_window_event(window, event);
        return true;
    }
    false
}

/// Bring up Cortex on the Widgets & Dock studio.
pub fn open_studio(app: &AppHandle, tab: &str) {
    use tauri::Emitter;
    crate::show_main(app);
    let _ = app.emit_to("main", "open-studio", tab);
}
