#![allow(dead_code)] // stubs filled incrementally — remove before 1.0

// ─── Crate root (lib target) ────────────────────────────
// main.rs is the bin entry point; it just calls run().
// All app logic lives here so the lib is independently testable.

mod auth;
mod config_ipc;
mod daemon;
mod desktop;
mod embed;
mod embeddings;
mod exec_ipc;
mod executor;
mod intent;
mod ipc;
mod ollama;
mod plugin;
mod plugins;
mod ranker;
mod temporal;
mod ws_server;

use daemon::{MemoryDaemon, SessionGraph};
use dirs::home_dir;
use embed::VectorStore;
use ollama::OllamaClient;
use plugin::{Plugin, PluginRegistry, SearchResult};
use plugins::{
    AppsPlugin, BrowserPlugin, CalendarPlugin, ClipboardPlugin, CommandsPlugin, DockerPlugin,
    EmailPlugin, FilesPlugin, GitPlugin, GithubPlugin, ShellPlugin, SlackPlugin, VscodePlugin,
};
use ranker::{Ranker, RankerConfig};
use std::{
    collections::HashMap,
    sync::{
        atomic::{AtomicBool, AtomicI64, AtomicU64, Ordering},
        Arc,
    },
};

/// Milliseconds since the Unix epoch (monotonic-enough for grace windows).
fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}
use tauri::{
    menu::{Menu, MenuItem},
    tray::TrayIconBuilder,
    Manager,
};
use tokio::sync::RwLock;

/* ─── Shared application state ─────────────────────────── */

pub struct AppState {
    pub registry:      Arc<RwLock<PluginRegistry>>,
    pub ranker:        Arc<RwLock<Ranker>>,
    pub session_graph: Arc<SessionGraph>,
    pub memory_daemon: Arc<MemoryDaemon>,
    /// LRU cache: result_id → SearchResult, used by execute_result
    pub result_cache:  Arc<RwLock<HashMap<String, SearchResult>>>,
    /// Running total of indexed items across all plugins
    pub indexed_count: Arc<AtomicU64>,
    /// Absolute path to ~/.cortex/
    pub data_dir:      std::path::PathBuf,
    /// Ollama health + model watch
    pub ollama:        Arc<OllamaClient>,
    /// Embedding + Qdrant vector store (cosine search)
    pub vector_store:  Arc<VectorStore>,
    /// When true, the window hides on focus-loss (Raycast-style click-away).
    /// Disabled during onboarding / OAuth so the browser hand-off doesn't kill it.
    pub autohide:      Arc<AtomicBool>,
    /// Unix-ms of the last time the window was shown. Used as a grace window so
    /// the macOS key-focus storm right after showing never auto-hides it.
    pub shown_at:      Arc<AtomicI64>,
    /// Name of the app that was frontmost just before Cortex (for window-mgmt
    /// commands — so they resize YOUR app, not Finder/Cortex).
    pub last_app:      Arc<std::sync::Mutex<String>>,
}

/// Bring the main window to the front and stamp `shown_at`.
pub(crate) fn show_main(app: &tauri::AppHandle) {
    if let Some(w) = app.get_webview_window("main") {
        if let Some(state) = app.try_state::<AppState>() {
            state.shown_at.store(now_ms(), Ordering::Relaxed);
            // Capture the app you're in RIGHT NOW — before Cortex takes focus — so
            // window-management commands target it. Authoritative vs the 1.2s poller
            // (which can be stale if you switch apps then hit ⌘K quickly).
            // lsappinfo needs no Accessibility.
            #[cfg(target_os = "macos")]
            if let Ok(o) = std::process::Command::new("sh")
                .args(["-c", "lsappinfo info -only name \"$(lsappinfo front)\" 2>/dev/null"])
                .output()
            {
                let raw  = String::from_utf8_lossy(&o.stdout);
                let name = raw.rsplit('=').next().unwrap_or("").trim().trim_matches('"').to_string();
                if !name.is_empty() && !name.to_lowercase().contains("cortex") {
                    if let Ok(mut g) = state.last_app.lock() { *g = name; }
                }
            }
        }
        let _ = w.unminimize();
        let _ = w.center();
        let _ = w.show();
        let _ = w.set_focus();
    }
}

/// Toggle screen-memory capture (⌘⇧P / tray). Privacy-critical: must work
/// from anywhere, even when the palette is hidden.
pub fn toggle_recording(app: &tauri::AppHandle) -> bool {
    use tauri::Emitter;
    let Some(state) = app.try_state::<AppState>() else { return false };
    let d = &state.memory_daemon;
    let recording = if d.is_paused() { d.resume(); true } else { d.pause(); false };
    tracing::info!(target: "aio_cortex_lib", "capture {}", if recording { "resumed" } else { "PAUSED" });
    if let Some(items) = app.try_state::<TrayItems>() {
        let _ = items.pause.set_text(if recording { "Pause Capture" } else { "Resume Capture" });
    }
    let _ = app.emit("recording-changed", recording);
    recording
}

/// Tray menu items whose labels change at runtime.
pub struct TrayItems {
    pub pause:   MenuItem<tauri::Wry>,
    pub widgets: MenuItem<tauri::Wry>,
}

/// Open the Widgets & Dock studio inside the main window.
#[tauri::command]
fn open_studio(tab: Option<String>, app: tauri::AppHandle) {
    desktop::open_studio(&app, tab.as_deref().unwrap_or("widgets"));
}

/* ─── Library entry point ───────────────────────────────── */

pub fn run() {
    // Logs: default shows our crate at debug + everything else at info.
    // Full firehose:  CORTEX_LOG=trace npm run tauri dev
    // App only:       CORTEX_LOG=aio_cortex_lib=trace npm run tauri dev
    tracing_subscriber::fmt()
        .with_env_filter(
            std::env::var("CORTEX_LOG")
                .or_else(|_| std::env::var("RUST_LOG"))
                .unwrap_or_else(|_| "info,aio_cortex_lib=debug".into()),
        )
        .with_target(true)
        .compact()
        .init();

    use tauri_plugin_global_shortcut::{Code, Modifiers, ShortcutState};
    tauri::Builder::default()
        // Single instance MUST be the first plugin — a second launch focuses the
        // existing window instead of spawning a duplicate (and duplicate tray).
        .plugin(tauri_plugin_single_instance::init(|app, _argv, _cwd| {
            show_main(app);
        }))
        .plugin(
            tauri_plugin_global_shortcut::Builder::new()
                .with_handler(|app, shortcut, event| {
                    if event.state() != ShortcutState::Pressed { return; }
                    if shortcut.matches(Modifiers::SUPER | Modifiers::SHIFT, Code::KeyP)
                        || shortcut.matches(Modifiers::CONTROL | Modifiers::SHIFT, Code::KeyP)
                    {
                        toggle_recording(app);
                        return;
                    }
                    {
                        if let Some(w) = app.get_webview_window("main") {
                            // Toggle only when visible AND focused; otherwise bring
                            // forward. `is_visible` alone is unreliable post blur-hide.
                            let visible = w.is_visible().unwrap_or(false);
                            let focused = w.is_focused().unwrap_or(false);
                            if visible && focused {
                                let _ = w.hide();
                            } else {
                                show_main(app);
                            }
                        }
                    }
                })
                .build(),
        )
        .plugin(tauri_plugin_shell::init())
        .on_window_event(|window, event| {
            // Widget / dock windows have their own handling — and must never
            // inherit the palette's hide-on-blur below.
            if desktop::on_window_event(window, event) { return; }
            if window.label() != "main" { return; }
            // Raycast-style hide-on-blur, but DEBOUNCED. macOS rapidly toggles
            // key focus (windowDidResignKey/BecomeKey) when a transparent,
            // always-on-top window is shown — hiding immediately on the first
            // `Focused(false)` created a flicker loop where the window never
            // stayed open. Instead, wait 220ms and only hide if focus is still
            // gone (a genuine click-away), which lets the flicker self-cancel.
            if let tauri::WindowEvent::Focused(false) = event {
                let w   = window.clone();
                let app = window.app_handle().clone();
                tauri::async_runtime::spawn(async move {
                    // Debounce: wait, then only hide on a *sustained* blur.
                    tokio::time::sleep(std::time::Duration::from_millis(280)).await;
                    if w.is_focused().unwrap_or(false) { return; } // regained → flicker
                    if let Some(state) = app.try_state::<AppState>() {
                        // Grace: never hide within 1.2s of showing — the freshly
                        // shown window resigns/regains key several times before it
                        // settles, and hiding during that storm = "closes instantly".
                        let since_shown = now_ms() - state.shown_at.load(Ordering::Relaxed);
                        if since_shown < 1200 { return; }
                        if state.autohide.load(Ordering::Relaxed) {
                            let _ = w.hide();
                        }
                    }
                });
            }
        })
        .setup(setup)
        .invoke_handler(tauri::generate_handler![
            ipc::search,
            ipc::get_suggestions,
            ipc::execute_result,
            ipc::get_daemon_status,
            ipc::toggle_recording,
            ipc::sync_plugins,
            ipc::search_memory,
            ipc::memory_timeline,
            exec_ipc::plan_execution,
            exec_ipc::run_execution,
            exec_ipc::ask_ai_chat,
            exec_ipc::list_chats,
            exec_ipc::get_chat,
            exec_ipc::delete_chat,
            exec_ipc::clear_chats,
            config_ipc::get_config,
            config_ipc::set_config,
            config_ipc::set_ui_value,
            config_ipc::clear_captures,
            config_ipc::open_data_folder,
            config_ipc::read_file_preview,
            config_ipc::set_onboarding_complete,
            config_ipc::get_onboarding_complete,
            config_ipc::get_ollama_status,
            config_ipc::check_ollama_health,
            config_ipc::oauth_connect,
            config_ipc::check_google_auth,
            config_ipc::connect_google,
            config_ipc::check_github_token,
            config_ipc::set_autohide,
            config_ipc::open_url,
            config_ipc::get_app_icon,
            config_ipc::get_file_meta,
            config_ipc::reveal_in_finder,
            config_ipc::quick_look,
            config_ipc::detect_terminals,
            config_ipc::spotlight_search,
            config_ipc::list_dir,
            config_ipc::get_running_apps,
            config_ipc::get_open_tabs,
            config_ipc::get_clipboard_history,
            config_ipc::snippet_list,
            config_ipc::snippet_add,
            config_ipc::snippet_delete,
            config_ipc::get_github_stats,
            config_ipc::window_action,
            desktop::widgets::widgets_list,
            desktop::widgets::widget_get,
            desktop::widgets::widget_add,
            desktop::widgets::widget_update,
            desktop::widgets::widget_remove,
            desktop::widgets::widgets_set_visible,
            desktop::widgets::widgets_visible,
            desktop::widgets::widgets_edit_mode,
            desktop::providers::sys_stats,
            desktop::providers::now_playing,
            desktop::providers::media_control,
            desktop::providers::weather_get,
            desktop::providers::calendar_upcoming,
            desktop::providers::git_repo_status,
            desktop::providers::docker_containers,
            desktop::providers::docker_action,
            desktop::providers::github_activity,
            desktop::providers::photo_pick,
            desktop::providers::list_installed_apps,
            desktop::providers::launch_path,
            open_studio,
        ])
        .run(tauri::generate_context!())
        .expect("tauri run failed");
}

/* ─── Setup ─────────────────────────────────────────────── */

fn setup(app: &mut tauri::App) -> Result<(), Box<dyn std::error::Error>> {
    let home     = home_dir().unwrap_or_default();
    let data_dir = home.join(".cortex");
    std::fs::create_dir_all(&data_dir)?;

    // User settings — applied at startup (file roots, blocked apps, retention,
    // raw storage, plugin toggles). Previously written but ignored.
    let cfg = config_ipc::load_config();
    let plugin_on = |id: &str| cfg.enabled_plugins.get(id).copied().unwrap_or(true);

    let mut registry = PluginRegistry::new();

    // ── Apps plugin (Raycast-style launcher) ─────────────
    {
        let apps = Arc::new(AppsPlugin::new(data_dir.clone()));
        let a = apps.clone();
        tauri::async_runtime::spawn(async move {
            if let Err(e) = a.sync().await { tracing::warn!("apps sync: {e}"); }
        });
        registry.register(apps);
    }

    // ── System commands plugin ───────────────────────────
    registry.register(Arc::new(CommandsPlugin::new()));

    // ── Files plugin ─────────────────────────────────────
    // Build list of roots that actually exist on this machine.
    // Code-focused roots only — skip Downloads/home junk that bloats the
    // index to ~1M files and slows first-run indexing to a crawl.
    let mut file_roots: Vec<std::path::PathBuf> = [
        "code", "projects", "Projects", "Developer", "Sites",
        "repos", "src", "dev", "work", "workspace", "Documents",
    ]
    .iter()
    .map(|s| home.join(s))
    .filter(|p| p.exists())
    .collect();
    // User-added roots from Settings.
    for r in &cfg.file_roots {
        let p = std::path::PathBuf::from(r);
        if p.exists() && !file_roots.contains(&p) { file_roots.push(p); }
    }

    if let Ok(files) = FilesPlugin::new(data_dir.join("indices/files"), file_roots) {
        // Extract watcher context BEFORE moving the plugin into the registry.
        let watcher_ctx = files.watcher_context();
        tauri::async_runtime::spawn(plugins::files::start_file_watcher(watcher_ctx));
        registry.register(Arc::new(files));
    }

    // ── Shell plugin (Tantivy + hook server) ──────────────
    if let Ok(shell) = ShellPlugin::new(data_dir.join("shell")) {
        let shell_arc = Arc::new(shell);
        tauri::async_runtime::spawn(plugins::shell::start_hook_server(shell_arc.clone()));
        registry.register(shell_arc);
    }

    // ── Browser plugin ────────────────────────────────────
    // Keep a typed Arc so the WS server can call handle_tab_event().
    let browser = Arc::new(BrowserPlugin::new());
    tauri::async_runtime::spawn(ws_server::start(browser.clone()));
    registry.register(browser);

    // ── Git plugin (Tantivy + incremental) ────────────────
    if plugin_on("git") { if let Ok(git) = GitPlugin::new(data_dir.join("git"), vec![]) {
        registry.register(Arc::new(git));
    }}

    // ── GitHub plugin ─────────────────────────────────────
    if plugin_on("github") { if let Ok(gh) = GithubPlugin::new(data_dir.join("github")) {
        let gh_arc = Arc::new(gh);
        tauri::async_runtime::spawn(plugins::github::periodic_sync(gh_arc.clone()));
        registry.register(gh_arc);
    }}

    // ── Docker plugin ─────────────────────────────────────
    if plugin_on("docker") { if let Ok(docker) = DockerPlugin::new(data_dir.join("docker")) {
        let docker_arc = Arc::new(docker);
        tauri::async_runtime::spawn(plugins::docker::watch_docker(docker_arc.clone()));
        registry.register(docker_arc);
    }}

    // ── VS Code plugin ────────────────────────────────────
    if plugin_on("vscode") { if let Ok(vscode) = VscodePlugin::new(data_dir.join("indices/vscode")) {
        registry.register(Arc::new(vscode));
    }}

    // ── Calendar plugin ───────────────────────────────────
    if plugin_on("calendar") { if let Ok(cal) = CalendarPlugin::new(data_dir.join("calendar")) {
        registry.register(Arc::new(cal));
    }}

    // ── Email plugin (Gmail + Apple Mail) ─────────────────
    if plugin_on("email") { if let Ok(email) = EmailPlugin::new(data_dir.join("email")) {
        registry.register(Arc::new(email));
    }}

    // ── Slack plugin ──────────────────────────────────────
    if plugin_on("slack") { if let Ok(slack) = SlackPlugin::new(data_dir.join("slack")) {
        registry.register(Arc::new(slack));
    }}

    // ── Clipboard plugin ──────────────────────────────────
    if plugin_on("clipboard") { if let Ok(clip_plugin) = ClipboardPlugin::new(data_dir.join("clipboard")) {
        if let Ok(clip_watcher) = ClipboardPlugin::new(data_dir.join("clipboard")) {
            let watcher_arc = Arc::new(clip_watcher);
            tauri::async_runtime::spawn(plugins::clipboard::watch_clipboard(watcher_arc));
        }
        registry.register(Arc::new(clip_plugin));
    }}

    // ── Shared state ──────────────────────────────────────
    let registry_arc  = Arc::new(RwLock::new(registry));
    let indexed_count = Arc::new(AtomicU64::new(0));

    // Load behavioral interaction log from SQLite so ranker has history at startup
    let behavioral_log = tokio::task::block_in_place(|| {
        Ranker::load_behavioral_log(&data_dir.join("interactions.db"))
    });
    let ranker = Arc::new(RwLock::new(Ranker::new(
        RankerConfig::default(),
        behavioral_log,
    )));

    // ── Ollama health watcher ─────────────────────────────
    let ollama = Arc::new(OllamaClient::new());
    {
        let o = ollama.clone();
        tauri::async_runtime::spawn(async move { o.watch().await });
    }

    // ── Warm the chat model on startup (local only). Cloud is always warm,
    //    so skip the probe when an api_key is configured. ──────────────────
    tauri::async_runtime::spawn(async {
        if crate::exec_ipc::ollama_cfg().api_key.is_some() { return; } // cloud — no warmup needed
        tokio::time::sleep(std::time::Duration::from_secs(3)).await;
        let client = reqwest::Client::new();
        let installed: Vec<String> = match client.get("http://localhost:11434/api/tags").send().await {
            Ok(r) => r.json::<serde_json::Value>().await.ok()
                .and_then(|v| v["models"].as_array().map(|a| a.iter().filter_map(|m| m["name"].as_str().map(String::from)).collect()))
                .unwrap_or_default(),
            Err(_) => vec![],
        };
        let model = ["llama3.1:8b","qwen2.5:7b","llama3.2:3b","phi3:mini"].iter()
            .find(|m| installed.iter().any(|i| i.starts_with(**m))).unwrap_or(&"phi3:mini").to_string();
        let _ = client.post("http://localhost:11434/api/generate")
            .json(&serde_json::json!({ "model": model, "prompt": "hi", "stream": false, "keep_alive": "30m", "options": {"num_predict": 1} }))
            .send().await;
        tracing::info!(target: "aio_cortex_lib", "warmed model: {model}");
    });

    // ── Vector store (Nomic + Qdrant) ─────────────────────
    let vector_store = Arc::new(VectorStore::new());

    let session_graph = Arc::new(
        SessionGraph::new(data_dir.join("sessions"))?,
    );

    // MemoryDaemon gets its own Arc<SessionGraph> (same WAL db, separate connection).
    let daemon_sg = Arc::new(SessionGraph::new(data_dir.join("sessions"))?);
    let cap_cfg = daemon::CaptureConfig {
        retention_days: cfg.retention_days.max(1),
        raw_storage:    cfg.raw_storage,
        blocked_apps:   cfg.blocked_apps.clone(),
        ..Default::default()
    };
    let memory_daemon = Arc::new(MemoryDaemon::new(cap_cfg, daemon_sg));
    {
        let d = memory_daemon.clone();
        tauri::async_runtime::spawn(async move {
            if let Err(e) = d.run().await {
                tracing::error!("memory daemon: {e}");
            }
        });
    }
    // Retention cleanup — every 6h delete frames older than retention_days.
    {
        let d = memory_daemon.clone();
        tauri::async_runtime::spawn(async move {
            loop {
                tokio::time::sleep(std::time::Duration::from_secs(6 * 3600)).await;
                match d.cleanup().await {
                    Ok(n) if n > 0 => tracing::info!(target: "aio_cortex_lib", "retention cleanup: removed {n} old frames"),
                    _ => {}
                }
            }
        });
    }

    app.manage(AppState {
        registry:      registry_arc.clone(),
        ranker:        ranker.clone(),
        session_graph: session_graph.clone(),
        memory_daemon: memory_daemon.clone(),
        result_cache:  Arc::new(RwLock::new(HashMap::new())),
        indexed_count: indexed_count.clone(),
        data_dir:      data_dir.clone(),
        ollama:        ollama.clone(),
        vector_store:  vector_store.clone(),
        // Start with autohide OFF so first-run onboarding isn't dismissed by blur.
        // Frontend flips it on once the main palette is showing.
        autohide:      Arc::new(AtomicBool::new(false)),
        shown_at:      Arc::new(AtomicI64::new(now_ms())),
        last_app:      Arc::new(std::sync::Mutex::new(String::new())),
    });

    // Track the frontmost non-Cortex app so window-management commands resize
    // the app you were actually using.
    #[cfg(target_os = "macos")]
    {
        let la = app.state::<AppState>().last_app.clone();
        tauri::async_runtime::spawn(async move {
            loop {
                // lsappinfo needs NO Accessibility permission (unlike System Events).
                // `lsappinfo front` → ASN; `info -only name <asn>` → "LSDisplayName"="Safari".
                let out = tokio::task::spawn_blocking(|| {
                    std::process::Command::new("sh")
                        .args(["-c", "lsappinfo info -only name \"$(lsappinfo front)\" 2>/dev/null"])
                        .output().ok().map(|o| String::from_utf8_lossy(&o.stdout).to_string())
                }).await.ok().flatten();
                if let Some(raw) = out {
                    // raw = "LSDisplayName"="Safari"
                    let name = raw.rsplit('=').next().unwrap_or("").trim().trim_matches('"').to_string();
                    if !name.is_empty() && !name.to_lowercase().contains("cortex") {
                        if let Ok(mut g) = la.lock() { *g = name; }
                    }
                }
                tokio::time::sleep(std::time::Duration::from_millis(1200)).await;
            }
        });
    }

    // ── Initial sync + 5-minute periodic re-sync ──────────
    {
        let reg   = registry_arc.clone();
        let count = indexed_count.clone();
        tauri::async_runtime::spawn(async move {
            loop {
                let totals = {
                    let registry = reg.read().await;
                    registry.sync_all().await
                };
                let total: u64 = totals.values().map(|&n| n as u64).sum();
                count.store(total, Ordering::Relaxed);
                tracing::info!("sync complete — {total} items indexed");
                tokio::time::sleep(std::time::Duration::from_secs(300)).await;
            }
        });
    }

    // ── Global shortcut ⌘K ────────────────────────────────
    // Plugin already initialized with handler in run(); just register the key.
    use tauri_plugin_global_shortcut::GlobalShortcutExt;
    app.global_shortcut().register("CommandOrControl+K")?;
    // Privacy pause — failure to register is logged loudly but must not abort
    // startup (another app may own the combo; the tray item still works).
    if let Err(e) = app.global_shortcut().register("CommandOrControl+Shift+P") {
        tracing::error!(target: "aio_cortex_lib", "could not register ⌘⇧P pause hotkey: {e}");
    }

    // ── System tray ───────────────────────────────────────
    use tauri::menu::PredefinedMenuItem;
    let open_i    = MenuItem::with_id(app, "open",     "Open Cortex",        true, Some("Cmd+K"))?;
    let pause_i   = MenuItem::with_id(app, "pause",    "Pause Capture",      true, Some("CmdOrCtrl+Shift+P"))?;
    let widgets_i = MenuItem::with_id(app, "widgets",  "Hide Widgets",       true, None::<&str>)?;
    let studio_i  = MenuItem::with_id(app, "studio",   "Widgets & Dock…",    true, None::<&str>)?;
    let reindex_i = MenuItem::with_id(app, "reindex",  "Re-index Now",       true, None::<&str>)?;
    let reset_i   = MenuItem::with_id(app, "reset",    "Re-run Onboarding",  true, None::<&str>)?;
    let sep1      = PredefinedMenuItem::separator(app)?;
    let quit_i    = MenuItem::with_id(app, "quit",     "Quit Cortex",        true, Some("Cmd+Q"))?;
    let menu      = Menu::with_items(app, &[&open_i, &pause_i, &PredefinedMenuItem::separator(app)?, &studio_i, &widgets_i, &PredefinedMenuItem::separator(app)?, &reindex_i, &reset_i, &sep1, &quit_i])?;

    let tray_rgba = image::load_from_memory(include_bytes!("../icons/tray.png"))
        .expect("decode tray icon")
        .to_rgba8();
    let (tw, th) = tray_rgba.dimensions();
    let tray_icon = tauri::image::Image::new_owned(tray_rgba.into_raw(), tw, th);
    TrayIconBuilder::new()
        .icon(tray_icon)
        .icon_as_template(true) // monochrome glyph, macOS tints for light/dark menu bar
        .tooltip("Cortex — ⌘K")
        .menu(&menu)
        .show_menu_on_left_click(true)
        .on_menu_event(move |app, event| match event.id.as_ref() {
            "quit"    => app.exit(0),
            "open"    => show_main(app),
            "pause"   => { toggle_recording(app); }
            "studio"  => desktop::open_studio(app, "widgets"),
            "widgets" => {
                use tauri::Emitter;
                if let Some(st) = app.try_state::<Arc<desktop::widgets::WidgetStore>>() {
                    let show = !st.visible();
                    st.set_visible(show);
                    if show { desktop::widgets::show_all(app) } else { desktop::widgets::hide_all(app) }
                    let _ = app.emit("widgets-changed", ());
                }
            }
            "reindex" => {
                if let Some(state) = app.try_state::<AppState>() {
                    let reg = state.registry.clone();
                    tauri::async_runtime::spawn(async move {
                        let n = reg.read().await.sync_all().await;
                        tracing::info!("manual reindex: {:?}", n);
                    });
                }
            }
            "reset" => {
                use tauri::Emitter;
                let flag = home_dir().unwrap_or_default().join(".cortex/.onboarding_complete");
                let _ = std::fs::remove_file(flag);
                show_main(app);
                let _ = app.emit("open-onboarding", ());
            }
            _ => {}
        })
        .build(app)?;
    app.manage(TrayItems { pause: pause_i, widgets: widgets_i });

    // Liquid Glass behind the palette (native on macOS 26+, vibrancy before).
    if let Some(w) = app.get_webview_window("main") { desktop::glass::apply(&w, 14.0); }

    // Desktop widgets — after AppState so providers can reach shared state.
    desktop::init(app.handle(), &data_dir);
    if let Some(items) = app.try_state::<TrayItems>() {
        let visible = app.state::<Arc<desktop::widgets::WidgetStore>>().visible();
        let _ = items.widgets.set_text(if visible { "Hide Widgets" } else { "Show Widgets" });
    }
    {
        use tauri::Listener;
        let h = app.handle().clone();
        app.listen_any("widgets-changed", move |_| {
            if let (Some(items), Some(st)) = (h.try_state::<TrayItems>(), h.try_state::<Arc<desktop::widgets::WidgetStore>>()) {
                let _ = items.widgets.set_text(if st.visible() { "Hide Widgets" } else { "Show Widgets" });
            }
        });
    }

    Ok(())
}

/* ─── Storage helpers ───────────────────────────────────── */

/// Recursively sum file sizes under a directory.
pub fn dir_size_bytes(path: &std::path::Path) -> u64 {
    walkdir::WalkDir::new(path)
        .into_iter()
        .filter_map(|e| e.ok())
        .filter(|e| e.file_type().is_file())
        .filter_map(|e| e.metadata().ok())
        .map(|m| m.len())
        .sum()
}
