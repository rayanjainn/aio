//! Desktop widgets — each widget is its own small, transparent, vibrancy-backed
//! window that lives on the desktop (or floats above apps). Layout and per-widget
//! config persist in `~/.cortex/widgets.json`; the frontend renders the widget
//! from `index.html#/widget/<id>`.

use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        Arc, Mutex,
    },
};
use tauri::{AppHandle, Emitter, Manager, WebviewUrl, WebviewWindowBuilder};

pub const LABEL_PREFIX: &str = "widget-";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Layer {
    /// Pinned to the desktop: behind every app window, fixed across Spaces.
    #[default]
    Desktop,
    /// Always on top of other windows.
    Floating,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Widget {
    pub id:     String,
    pub kind:   String,
    /// Logical (point) coordinates in the global desktop space.
    pub x:      f64,
    pub y:      f64,
    pub w:      f64,
    pub h:      f64,
    pub layer:  Layer,
    pub locked: bool,
    /// Kind-specific settings (city, timezone, note text, …).
    pub config: Value,
}

impl Default for Widget {
    fn default() -> Self {
        Self {
            id: String::new(), kind: String::new(),
            x: 0.0, y: 0.0, w: 170.0, h: 170.0,
            layer: Layer::Desktop, locked: false,
            config: Value::Object(Default::default()),
        }
    }
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WidgetPatch {
    pub x:      Option<f64>,
    pub y:      Option<f64>,
    pub w:      Option<f64>,
    pub h:      Option<f64>,
    pub layer:  Option<Layer>,
    pub locked: Option<bool>,
    /// Shallow-merged into the existing config object.
    pub config: Option<Value>,
}

#[derive(Debug, Default, Serialize, Deserialize)]
#[serde(default)]
struct OnDisk {
    visible: Option<bool>,
    items:   Vec<Widget>,
}

/* ─── Store ─────────────────────────────────────────────── */

pub struct WidgetStore {
    path:    PathBuf,
    items:   Mutex<Vec<Widget>>,
    visible: AtomicBool,
    /// Bumped on every change; the debounced writer only persists if it still
    /// holds the latest generation (window drags fire dozens of moves/sec).
    gen:     AtomicU64,
}

impl WidgetStore {
    pub fn load(path: PathBuf) -> Self {
        let disk: OnDisk = std::fs::read_to_string(&path)
            .ok()
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or_default();
        Self {
            path,
            items: Mutex::new(disk.items),
            visible: AtomicBool::new(disk.visible.unwrap_or(true)),
            gen: AtomicU64::new(0),
        }
    }

    pub fn list(&self) -> Vec<Widget> {
        self.items.lock().map(|g| g.clone()).unwrap_or_default()
    }

    pub fn get(&self, id: &str) -> Option<Widget> {
        self.items.lock().ok()?.iter().find(|w| w.id == id).cloned()
    }

    pub fn visible(&self) -> bool { self.visible.load(Ordering::Relaxed) }

    pub fn set_visible(&self, v: bool) {
        self.visible.store(v, Ordering::Relaxed);
        self.persist_now();
    }

    pub fn insert(&self, w: Widget) {
        if let Ok(mut g) = self.items.lock() { g.push(w); }
        self.persist_now();
    }

    pub fn update(&self, id: &str, patch: WidgetPatch) -> Option<Widget> {
        let out = {
            let mut g = self.items.lock().ok()?;
            let w = g.iter_mut().find(|w| w.id == id)?;
            apply_patch(w, patch);
            w.clone()
        };
        self.persist_now();
        Some(out)
    }

    /// Frame-only update from window move/resize events — persisted lazily.
    pub fn set_frame(self: &Arc<Self>, id: &str, x: Option<f64>, y: Option<f64>, w: Option<f64>, h: Option<f64>) {
        let changed = {
            let Ok(mut g) = self.items.lock() else { return };
            let Some(it) = g.iter_mut().find(|it| it.id == id) else { return };
            let before = (it.x, it.y, it.w, it.h);
            if let Some(v) = x { it.x = v.round(); }
            if let Some(v) = y { it.y = v.round(); }
            if let Some(v) = w { it.w = v.round(); }
            if let Some(v) = h { it.h = v.round(); }
            before != (it.x, it.y, it.w, it.h)
        };
        if changed { self.persist_debounced(); }
    }

    pub fn remove(&self, id: &str) -> bool {
        let removed = self.items.lock()
            .map(|mut g| { let n = g.len(); g.retain(|w| w.id != id); n != g.len() })
            .unwrap_or(false);
        if removed { self.persist_now(); }
        removed
    }

    fn persist_debounced(self: &Arc<Self>) {
        let gen = self.gen.fetch_add(1, Ordering::SeqCst) + 1;
        let me = self.clone();
        tauri::async_runtime::spawn(async move {
            tokio::time::sleep(std::time::Duration::from_millis(400)).await;
            if me.gen.load(Ordering::SeqCst) == gen { me.persist_now(); }
        });
    }

    fn persist_now(&self) {
        let disk = OnDisk { visible: Some(self.visible()), items: self.list() };
        if let Err(e) = write_atomic(&self.path, &disk) {
            tracing::warn!(target: "aio_cortex_lib", "widgets: save failed: {e}");
        }
    }
}

pub fn write_atomic<T: Serialize>(path: &std::path::Path, value: &T) -> anyhow::Result<()> {
    if let Some(dir) = path.parent() { std::fs::create_dir_all(dir)?; }
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, serde_json::to_vec_pretty(value)?)?;
    std::fs::rename(tmp, path)?;
    Ok(())
}

fn apply_patch(w: &mut Widget, p: WidgetPatch) {
    if let Some(v) = p.x { w.x = v; }
    if let Some(v) = p.y { w.y = v; }
    if let Some(v) = p.w { w.w = v.clamp(MIN_SIZE, MAX_SIZE); }
    if let Some(v) = p.h { w.h = v.clamp(MIN_SIZE, MAX_SIZE); }
    if let Some(v) = p.layer { w.layer = v; }
    if let Some(v) = p.locked { w.locked = v; }
    if let Some(Value::Object(patch)) = p.config {
        if !w.config.is_object() { w.config = Value::Object(Default::default()); }
        if let Value::Object(cfg) = &mut w.config {
            for (k, v) in patch {
                if v.is_null() { cfg.remove(&k); } else { cfg.insert(k, v); }
            }
        }
    }
}

const MIN_SIZE: f64 = 80.0;
const MAX_SIZE: f64 = 1200.0;
const GAP: f64 = 16.0;

/// Logical rectangle (x, y, w, h).
pub type Rect = (f64, f64, f64, f64);

fn overlaps(a: Rect, b: Rect) -> bool {
    a.0 < b.0 + b.2 + GAP && b.0 < a.0 + a.2 + GAP && a.1 < b.1 + b.3 + GAP && b.1 < a.1 + a.3 + GAP
}

/// First free slot for a `w`×`h` widget in `area`, scanning columns from the
/// right edge (where macOS puts widgets) top-to-bottom. Falls back to a
/// cascade from the top-right when the area is full.
pub fn find_free_spot(existing: &[Rect], w: f64, h: f64, area: Rect) -> (f64, f64) {
    let (ax, ay, aw, ah) = area;
    let step = 20.0;
    let right = ax + aw - w - GAP * 1.5;
    let bottom = ay + ah - h - GAP;
    let mut x = right;
    while x >= ax + GAP {
        let mut y = ay + GAP * 1.5;
        while y <= bottom {
            let cand = (x, y, w, h);
            match existing.iter().find(|r| overlaps(cand, **r)) {
                None => return (x.round(), y.round()),
                // Jump past the blocker instead of crawling 20pt at a time.
                Some(r) => y = (r.1 + r.3 + GAP).max(y + step),
            }
        }
        x -= step;
    }
    let n = existing.len() as f64;
    ((right - n * 24.0).max(ax), (ay + GAP * 1.5 + n * 24.0).min(bottom.max(ay)))
}

/* ─── Windows ───────────────────────────────────────────── */

pub fn label_for(id: &str) -> String { format!("{LABEL_PREFIX}{id}") }

/// Create (or re-show) the native window for a widget.
pub fn open_window(app: &AppHandle, w: &Widget) -> tauri::Result<()> {
    let label = label_for(&w.id);
    if let Some(win) = app.get_webview_window(&label) {
        let _ = win.show();
        return Ok(());
    }
    let url = WebviewUrl::App(format!("index.html#/widget/{}", w.id).into());
    let builder = WebviewWindowBuilder::new(app, &label, url)
        .title("Cortex Widget")
        .decorations(false)
        .transparent(true)
        .shadow(false)
        .resizable(false)
        .skip_taskbar(true)
        .focused(false)
        .visible_on_all_workspaces(true)
        .accept_first_mouse(true)
        .inner_size(w.w, w.h)
        .position(w.x, w.y)
        .always_on_top(w.layer == Layer::Floating)
        .always_on_bottom(w.layer == Layer::Desktop);
    let win = builder.build()?;
    super::glass::apply(&win, 22.0);
    apply_layer(&win, w.layer);
    Ok(())
}

pub fn close_window(app: &AppHandle, id: &str) {
    if let Some(win) = app.get_webview_window(&label_for(id)) {
        let _ = win.destroy();
    }
}

/// Re-apply the stacking layer to an existing window.
pub fn apply_layer(win: &tauri::WebviewWindow, layer: Layer) {
    let _ = win.set_always_on_top(layer == Layer::Floating);
    let _ = win.set_always_on_bottom(layer == Layer::Desktop);
    #[cfg(target_os = "macos")]
    mac::pin(win, layer == Layer::Desktop);
}

#[cfg(target_os = "macos")]
pub mod mac {
    //! AppKit specifics tao doesn't expose: desktop-icon window level and
    //! "stationary" Spaces behaviour so Mission Control / Show Desktop leave
    //! desktop widgets where they are (like native widgets).
    use objc2_app_kit::{NSWindow, NSWindowCollectionBehavior};

    extern "C" {
        fn CGWindowLevelForKey(key: i32) -> i32;
    }
    const K_CG_DESKTOP_ICON_WINDOW_LEVEL_KEY: i32 = 18;

    pub fn pin(win: &tauri::WebviewWindow, desktop: bool) {
        let w = win.clone();
        let _ = win.run_on_main_thread(move || {
            let Ok(ptr) = w.ns_window() else { return };
            if ptr.is_null() { return; }
            // SAFETY: tauri hands us the live NSWindow* for this window and we
            // are on the main thread, as AppKit requires.
            let ns: &NSWindow = unsafe { &*(ptr as *const NSWindow) };
            let mut behavior = NSWindowCollectionBehavior::CanJoinAllSpaces
                | NSWindowCollectionBehavior::IgnoresCycle
                | NSWindowCollectionBehavior::FullScreenAuxiliary;
            if desktop {
                behavior |= NSWindowCollectionBehavior::Stationary;
                // One above the desktop icons: under every app window, never
                // covered by the wallpaper.
                let level = unsafe { CGWindowLevelForKey(K_CG_DESKTOP_ICON_WINDOW_LEVEL_KEY) } as isize + 1;
                ns.setLevel(level);
            }
            ns.setCollectionBehavior(behavior);
        });
    }

    /// Dock-style window: on every Space, over full-screen apps, never in the
    /// ⌘` window cycle or Mission Control.
    pub fn float_everywhere(win: &tauri::WebviewWindow) {
        let w = win.clone();
        let _ = win.run_on_main_thread(move || {
            let Ok(ptr) = w.ns_window() else { return };
            if ptr.is_null() { return; }
            // SAFETY: live NSWindow* on the main thread (see `pin`).
            let ns: &NSWindow = unsafe { &*(ptr as *const NSWindow) };
            ns.setCollectionBehavior(
                NSWindowCollectionBehavior::CanJoinAllSpaces
                    | NSWindowCollectionBehavior::Stationary
                    | NSWindowCollectionBehavior::IgnoresCycle
                    | NSWindowCollectionBehavior::FullScreenAuxiliary,
            );
        });
    }
}

/// Usable area of the monitor the cursor is on (logical units).
pub fn work_area(app: &AppHandle) -> Rect {
    let mon = app.cursor_position().ok()
        .and_then(|p| app.monitor_from_point(p.x, p.y).ok().flatten())
        .or_else(|| app.primary_monitor().ok().flatten());
    match mon {
        Some(m) => {
            let s = m.scale_factor();
            let r = m.work_area();
            (r.position.x as f64 / s, r.position.y as f64 / s, r.size.width as f64 / s, r.size.height as f64 / s)
        }
        None => (0.0, 0.0, 1440.0, 900.0),
    }
}

/* ─── IPC ───────────────────────────────────────────────── */

fn store(app: &AppHandle) -> Result<Arc<WidgetStore>, String> {
    app.try_state::<Arc<WidgetStore>>().map(|s| s.inner().clone()).ok_or_else(|| "widgets not ready".into())
}

#[tauri::command]
pub fn widgets_list(app: AppHandle) -> Result<Vec<Widget>, String> {
    Ok(store(&app)?.list())
}

#[tauri::command]
pub fn widget_get(id: String, app: AppHandle) -> Result<Option<Widget>, String> {
    Ok(store(&app)?.get(&id))
}

#[tauri::command]
pub fn widget_add(kind: String, w: f64, h: f64, config: Option<Value>, app: AppHandle) -> Result<Widget, String> {
    let st = store(&app)?;
    let (w, h) = (w.clamp(MIN_SIZE, MAX_SIZE), h.clamp(MIN_SIZE, MAX_SIZE));
    let area = work_area(&app);
    let taken: Vec<Rect> = st.list().iter().map(|it| (it.x, it.y, it.w, it.h)).collect();
    let (x, y) = find_free_spot(&taken, w, h, area);
    let widget = Widget {
        id: uuid::Uuid::new_v4().simple().to_string()[..12].to_string(),
        kind, x, y, w, h,
        config: config.filter(Value::is_object).unwrap_or_else(|| Value::Object(Default::default())),
        ..Default::default()
    };
    st.insert(widget.clone());
    if !st.visible() { st.set_visible(true); show_all(&app); }
    open_window(&app, &widget).map_err(|e| e.to_string())?;
    let _ = app.emit("widgets-changed", ());
    Ok(widget)
}

#[tauri::command]
pub fn widget_update(id: String, patch: WidgetPatch, app: AppHandle) -> Result<Widget, String> {
    let st = store(&app)?;
    let frame = patch.x.is_some() || patch.y.is_some() || patch.w.is_some() || patch.h.is_some();
    let layer = patch.layer;
    let updated = st.update(&id, patch).ok_or("no such widget")?;
    if let Some(win) = app.get_webview_window(&label_for(&id)) {
        if frame {
            let _ = win.set_size(tauri::LogicalSize::new(updated.w, updated.h));
            let _ = win.set_position(tauri::LogicalPosition::new(updated.x, updated.y));
        }
        if let Some(l) = layer { apply_layer(&win, l); }
    }
    let _ = app.emit("widget-updated", &updated);
    let _ = app.emit("widgets-changed", ());
    Ok(updated)
}

#[tauri::command]
pub fn widget_remove(id: String, app: AppHandle) -> Result<(), String> {
    let st = store(&app)?;
    st.remove(&id);
    close_window(&app, &id);
    let _ = app.emit("widgets-changed", ());
    Ok(())
}

#[tauri::command]
pub fn widgets_set_visible(visible: bool, app: AppHandle) -> Result<bool, String> {
    let st = store(&app)?;
    st.set_visible(visible);
    if visible { show_all(&app) } else { hide_all(&app) }
    let _ = app.emit("widgets-changed", ());
    Ok(visible)
}

#[tauri::command]
pub fn widgets_visible(app: AppHandle) -> Result<bool, String> {
    Ok(store(&app)?.visible())
}

/// Broadcast edit mode (jiggle + remove buttons) to every widget window.
#[tauri::command]
pub fn widgets_edit_mode(enabled: bool, app: AppHandle) {
    let _ = app.emit("widgets-edit-mode", enabled);
}

pub fn show_all(app: &AppHandle) {
    let Ok(st) = store(app) else { return };
    for w in st.list() {
        if let Err(e) = open_window(app, &w) {
            tracing::warn!(target: "aio_cortex_lib", "widget {} failed to open: {e}", w.id);
        }
    }
}

pub fn hide_all(app: &AppHandle) {
    for (label, win) in app.webview_windows() {
        if label.starts_with(LABEL_PREFIX) { let _ = win.hide(); }
    }
}

/// Window move/resize → persist the new frame (debounced).
pub fn on_window_event(window: &tauri::Window, event: &tauri::WindowEvent) {
    let Some(id) = window.label().strip_prefix(LABEL_PREFIX) else { return };
    let Some(st) = window.app_handle().try_state::<Arc<WidgetStore>>() else { return };
    let scale = window.scale_factor().unwrap_or(1.0);
    match event {
        tauri::WindowEvent::Moved(p) => st.set_frame(id, Some(p.x as f64 / scale), Some(p.y as f64 / scale), None, None),
        tauri::WindowEvent::Resized(s) if s.width > 0 && s.height > 0 => {
            st.set_frame(id, None, None, Some(s.width as f64 / scale), Some(s.height as f64 / scale))
        }
        _ => {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const AREA: Rect = (0.0, 25.0, 1440.0, 875.0);

    #[test]
    fn first_widget_goes_top_right() {
        let (x, y) = find_free_spot(&[], 170.0, 170.0, AREA);
        assert!(x > 1200.0, "x={x}");
        assert!(y < 60.0, "y={y}");
    }

    #[test]
    fn spots_never_overlap() {
        // 12 mixed widgets fill a 1440×900 screen without any overlap; past
        // that the greedy packer may fall back to the cascade.
        let mut taken: Vec<Rect> = vec![];
        for i in 0..12 {
            let (w, h) = if i % 3 == 0 { (360.0, 170.0) } else { (170.0, 170.0) };
            let (x, y) = find_free_spot(&taken, w, h, AREA);
            let r = (x, y, w, h);
            assert!(taken.iter().all(|t| !overlaps(r, *t)), "#{i} overlaps at {r:?}");
            assert!(x >= AREA.0 && y >= AREA.1 && x + w <= AREA.0 + AREA.2 && y + h <= AREA.1 + AREA.3, "#{i} off-screen {r:?}");
            taken.push(r);
        }
    }

    #[test]
    fn full_area_falls_back_to_cascade() {
        let taken = vec![AREA];
        let (x, y) = find_free_spot(&taken, 170.0, 170.0, AREA);
        assert!(x >= AREA.0 && y >= AREA.1);
    }

    #[test]
    fn patch_merges_config_and_clamps() {
        let mut w = Widget { config: serde_json::json!({ "city": "Pune", "unit": "c" }), ..Default::default() };
        apply_patch(&mut w, WidgetPatch {
            w: Some(5.0), h: Some(99_999.0),
            config: Some(serde_json::json!({ "city": "Mumbai", "unit": null, "tz": "Asia/Kolkata" })),
            ..Default::default()
        });
        assert_eq!(w.w, MIN_SIZE);
        assert_eq!(w.h, MAX_SIZE);
        assert_eq!(w.config, serde_json::json!({ "city": "Mumbai", "tz": "Asia/Kolkata" }));
    }

    #[test]
    fn store_roundtrip() {
        let dir = std::env::temp_dir().join(format!("cortex-widgets-{}", uuid::Uuid::new_v4()));
        let path = dir.join("widgets.json");
        let st = WidgetStore::load(path.clone());
        st.insert(Widget { id: "a".into(), kind: "clock".into(), ..Default::default() });
        st.update("a", WidgetPatch { layer: Some(Layer::Floating), ..Default::default() });
        st.set_visible(false);
        let again = WidgetStore::load(path);
        assert_eq!(again.list().len(), 1);
        assert_eq!(again.get("a").unwrap().layer, Layer::Floating);
        assert!(!again.visible());
        assert!(again.remove("a"));
        assert!(!again.remove("a"));
        let _ = std::fs::remove_dir_all(dir);
    }
}
