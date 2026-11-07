//! The engine: every plugin, the ranker, the session graph and the memory daemon,
//! started exactly as the old desktop app did — minus anything Tauri.

use crate::{
    config_ipc,
    daemon::{self, MemoryDaemon, SessionGraph},
    embed::VectorStore,
    ollama::OllamaClient,
    plugin::{Plugin, PluginRegistry, SearchResult},
    plugins::{self, *},
    ranker::{Ranker, RankerConfig},
    ws_server,
};
use dirs::home_dir;
use std::{
    collections::HashMap,
    sync::{atomic::{AtomicBool, AtomicU64, Ordering}, Arc},
};
use tokio::sync::RwLock;

pub struct Engine {
    pub registry:      Arc<RwLock<PluginRegistry>>,
    pub ranker:        Arc<RwLock<Ranker>>,
    pub session_graph: Arc<SessionGraph>,
    pub memory_daemon: Arc<MemoryDaemon>,
    /// result_id → SearchResult, so a client can act on a result by id.
    pub result_cache:  Arc<RwLock<HashMap<String, SearchResult>>>,
    pub indexed_count: Arc<AtomicU64>,
    pub data_dir:      std::path::PathBuf,
    pub ollama:        Arc<OllamaClient>,
    pub vector_store:  Arc<VectorStore>,
    pub started:       std::time::Instant,
    pub _unused:       AtomicBool,
}

impl Engine {
    pub async fn start() -> Result<Arc<Engine>, Box<dyn std::error::Error>> {
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
        tokio::spawn(async move {
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

    // macOS volumes are case-insensitive: "projects" and "Projects" are one folder, and indexing it
    // twice shows every file twice. Also drop roots that sit inside another root.
    let mut seen_lower: Vec<String> = Vec::new();
    file_roots.retain(|p| {
        let k = p.to_string_lossy().to_lowercase();
        if seen_lower.contains(&k) { false } else { seen_lower.push(k); true }
    });
    let lowered: Vec<String> = file_roots.iter().map(|p| p.to_string_lossy().to_lowercase()).collect();
    let keep: Vec<bool> = lowered.iter().enumerate()
        .map(|(i, k)| !lowered.iter().enumerate().any(|(j, o)| j != i && k.starts_with(&format!("{}/", o))))
        .collect();
    let mut idx = 0;
    file_roots.retain(|_| { let k = keep[idx]; idx += 1; k });

    if let Ok(files) = FilesPlugin::new(data_dir.join("indices/files"), file_roots) {
        // Extract watcher context BEFORE moving the plugin into the registry.
        let watcher_ctx = files.watcher_context();
        tokio::spawn(plugins::files::start_file_watcher(watcher_ctx));
        registry.register(Arc::new(files));
    }

    // ── Shell plugin (Tantivy + hook server) ──────────────
    if let Ok(shell) = ShellPlugin::new(data_dir.join("shell")) {
        let shell_arc = Arc::new(shell);
        tokio::spawn(plugins::shell::start_hook_server(shell_arc.clone()));
        registry.register(shell_arc);
    }

    // ── Browser plugin ────────────────────────────────────
    // Keep a typed Arc so the WS server can call handle_tab_event().
    let browser = Arc::new(BrowserPlugin::new());
    tokio::spawn(ws_server::start(browser.clone()));
    registry.register(browser);

    // ── Git plugin (Tantivy + incremental) ────────────────
    if plugin_on("git") { if let Ok(git) = GitPlugin::new(data_dir.join("git"), vec![]) {
        registry.register(Arc::new(git));
    }}

    // ── GitHub plugin ─────────────────────────────────────
    if plugin_on("github") { if let Ok(gh) = GithubPlugin::new(data_dir.join("github")) {
        let gh_arc = Arc::new(gh);
        tokio::spawn(plugins::github::periodic_sync(gh_arc.clone()));
        registry.register(gh_arc);
    }}

    // ── Docker plugin ─────────────────────────────────────
    if plugin_on("docker") { if let Ok(docker) = DockerPlugin::new(data_dir.join("docker")) {
        let docker_arc = Arc::new(docker);
        tokio::spawn(plugins::docker::watch_docker(docker_arc.clone()));
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
            tokio::spawn(plugins::clipboard::watch_clipboard(watcher_arc));
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
        tokio::spawn(async move { o.watch().await });
    }

    // ── Warm the chat model on startup (local only). Cloud is always warm,
    //    so skip the probe when an api_key is configured. ──────────────────
    tokio::spawn(async {
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
    // The native app starts the engine with screen capture paused until the user opts in.
    if std::env::var("CORTEX_CAPTURE_PAUSED").is_ok() { memory_daemon.pause(); }
    {
        let d = memory_daemon.clone();
        tokio::spawn(async move {
            if let Err(e) = d.run().await {
                tracing::error!("memory daemon: {e}");
            }
        });
    }
    // Retention cleanup — every 6h delete frames older than retention_days.
    {
        let d = memory_daemon.clone();
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(std::time::Duration::from_secs(6 * 3600)).await;
                match d.cleanup().await {
                    Ok(n) if n > 0 => tracing::info!(target: "aio_cortex_lib", "retention cleanup: removed {n} old frames"),
                    _ => {}
                }
            }
        });
    }

    let engine = Arc::new(Engine {
        registry:      registry_arc.clone(),
        ranker:        ranker.clone(),
        session_graph: session_graph.clone(),
        memory_daemon: memory_daemon.clone(),
        result_cache:  Arc::new(RwLock::new(HashMap::new())),
        indexed_count: indexed_count.clone(),
        data_dir:      data_dir.clone(),
        ollama:        ollama.clone(),
        vector_store:  vector_store.clone(),
        started:       std::time::Instant::now(),
        _unused:       AtomicBool::new(false),
    });

    // ── Initial sync + 5-minute periodic re-sync ──────────
    {
        let reg   = registry_arc.clone();
        let count = indexed_count.clone();
        tokio::spawn(async move {
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

    Ok(engine)
    }
}
