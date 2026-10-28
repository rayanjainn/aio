//! Two docks:
//!
//! * **macOS Dock** — read and edit `com.apple.dock` (size, magnification,
//!   position, auto-hide, effects, app order, spacers). Changes round-trip the
//!   whole domain through `defaults export/import` as a plist, then restart the
//!   Dock. The original domain is backed up once to `~/.cortex/dock-backup.plist`.
//! * **Cortex Dock** — a Liquid Glass bar of apps, folders and live mini
//!   widgets (clock, battery, CPU, now playing, weather) on any screen edge.

use plist::{Dictionary, Value};
use serde::{Deserialize, Serialize};
use std::{
    path::PathBuf,
    sync::{atomic::{AtomicBool, Ordering}, Arc, Mutex},
    time::Duration,
};
use tauri::{AppHandle, Emitter, Manager, WebviewUrl, WebviewWindowBuilder};

pub const LABEL: &str = "dock";

/* ═══ macOS Dock preferences ═════════════════════════════ */

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct DockTile {
    /// "app" | "folder" | "spacer" | "small-spacer"
    pub kind:  String,
    pub label: String,
    pub path:  String,
}

#[derive(Debug, Clone, Serialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct MacDock {
    pub supported:                bool,
    pub autohide:                 bool,
    pub tilesize:                 f64,
    pub magnification:            bool,
    pub largesize:                f64,
    pub orientation:              String,
    pub mineffect:                String,
    pub show_recents:             bool,
    pub autohide_delay:           f64,
    pub autohide_time_modifier:   f64,
    pub static_only:              bool,
    pub launchanim:               bool,
    pub minimize_to_application:  bool,
    pub show_process_indicators:  bool,
    pub scroll_to_open:           bool,
    pub apps:                     Vec<DockTile>,
    pub has_backup:               bool,
    /// Auto-hide with a huge reveal delay — effectively gone.
    pub hidden:                   bool,
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MacDockPatch {
    pub autohide:                Option<bool>,
    pub tilesize:                Option<f64>,
    pub magnification:           Option<bool>,
    pub largesize:               Option<f64>,
    pub orientation:             Option<String>,
    pub mineffect:               Option<String>,
    pub show_recents:            Option<bool>,
    pub autohide_delay:          Option<f64>,
    pub autohide_time_modifier:  Option<f64>,
    pub static_only:             Option<bool>,
    pub launchanim:              Option<bool>,
    pub minimize_to_application: Option<bool>,
    pub show_process_indicators: Option<bool>,
    pub scroll_to_open:          Option<bool>,
    pub hidden:                  Option<bool>,
}

fn b(d: &Dictionary, k: &str, def: bool) -> bool {
    match d.get(k) {
        Some(Value::Boolean(v)) => *v,
        Some(Value::Integer(i)) => i.as_signed().unwrap_or(0) != 0,
        _ => def,
    }
}
fn f(d: &Dictionary, k: &str, def: f64) -> f64 {
    match d.get(k) {
        Some(Value::Real(v)) => *v,
        Some(Value::Integer(i)) => i.as_signed().unwrap_or(0) as f64,
        _ => def,
    }
}
fn s(d: &Dictionary, k: &str, def: &str) -> String {
    d.get(k).and_then(Value::as_string).unwrap_or(def).to_string()
}

fn url_to_path(url: &str) -> String {
    let p = url.strip_prefix("file://").unwrap_or(url);
    let p = p.trim_end_matches('/');
    url::Url::parse(&format!("file://{p}")).ok()
        .and_then(|u| u.to_file_path().ok())
        .map(|pb| pb.to_string_lossy().to_string())
        .unwrap_or_else(|| p.to_string())
}

fn tile_from_value(v: &Value) -> Option<DockTile> {
    let d = v.as_dictionary()?;
    let ty = d.get("tile-type").and_then(Value::as_string).unwrap_or("");
    let data = d.get("tile-data").and_then(Value::as_dictionary);
    match ty {
        "spacer-tile" => Some(DockTile { kind: "spacer".into(), label: String::new(), path: String::new() }),
        "small-spacer-tile" => Some(DockTile { kind: "small-spacer".into(), label: String::new(), path: String::new() }),
        "file-tile" | "directory-tile" => {
            let data = data?;
            let url = data.get("file-data").and_then(Value::as_dictionary)
                .and_then(|fd| fd.get("_CFURLString")).and_then(Value::as_string).unwrap_or("");
            let path = url_to_path(url);
            let label = data.get("file-label").and_then(Value::as_string).map(String::from)
                .unwrap_or_else(|| std::path::Path::new(&path).file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_default());
            Some(DockTile { kind: if ty == "file-tile" { "app".into() } else { "folder".into() }, label, path })
        }
        _ => None,
    }
}

/// Parse a `com.apple.dock` domain dictionary into the UI model.
pub fn parse_dock(d: &Dictionary) -> MacDock {
    let apps = d.get("persistent-apps").and_then(Value::as_array)
        .map(|a| a.iter().filter_map(tile_from_value).collect()).unwrap_or_default();
    MacDock {
        supported: true,
        autohide: b(d, "autohide", false),
        tilesize: f(d, "tilesize", 48.0),
        magnification: b(d, "magnification", false),
        largesize: f(d, "largesize", 64.0),
        orientation: s(d, "orientation", "bottom"),
        mineffect: s(d, "mineffect", "genie"),
        show_recents: b(d, "show-recents", true),
        autohide_delay: f(d, "autohide-delay", 0.5),
        autohide_time_modifier: f(d, "autohide-time-modifier", 0.5),
        static_only: b(d, "static-only", false),
        launchanim: b(d, "launchanim", true),
        minimize_to_application: b(d, "minimize-to-application", false),
        show_process_indicators: b(d, "show-process-indicators", true),
        scroll_to_open: b(d, "scroll-to-open", false),
        apps,
        has_backup: false,
        hidden: is_hidden(d),
    }
}

/// Apply a settings patch, validating every value against what the Dock accepts.
pub fn apply_patch(d: &mut Dictionary, p: &MacDockPatch) -> Result<(), String> {
    let mut set_b = |k: &str, v: Option<bool>| if let Some(v) = v { d.insert(k.into(), Value::Boolean(v)); };
    set_b("autohide", p.autohide);
    set_b("magnification", p.magnification);
    set_b("show-recents", p.show_recents);
    set_b("static-only", p.static_only);
    set_b("launchanim", p.launchanim);
    set_b("minimize-to-application", p.minimize_to_application);
    set_b("show-process-indicators", p.show_process_indicators);
    set_b("scroll-to-open", p.scroll_to_open);
    if let Some(v) = p.tilesize { d.insert("tilesize".into(), Value::Real(v.clamp(16.0, 128.0).round())); }
    if let Some(v) = p.largesize { d.insert("largesize".into(), Value::Real(v.clamp(16.0, 128.0).round())); }
    if let Some(v) = p.autohide_delay { d.insert("autohide-delay".into(), Value::Real(v.clamp(0.0, 5.0))); }
    if let Some(v) = p.autohide_time_modifier { d.insert("autohide-time-modifier".into(), Value::Real(v.clamp(0.0, 3.0))); }
    if let Some(o) = &p.orientation {
        if !["bottom", "left", "right"].contains(&o.as_str()) { return Err(format!("invalid orientation {o}")); }
        d.insert("orientation".into(), Value::String(o.clone()));
    }
    if let Some(h) = p.hidden { hide_in(d, h); }
    if let Some(m) = &p.mineffect {
        if !["genie", "scale", "suck"].contains(&m.as_str()) { return Err(format!("invalid minimize effect {m}")); }
        d.insert("mineffect".into(), Value::String(m.clone()));
    }
    Ok(())
}

fn path_of(v: &Value) -> Option<String> {
    let t = tile_from_value(v)?;
    (t.kind == "app" || t.kind == "folder").then_some(t.path)
}

fn new_tile(t: &DockTile) -> Option<Value> {
    let mut d = Dictionary::new();
    match t.kind.as_str() {
        "spacer" | "small-spacer" => {
            d.insert("tile-data".into(), Value::Dictionary(Dictionary::new()));
            d.insert("tile-type".into(), Value::String(format!("{}-tile", t.kind)));
        }
        "app" | "folder" => {
            if t.path.is_empty() { return None; }
            let mut url = url::Url::from_file_path(&t.path).ok()?.to_string();
            if !url.ends_with('/') { url.push('/'); }
            let mut fd = Dictionary::new();
            fd.insert("_CFURLString".into(), Value::String(url));
            fd.insert("_CFURLStringType".into(), Value::Integer(15.into()));
            let mut data = Dictionary::new();
            data.insert("file-data".into(), Value::Dictionary(fd));
            if !t.label.is_empty() { data.insert("file-label".into(), Value::String(t.label.clone())); }
            d.insert("tile-data".into(), Value::Dictionary(data));
            d.insert("tile-type".into(), Value::String(if t.kind == "app" { "file-tile" } else { "directory-tile" }.into()));
        }
        _ => return None,
    }
    Some(Value::Dictionary(d))
}

/// Rebuild `persistent-apps` in the given order. Existing tiles are reused
/// verbatim (they carry bookmarks/GUIDs the Dock relies on); only genuinely
/// new apps and spacers get fresh tiles.
pub fn set_apps(d: &mut Dictionary, tiles: &[DockTile]) {
    let existing: Vec<Value> = d.get("persistent-apps").and_then(Value::as_array).cloned().unwrap_or_default();
    let mut used = vec![false; existing.len()];
    let out: Vec<Value> = tiles.iter().filter_map(|t| {
        if t.kind == "app" || t.kind == "folder" {
            if let Some(i) = existing.iter().enumerate()
                .position(|(i, v)| !used[i] && path_of(v).as_deref() == Some(t.path.as_str())) {
                used[i] = true;
                return Some(existing[i].clone());
            }
        }
        new_tile(t)
    }).collect();
    d.insert("persistent-apps".into(), Value::Array(out));
}

fn backup_path() -> PathBuf { dirs::home_dir().unwrap_or_default().join(".cortex/dock-backup.plist") }

#[cfg(target_os = "macos")]
fn export_domain() -> Result<Dictionary, String> {
    let out = std::process::Command::new("defaults").args(["export", "com.apple.dock", "-"]).output()
        .map_err(|e| e.to_string())?;
    if !out.status.success() { return Err("could not read Dock preferences".into()); }
    Value::from_reader(std::io::Cursor::new(out.stdout)).map_err(|e| e.to_string())?
        .into_dictionary().ok_or_else(|| "unexpected Dock preferences format".into())
}

#[cfg(target_os = "macos")]
fn import_domain(d: &Dictionary) -> Result<(), String> {
    use std::io::Write;
    // First write ever: keep a pristine copy so "Restore" can undo everything.
    let bp = backup_path();
    if !bp.exists() {
        if let Ok(orig) = export_domain() {
            let _ = std::fs::create_dir_all(bp.parent().unwrap_or(&bp));
            let _ = Value::Dictionary(orig).to_file_xml(&bp);
        }
    }
    let mut xml = Vec::new();
    Value::Dictionary(d.clone()).to_writer_xml(&mut xml).map_err(|e| e.to_string())?;
    let mut child = std::process::Command::new("defaults").args(["import", "com.apple.dock", "-"])
        .stdin(std::process::Stdio::piped()).spawn().map_err(|e| e.to_string())?;
    child.stdin.take().ok_or("no stdin")?.write_all(&xml).map_err(|e| e.to_string())?;
    if !child.wait().map_err(|e| e.to_string())?.success() { return Err("defaults import failed".into()); }
    let _ = std::process::Command::new("killall").arg("Dock").status();
    Ok(())
}

#[tauri::command]
pub async fn macos_dock_get() -> MacDock {
    #[cfg(target_os = "macos")]
    {
        return tokio::task::spawn_blocking(|| {
            export_domain().map(|d| MacDock { has_backup: backup_path().exists(), ..parse_dock(&d) }).unwrap_or_default()
        }).await.unwrap_or_default();
    }
    #[allow(unreachable_code)]
    MacDock::default()
}

#[tauri::command]
pub async fn macos_dock_set(patch: MacDockPatch) -> Result<MacDock, String> {
    #[cfg(target_os = "macos")]
    {
        return tokio::task::spawn_blocking(move || {
            let mut d = export_domain()?;
            apply_patch(&mut d, &patch)?;
            import_domain(&d)?;
            Ok(MacDock { has_backup: true, ..parse_dock(&d) })
        }).await.map_err(|e| e.to_string())?;
    }
    #[allow(unreachable_code)]
    { let _ = patch; Err("The system Dock can only be customized on macOS".into()) }
}

#[tauri::command]
pub async fn macos_dock_set_apps(apps: Vec<DockTile>) -> Result<MacDock, String> {
    #[cfg(target_os = "macos")]
    {
        return tokio::task::spawn_blocking(move || {
            let mut d = export_domain()?;
            set_apps(&mut d, &apps);
            import_domain(&d)?;
            Ok(MacDock { has_backup: true, ..parse_dock(&d) })
        }).await.map_err(|e| e.to_string())?;
    }
    #[allow(unreachable_code)]
    { let _ = apps; Err("The system Dock can only be customized on macOS".into()) }
}

#[tauri::command]
pub async fn macos_dock_restore() -> Result<MacDock, String> {
    #[cfg(target_os = "macos")]
    {
        return tokio::task::spawn_blocking(|| {
            let bp = backup_path();
            let d = Value::from_file(&bp).map_err(|_| "No backup yet — nothing has been changed".to_string())?
                .into_dictionary().ok_or("corrupt backup")?;
            import_domain(&d)?;
            let _ = std::fs::remove_file(&bp);
            Ok(parse_dock(&d))
        }).await.map_err(|e| e.to_string())?;
    }
    #[allow(unreachable_code)]
    Err("The system Dock can only be customized on macOS".into())
}

/* ═══ Cortex Dock ════════════════════════════════════════ */

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", tag = "type")]
pub enum DockItem {
    App { name: String, path: String },
    Folder { name: String, path: String },
    /// Live mini widget: "clock" | "battery" | "cpu" | "music" | "weather" | "focus".
    Widget { kind: String, #[serde(default)] config: serde_json::Value },
    Separator,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub struct DockConfig {
    pub enabled:          bool,
    /// "bottom" | "left" | "right" | "top"
    pub edge:             String,
    pub icon_size:        f64,
    pub magnify:          bool,
    pub autohide:         bool,
    pub show_running:     bool,
    /// Auto-hide the macOS Dock while the Cortex Dock is on.
    pub hide_system_dock: bool,
    pub items:            Vec<DockItem>,
}

impl Default for DockConfig {
    fn default() -> Self {
        let app = |n: &str, p: &str| DockItem::App { name: n.into(), path: p.into() };
        Self {
            enabled: false,
            edge: "bottom".into(),
            icon_size: 48.0,
            magnify: true,
            autohide: false,
            show_running: true,
            hide_system_dock: false,
            items: vec![
                app("Finder", "/System/Library/CoreServices/Finder.app"),
                app("Safari", "/Applications/Safari.app"),
                app("Mail", "/System/Applications/Mail.app"),
                app("Notes", "/System/Applications/Notes.app"),
                app("Terminal", "/System/Applications/Utilities/Terminal.app"),
                DockItem::Separator,
                DockItem::Widget { kind: "music".into(), config: serde_json::Value::Null },
                DockItem::Widget { kind: "cpu".into(), config: serde_json::Value::Null },
                DockItem::Widget { kind: "battery".into(), config: serde_json::Value::Null },
                DockItem::Widget { kind: "clock".into(), config: serde_json::Value::Null },
            ],
        }
    }
}

pub struct DockState {
    path:     PathBuf,
    pub cfg:  Mutex<DockConfig>,
    /// Logical size the frontend asked for (content-sized bar).
    size:     Mutex<(f64, f64)>,
    /// Glass margins (top, right, bottom, left) — headroom for magnification.
    inset:    Mutex<(f64, f64, f64, f64)>,
    revealed: AtomicBool,
}

impl DockState {
    pub fn load(path: PathBuf) -> Self {
        let cfg = std::fs::read_to_string(&path).ok()
            .and_then(|s| serde_json::from_str(&s).ok()).unwrap_or_default();
        Self { path, cfg: Mutex::new(cfg), size: Mutex::new((600.0, 76.0)), inset: Mutex::new((0.0, 0.0, 0.0, 0.0)), revealed: AtomicBool::new(true) }
    }
    pub fn config(&self) -> DockConfig { self.cfg.lock().map(|c| c.clone()).unwrap_or_default() }
}

/// Where the bar goes: centred on `edge` of `area`, `margin` points in.
pub fn dock_frame(area: super::widgets::Rect, edge: &str, w: f64, h: f64, margin: f64) -> (f64, f64) {
    let (ax, ay, aw, ah) = area;
    match edge {
        "left"  => (ax + margin, ay + (ah - h) / 2.0),
        "right" => (ax + aw - w - margin, ay + (ah - h) / 2.0),
        "top"   => (ax + (aw - w) / 2.0, ay + margin),
        _       => (ax + (aw - w) / 2.0, ay + ah - h - margin),
    }
}

fn primary_area(app: &AppHandle) -> super::widgets::Rect {
    match app.primary_monitor().ok().flatten() {
        Some(m) => {
            let s = m.scale_factor();
            let r = m.work_area();
            (r.position.x as f64 / s, r.position.y as f64 / s, r.size.width as f64 / s, r.size.height as f64 / s)
        }
        None => (0.0, 0.0, 1440.0, 900.0),
    }
}

fn place(app: &AppHandle) {
    let (Some(st), Some(win)) = (app.try_state::<Arc<DockState>>(), app.get_webview_window(LABEL)) else { return };
    let cfg = st.config();
    let (w, h) = st.size.lock().map(|s| *s).unwrap_or((600.0, 76.0));
    let (x, y) = dock_frame(primary_area(app), &cfg.edge, w, h, 4.0);
    // Only touch the native window when something actually changed — every
    // resize makes WebKit re-composite, which read as a blank "buffering" flash.
    let scale = win.scale_factor().unwrap_or(1.0);
    let same_size = win.inner_size().map(|s| ((s.width as f64 / scale) - w).abs() < 1.0 && ((s.height as f64 / scale) - h).abs() < 1.0).unwrap_or(false);
    let same_pos = win.outer_position().map(|p| ((p.x as f64 / scale) - x).abs() < 1.0 && ((p.y as f64 / scale) - y).abs() < 1.0).unwrap_or(false);
    if !same_size { let _ = win.set_size(tauri::LogicalSize::new(w, h)); }
    if !same_pos { let _ = win.set_position(tauri::LogicalPosition::new(x, y)); }
    let (t, r, b, l) = st.inset.lock().map(|i| *i).unwrap_or_default();
    super::glass::set_inset(&win, t, r, b, l);
}

fn open(app: &AppHandle) -> tauri::Result<()> {
    if app.get_webview_window(LABEL).is_some() { place(app); return Ok(()); }
    let win = WebviewWindowBuilder::new(app, LABEL, WebviewUrl::App("index.html#/dock".into()))
        .title("Cortex Dock")
        .decorations(false).transparent(true).shadow(false).resizable(false)
        .skip_taskbar(true).focused(false).always_on_top(true)
        .visible_on_all_workspaces(true).accept_first_mouse(true)
        .inner_size(600.0, 76.0)
        .build()?;
    super::glass::apply(&win, 28.0);
    #[cfg(target_os = "macos")]
    super::widgets::mac::float_everywhere(&win);
    place(app);
    Ok(())
}

fn apply(app: &AppHandle, prev: Option<&DockConfig>) {
    let Some(st) = app.try_state::<Arc<DockState>>() else { return };
    let cfg = st.config();
    // Create / destroy the window only when the dock is switched on or off;
    // every other change is pushed live to the open window via `dock-config`.
    if prev.map(|p| p.enabled) != Some(cfg.enabled) {
        if cfg.enabled {
            if let Err(e) = open(app) { tracing::warn!(target: "aio_cortex_lib", "dock: {e}"); }
        } else if let Some(w) = app.get_webview_window(LABEL) {
            let _ = w.destroy();
        }
    }
    // Keep the system Dock out of the way only while ours is showing.
    let want_hidden = cfg.enabled && cfg.hide_system_dock;
    let was_hidden = prev.map(|p| p.enabled && p.hide_system_dock);
    if was_hidden != Some(want_hidden) && (want_hidden || was_hidden == Some(true)) {
        tauri::async_runtime::spawn_blocking(move || {
            if let Err(e) = set_system_dock_hidden(want_hidden) {
                tracing::warn!(target: "aio_cortex_lib", "system dock: {e}");
            }
        });
    }
}

/// Fully hide (or restore) the macOS Dock: auto-hide with a 1000 s reveal
/// delay, so it never slides in. Plain auto-hide still pops up at the edge.
pub fn set_system_dock_hidden(hidden: bool) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        let mut d = export_domain()?;
        if hidden == is_hidden(&d) { return Ok(()); }
        hide_in(&mut d, hidden);
        return import_domain(&d);
    }
    #[allow(unreachable_code)]
    { let _ = hidden; Err("macOS only".into()) }
}

/// Hide / restore the macOS Dock on its own (Studio switch).
#[tauri::command]
pub async fn system_dock_set_hidden(hidden: bool) -> Result<(), String> {
    tokio::task::spawn_blocking(move || set_system_dock_hidden(hidden)).await.map_err(|e| e.to_string())?
}

fn is_hidden(d: &Dictionary) -> bool { b(d, "autohide", false) && f(d, "autohide-delay", 0.0) >= 100.0 }

fn hide_in(d: &mut Dictionary, hidden: bool) {
    d.insert("autohide".into(), Value::Boolean(hidden));
    if hidden {
        d.insert("autohide-delay".into(), Value::Real(1000.0));
    } else {
        d.remove("autohide-delay");
    }
}

pub fn init(app: &AppHandle, data_dir: &std::path::Path) {
    let st = Arc::new(DockState::load(data_dir.join("dock.json")));
    app.manage(st.clone());
    apply(app, None);
    spawn_autohide(app.clone(), st);
}

/// Auto-hide: poll the cursor (~15 Hz); reveal when it touches the dock's
/// screen edge, hide once it has left the bar for a moment.
fn spawn_autohide(app: AppHandle, st: Arc<DockState>) {
    tauri::async_runtime::spawn(async move {
        let mut away_ticks = 0u32;
        loop {
            tokio::time::sleep(Duration::from_millis(66)).await;
            let cfg = st.config();
            let Some(win) = app.get_webview_window(LABEL) else { continue };
            if !cfg.enabled || !cfg.autohide {
                if !st.revealed.swap(true, Ordering::Relaxed) { let _ = win.show(); let _ = app.emit_to(LABEL, "dock-reveal", true); }
                continue;
            }
            let Ok(p) = app.cursor_position() else { continue };
            let scale = win.scale_factor().unwrap_or(1.0);
            let (cx, cy) = (p.x / scale, p.y / scale);
            let (ax, ay, aw, ah) = primary_area(&app);
            let (Ok(pos), Ok(size)) = (win.outer_position(), win.outer_size()) else { continue };
            let (wx, wy, ww, wh) = (pos.x as f64 / scale, pos.y as f64 / scale, size.width as f64 / scale, size.height as f64 / scale);
            let over = cx >= wx - 12.0 && cx <= wx + ww + 12.0 && cy >= wy - 12.0 && cy <= wy + wh + 12.0;
            let at_edge = match cfg.edge.as_str() {
                "left"  => cx <= ax + 3.0 && cy >= wy && cy <= wy + wh,
                "right" => cx >= ax + aw - 3.0 && cy >= wy && cy <= wy + wh,
                "top"   => cy <= ay + 3.0 && cx >= wx && cx <= wx + ww,
                _       => cy >= ay + ah - 3.0 && cx >= wx && cx <= wx + ww,
            } || {
                // Work area excludes the menu bar / system Dock: also accept the true screen edge.
                let bottom_edge = app.primary_monitor().ok().flatten()
                    .map(|m| (m.position().y as f64 + m.size().height as f64) / m.scale_factor()).unwrap_or(ay + ah);
                cfg.edge == "bottom" && cy >= bottom_edge - 3.0 && cx >= wx && cx <= wx + ww
            };
            let revealed = st.revealed.load(Ordering::Relaxed);
            if !revealed && at_edge {
                st.revealed.store(true, Ordering::Relaxed);
                away_ticks = 0;
                // Hidden windows keep their geometry, so measure from that.
                let _ = win.show();
                let _ = app.emit_to(LABEL, "dock-reveal", true);
            } else if revealed && !over {
                away_ticks += 1;
                if away_ticks > 8 {
                    st.revealed.store(false, Ordering::Relaxed);
                    let _ = app.emit_to(LABEL, "dock-reveal", false);
                    // Let the slide-out play, then hide the window — the native
                    // glass would otherwise linger as an empty slab.
                    let w2 = win.clone();
                    let st2 = st.clone();
                    tauri::async_runtime::spawn(async move {
                        tokio::time::sleep(Duration::from_millis(260)).await;
                        if !st2.revealed.load(Ordering::Relaxed) { let _ = w2.hide(); }
                    });
                }
            } else {
                away_ticks = 0;
            }
        }
    });
}

#[tauri::command]
pub fn dock_get_config(app: AppHandle) -> DockConfig {
    app.try_state::<Arc<DockState>>().map(|s| s.config()).unwrap_or_default()
}

#[tauri::command]
pub fn dock_set_config(cfg: DockConfig, app: AppHandle) -> Result<DockConfig, String> {
    let st = app.try_state::<Arc<DockState>>().ok_or("dock not ready")?;
    let prev = st.config();
    let mut cfg = cfg;
    cfg.icon_size = cfg.icon_size.clamp(28.0, 96.0);
    if let Ok(mut g) = st.cfg.lock() { *g = cfg.clone(); }
    super::widgets::write_atomic(&st.path, &cfg).map_err(|e| e.to_string())?;
    apply(&app, Some(&prev));
    place(&app);
    let _ = app.emit("dock-config", &cfg);
    Ok(cfg)
}

/// The bar measured its content — size the window to fit, re-centre it, and
/// keep the glass on the bar itself (`inset` = headroom around it).
#[tauri::command]
pub fn dock_resize(w: f64, h: f64, inset: Option<[f64; 4]>, app: AppHandle) {
    if let Some(st) = app.try_state::<Arc<DockState>>() {
        if let Ok(mut s) = st.size.lock() { *s = (w.clamp(60.0, 4000.0).ceil(), h.clamp(40.0, 4000.0).ceil()); }
        if let (Some([t, r, b, l]), Ok(mut i)) = (inset, st.inset.lock()) { *i = (t, r, b, l); }
        place(&app);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> Dictionary {
        let xml = r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>autohide</key><true/>
  <key>tilesize</key><integer>52</integer>
  <key>orientation</key><string>left</string>
  <key>mod-count</key><integer>12</integer>
  <key>persistent-apps</key><array>
    <dict><key>GUID</key><integer>99</integer><key>tile-data</key><dict>
      <key>file-data</key><dict><key>_CFURLString</key><string>file:///Applications/Safari.app/</string><key>_CFURLStringType</key><integer>15</integer></dict>
      <key>file-label</key><string>Safari</string></dict><key>tile-type</key><string>file-tile</string></dict>
    <dict><key>tile-data</key><dict/><key>tile-type</key><string>spacer-tile</string></dict>
    <dict><key>tile-data</key><dict>
      <key>file-data</key><dict><key>_CFURLString</key><string>file:///System/Applications/Visual%20Studio%20Code.app/</string><key>_CFURLStringType</key><integer>15</integer></dict>
      </dict><key>tile-type</key><string>file-tile</string></dict>
  </array>
</dict></plist>"#;
        Value::from_reader_xml(xml.as_bytes()).unwrap().into_dictionary().unwrap()
    }

    #[test]
    fn parses_settings_and_tiles() {
        let m = parse_dock(&sample());
        assert!(m.autohide);
        assert_eq!(m.tilesize, 52.0);
        assert_eq!(m.orientation, "left");
        assert!(m.show_recents, "default when absent");
        assert_eq!(m.apps.len(), 3);
        assert_eq!(m.apps[0], DockTile { kind: "app".into(), label: "Safari".into(), path: "/Applications/Safari.app".into() });
        assert_eq!(m.apps[1].kind, "spacer");
        assert_eq!(m.apps[2].path, "/System/Applications/Visual Studio Code.app", "percent-decoded");
        assert_eq!(m.apps[2].label, "Visual Studio Code");
    }

    #[test]
    fn patch_validates_and_clamps() {
        let mut d = sample();
        apply_patch(&mut d, &MacDockPatch { tilesize: Some(400.0), magnification: Some(true), ..Default::default() }).unwrap();
        assert_eq!(d.get("tilesize"), Some(&Value::Real(128.0)));
        assert_eq!(d.get("magnification"), Some(&Value::Boolean(true)));
        assert!(apply_patch(&mut d, &MacDockPatch { orientation: Some("top".into()), ..Default::default() }).is_err());
        assert!(apply_patch(&mut d, &MacDockPatch { mineffect: Some("explode".into()), ..Default::default() }).is_err());
        apply_patch(&mut d, &MacDockPatch { hidden: Some(true), ..Default::default() }).unwrap();
        assert!(parse_dock(&d).hidden);
        apply_patch(&mut d, &MacDockPatch { hidden: Some(false), ..Default::default() }).unwrap();
        assert!(!parse_dock(&d).hidden && !parse_dock(&d).autohide);
        assert_eq!(d.get("mod-count"), Some(&Value::Integer(12.into())), "unrelated keys untouched");
    }

    #[test]
    fn reorder_keeps_existing_tiles_and_adds_new() {
        let mut d = sample();
        let tiles = vec![
            DockTile { kind: "app".into(), label: "".into(), path: "/System/Applications/Visual Studio Code.app".into() },
            DockTile { kind: "app".into(), label: "Notes".into(), path: "/System/Applications/Notes.app".into() },
            DockTile { kind: "small-spacer".into(), label: "".into(), path: "".into() },
            DockTile { kind: "app".into(), label: "Safari".into(), path: "/Applications/Safari.app".into() },
        ];
        set_apps(&mut d, &tiles);
        let arr = d.get("persistent-apps").unwrap().as_array().unwrap();
        assert_eq!(arr.len(), 4);
        // Safari's original dict (with its GUID) is reused, not recreated.
        assert_eq!(arr[3].as_dictionary().unwrap().get("GUID"), Some(&Value::Integer(99.into())));
        let back = parse_dock(&d);
        assert_eq!(back.apps.iter().map(|t| t.kind.as_str()).collect::<Vec<_>>(), ["app", "app", "small-spacer", "app"]);
        assert_eq!(back.apps[1].path, "/System/Applications/Notes.app");
        // spacer removed from original order is gone
        assert!(!back.apps.iter().any(|t| t.kind == "spacer"));
    }

    #[test]
    fn frame_positions() {
        let area = (0.0, 25.0, 1440.0, 875.0);
        assert_eq!(dock_frame(area, "bottom", 400.0, 70.0, 8.0), (520.0, 822.0));
        assert_eq!(dock_frame(area, "left", 70.0, 400.0, 8.0), (8.0, 262.5));
        assert_eq!(dock_frame(area, "right", 70.0, 400.0, 8.0), (1362.0, 262.5));
    }

    #[test]
    fn config_roundtrip_and_defaults() {
        let c = DockConfig::default();
        let j = serde_json::to_string(&c).unwrap();
        assert!(j.contains(r#""type":"separator""#));
        let back: DockConfig = serde_json::from_str(&j).unwrap();
        assert_eq!(back, c);
        let partial: DockConfig = serde_json::from_str(r#"{"enabled":true}"#).unwrap();
        assert!(partial.enabled);
        assert_eq!(partial.edge, "bottom");
    }
}
