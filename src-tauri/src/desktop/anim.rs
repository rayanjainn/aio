//! Window-level show / hide animations.
//!
//! The glass is a native view behind the web page, so animating the page (CSS)
//! leaves the glass behind: it appeared before the content and lingered after it
//! left. Animating the *window* — opacity and position, one frame at a time from
//! Rust — moves glass and content together.
//!
//! Windows are created hidden and shown only when their page reports ready
//! (`surface_ready`), so an empty glass slab never flashes while React boots.

use std::{
    collections::HashMap,
    sync::{Mutex, OnceLock},
    time::{Duration, Instant},
};
use tauri::{AppHandle, LogicalPosition, Manager};

const FRAME: Duration = Duration::from_millis(16);

/// Per-window animation generation: starting a new animation cancels the old one.
fn generations() -> &'static Mutex<HashMap<String, u64>> {
    static G: OnceLock<Mutex<HashMap<String, u64>>> = OnceLock::new();
    G.get_or_init(Default::default)
}

fn next_gen(label: &str) -> u64 {
    let mut g = generations().lock().unwrap_or_else(|e| e.into_inner());
    let n = g.entry(label.to_string()).or_insert(0);
    *n += 1;
    *n
}

fn current_gen(label: &str) -> u64 {
    generations().lock().map(|g| g.get(label).copied().unwrap_or(0)).unwrap_or(0)
}

/// Cubic ease-out — fast start, soft landing (like the system's own panels).
pub fn ease_out(t: f64) -> f64 {
    let t = t.clamp(0.0, 1.0);
    1.0 - (1.0 - t).powi(3)
}

pub fn lerp(a: f64, b: f64, t: f64) -> f64 { a + (b - a) * t }

/// Where the window starts (hidden) so it slides toward `rest`: pushed
/// `distance` points toward the screen edge named by `edge`.
pub fn hidden_offset(edge: &str, rest: (f64, f64), distance: f64) -> (f64, f64) {
    match edge {
        "left"  => (rest.0 - distance, rest.1),
        "right" => (rest.0 + distance, rest.1),
        "top"   => (rest.0, rest.1 - distance),
        _       => (rest.0, rest.1 + distance),
    }
}

/// Animate opacity (and optionally position) from `from` to `to` over `ms`.
/// `visible_at_end == false` orders the window out once it is fully faded.
pub async fn animate(
    app: AppHandle, label: String,
    alpha: (f64, f64), pos: Option<((f64, f64), (f64, f64))>,
    ms: u64, visible_at_end: bool,
) {
    let Some(win) = app.get_webview_window(&label) else { return };
    let gen = next_gen(&label);
    if alpha.0 < alpha.1 || visible_at_end {
        // Showing: start transparent *before* the window is ordered in.
        super::panel::set_alpha(&app, &label, alpha.0);
        if let Some((from, _)) = pos { let _ = win.set_position(LogicalPosition::new(from.0, from.1)); }
        #[cfg(target_os = "macos")]
        order_front(&app, &label);
        #[cfg(not(target_os = "macos"))]
        let _ = win.show();
    }
    let start = Instant::now();
    loop {
        if current_gen(&label) != gen { return; } // superseded by a newer animation
        let t = (start.elapsed().as_secs_f64() * 1000.0 / ms.max(1) as f64).min(1.0);
        let e = ease_out(t);
        super::panel::set_alpha(&app, &label, lerp(alpha.0, alpha.1, e));
        if let Some((from, to)) = pos {
            let _ = win.set_position(LogicalPosition::new(lerp(from.0, to.0, e), lerp(from.1, to.1, e)));
        }
        if t >= 1.0 { break; }
        tokio::time::sleep(FRAME).await;
    }
    if current_gen(&label) != gen { return; }
    if !visible_at_end {
        let _ = win.hide();
        // Leave opacity at 1 so the next show starts from a known state.
        super::panel::set_alpha(&app, &label, 1.0);
    }
}

/// Order a panel front without activating the app.
#[cfg(target_os = "macos")]
fn order_front(app: &AppHandle, label: &str) {
    use tauri_nspanel::ManagerExt;
    let a = app.clone();
    let l = label.to_string();
    let _ = app.run_on_main_thread(move || {
        if let Ok(p) = a.get_webview_panel(&l) { p.order_front_regardless(); }
        else if let Some(w) = a.get_webview_window(&l) { let _ = w.show(); }
    });
}

/// Fade a window in (no movement).
pub fn fade_in(app: &AppHandle, label: &str, ms: u64) {
    let (a, l) = (app.clone(), label.to_string());
    tauri::async_runtime::spawn(async move { animate(a, l, (0.0, 1.0), None, ms, true).await });
}

/// Fade a window out, then hide it.
pub fn fade_out(app: &AppHandle, label: &str, ms: u64) {
    let (a, l) = (app.clone(), label.to_string());
    tauri::async_runtime::spawn(async move { animate(a, l, (1.0, 0.0), None, ms, false).await });
}

/// Fade out then destroy (closing a widget).
pub fn fade_out_and_destroy(app: &AppHandle, label: &str, ms: u64) {
    let (a, l) = (app.clone(), label.to_string());
    tauri::async_runtime::spawn(async move {
        animate(a.clone(), l.clone(), (1.0, 0.0), None, ms, false).await;
        super::panel::revert(&a, &l);
        // Let the class revert run on the main thread before the window closes.
        tokio::time::sleep(Duration::from_millis(30)).await;
        if let Some(w) = a.get_webview_window(&l) { let _ = w.destroy(); }
    });
}

#[tauri::command]
pub fn surface_ready(window: tauri::WebviewWindow, app: AppHandle) {
    reveal(&app, window.label());
}

/// First show of a freshly created surface (called when its page reports ready).
pub fn reveal(app: &AppHandle, label: &str) {
    if label.starts_with(super::widgets::LABEL_PREFIX) {
        let visible = app.try_state::<std::sync::Arc<super::widgets::WidgetStore>>().map(|s| s.visible()).unwrap_or(true);
        if visible { fade_in(app, label, 260); }
    } else if label == super::dock::LABEL {
        super::dock::reveal_initial(app);
    } else if label == super::island::LABEL {
        fade_in(app, label, 240);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn easing_is_monotonic_and_bounded() {
        let mut prev = -1.0;
        for i in 0..=20 {
            let v = ease_out(i as f64 / 20.0);
            assert!((0.0..=1.0).contains(&v) && v >= prev);
            prev = v;
        }
        assert_eq!(ease_out(0.0), 0.0);
        assert_eq!(ease_out(1.0), 1.0);
        assert_eq!(ease_out(5.0), 1.0, "clamped");
    }

    #[test]
    fn hidden_offsets_point_at_the_edge() {
        assert_eq!(hidden_offset("bottom", (100.0, 800.0), 90.0), (100.0, 890.0));
        assert_eq!(hidden_offset("top", (100.0, 10.0), 90.0), (100.0, -80.0));
        assert_eq!(hidden_offset("left", (8.0, 300.0), 90.0), (-82.0, 300.0));
        assert_eq!(hidden_offset("right", (1300.0, 300.0), 90.0), (1390.0, 300.0));
    }

    #[test]
    fn a_newer_animation_cancels_the_older_one() {
        let a = next_gen("t-win");
        assert_eq!(current_gen("t-win"), a);
        let b = next_gen("t-win");
        assert!(b > a && current_gen("t-win") == b);
    }
}
