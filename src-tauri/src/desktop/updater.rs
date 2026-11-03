//! Automatic updates from GitHub Releases.
//!
//! On launch (after 20 s) and every 6 hours Cortex fetches
//! `releases/latest/download/latest.json`, verifies the update's minisign
//! signature against the public key in tauri.conf.json, downloads and
//! installs it in the background, then offers "Restart to Update" in the tray
//! and the Island. Turn it off in Settings → About (ui.autoUpdate = false).

use serde::Serialize;
use std::sync::Mutex;
use tauri::{AppHandle, Emitter, Manager};
use tauri_plugin_updater::UpdaterExt;

#[derive(Default)]
pub struct UpdateState {
    /// Version installed and waiting for a restart.
    pub ready: Mutex<Option<String>>,
    pub busy: Mutex<bool>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdateStatus {
    pub current: String,
    pub available: Option<String>,
    pub ready: Option<String>,
    pub notes: Option<String>,
    pub error: Option<String>,
}

fn auto_enabled() -> bool {
    crate::config_ipc::load_config().ui.get("autoUpdate").and_then(|v| v.as_bool()).unwrap_or(true)
}

fn set_tray(app: &AppHandle, text: &str) {
    if let Some(items) = app.try_state::<crate::TrayItems>() { let _ = items.update.set_text(text); }
}

/// Check; when `install`, download + install a newer version.
pub async fn check(app: &AppHandle, install: bool) -> UpdateStatus {
    let current = app.package_info().version.to_string();
    let st = app.state::<UpdateState>();
    let ready = st.ready.lock().ok().and_then(|g| g.clone());
    let mut status = UpdateStatus { current, available: None, ready: ready.clone(), notes: None, error: None };
    if ready.is_some() { return status; }
    {
        let Ok(mut b) = st.busy.lock() else { return status };
        if *b { return status; }
        *b = true;
    }
    let result: Result<(), String> = async {
        let updater = app.updater().map_err(|e| e.to_string())?;
        let Some(update) = updater.check().await.map_err(|e| e.to_string())? else { return Ok(()) };
        status.available = Some(update.version.clone());
        status.notes = update.body.clone();
        if !install { return Ok(()); }
        set_tray(app, &format!("Downloading {}…", update.version));
        update.download_and_install(|_, _| {}, || {}).await.map_err(|e| e.to_string())?;
        if let Ok(mut r) = st.ready.lock() { *r = Some(update.version.clone()); }
        status.ready = Some(update.version.clone());
        set_tray(app, &format!("Restart to Update ({})", update.version));
        let _ = app.emit("island-toast", serde_json::json!({ "icon": "check", "text": format!("Cortex {} ready — restart to update", update.version) }));
        let _ = app.emit("update-ready", &update.version);
        Ok(())
    }.await;
    if let Err(e) = result {
        tracing::warn!(target: "aio_cortex_lib", "update check failed: {e}");
        status.error = Some(e);
        if status.ready.is_none() { set_tray(app, "Check for Updates…"); }
    }
    if let Ok(mut b) = st.busy.lock() { *b = false; }
    status
}

pub fn init(app: &AppHandle) {
    app.manage(UpdateState::default());
    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        tokio::time::sleep(std::time::Duration::from_secs(20)).await;
        loop {
            if auto_enabled() { check(&app, true).await; }
            tokio::time::sleep(std::time::Duration::from_secs(6 * 3600)).await;
        }
    });
}

/// Tray item: restart into a ready update, or check now.
pub fn tray_clicked(app: &AppHandle) {
    let ready = app.try_state::<UpdateState>().and_then(|s| s.ready.lock().ok().and_then(|g| g.clone()));
    if ready.is_some() { app.restart(); }
    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        set_tray(&app, "Checking for Updates…");
        let s = check(&app, true).await;
        if s.ready.is_none() {
            set_tray(&app, "Check for Updates…");
            let text = match (&s.error, &s.available) {
                (Some(e), _) => format!("Update check failed: {e}"),
                (None, None) => format!("Cortex {} is up to date", s.current),
                (None, Some(v)) => format!("Cortex {v} is available"),
            };
            let _ = app.emit("island-toast", serde_json::json!({ "icon": "check", "text": text }));
        }
    });
}

#[tauri::command]
pub async fn update_check(install: Option<bool>, app: AppHandle) -> UpdateStatus {
    check(&app, install.unwrap_or(false)).await
}

#[tauri::command]
pub fn update_restart(app: AppHandle) {
    app.restart();
}
