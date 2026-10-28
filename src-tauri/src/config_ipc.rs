/// Config, file-preview, onboarding, and Ollama-status IPC commands.

use crate::AppState;
use anyhow::Result;
use serde::{Deserialize, Serialize};
use serde_json::Value as JsonValue;
use std::{collections::HashMap, path::PathBuf};
use tauri::State;

/* ─── Config types ──────────────────────────────────────── */

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AppConfig {
    pub retention_days:   u32,
    pub blocked_apps:     Vec<String>,
    pub raw_storage:      bool,
    pub compress_raw:     bool,
    pub github_token:     String,
    pub enabled_plugins:  HashMap<String, bool>,
    pub file_roots:       Vec<String>,
    pub quota_bytes:      u64,
    /// Preferred terminal app for running shell commands (e.g. "Terminal",
    /// "iTerm", "kitty", "Alacritty", "WezTerm", "Ghostty").
    pub terminal:         String,
}

impl Default for AppConfig {
    fn default() -> Self {
        Self {
            retention_days:  30,
            blocked_apps:    vec![],
            raw_storage:     false,
            compress_raw:    false,
            github_token:    String::new(),
            enabled_plugins: HashMap::new(),
            file_roots:      vec![],
            quota_bytes:     5 * 1024 * 1024 * 1024,
            terminal:        default_terminal(),
        }
    }
}

/// Platform default terminal name.
pub fn default_terminal() -> String {
    #[cfg(target_os = "macos")]   { "Terminal".into() }
    #[cfg(target_os = "windows")] { "PowerShell".into() }
    #[cfg(target_os = "linux")]   { "xterm".into() }
}

/// Detect installed terminal emulators (for the picker in Settings/Onboarding).
#[tauri::command]
pub async fn detect_terminals() -> Vec<String> {
    tokio::task::spawn_blocking(|| {
        let mut found = Vec::new();
        #[cfg(target_os = "macos")]
        {
            let candidates = ["Terminal", "iTerm", "kitty", "Alacritty", "WezTerm", "Ghostty", "Warp", "Hyper"];
            for c in candidates {
                let app = format!("/Applications/{c}.app");
                let sys = format!("/System/Applications/Utilities/{c}.app");
                if std::path::Path::new(&app).exists() || std::path::Path::new(&sys).exists() {
                    found.push(c.to_string());
                }
            }
        }
        #[cfg(target_os = "windows")]
        { found.push("PowerShell".into()); found.push("cmd".into()); if which("wt") { found.push("Windows Terminal".into()); } }
        #[cfg(target_os = "linux")]
        {
            for c in ["kitty", "alacritty", "wezterm", "gnome-terminal", "konsole", "xterm", "foot"] {
                if which(c) { found.push(c.to_string()); }
            }
        }
        if found.is_empty() { found.push(default_terminal()); }
        found
    }).await.unwrap_or_else(|_| vec![default_terminal()])
}

#[cfg(not(target_os = "macos"))]
fn which(bin: &str) -> bool {
    std::process::Command::new("which").arg(bin).output().map(|o| o.status.success()).unwrap_or(false)
}

/// Read the configured terminal (fast, used by the executor).
pub fn configured_terminal() -> String {
    load_config().terminal
}

/* ─── Config path ───────────────────────────────────────── */

fn config_path() -> PathBuf {
    dirs::home_dir()
        .unwrap_or_default()
        .join(".cortex/config.json")
}

pub fn load_config() -> AppConfig {
    let Ok(raw) = std::fs::read_to_string(config_path()) else {
        return AppConfig::default();
    };
    serde_json::from_str(&raw).unwrap_or_default()
}

fn save_config(cfg: &AppConfig) -> Result<()> {
    let path = config_path();
    std::fs::create_dir_all(path.parent().unwrap_or(&path))?;
    std::fs::write(path, serde_json::to_string_pretty(cfg)?)?;
    Ok(())
}

/* ─── IPC: get_config ───────────────────────────────────── */

#[tauri::command]
pub async fn get_config(_state: State<'_, AppState>) -> Result<AppConfig, String> {
    Ok(tokio::task::spawn_blocking(load_config).await.unwrap_or_default())
}

/* ─── IPC: set_config ───────────────────────────────────── */

#[tauri::command]
pub async fn set_config(
    key:   String,
    value: JsonValue,
    _state: State<'_, AppState>,
) -> Result<(), String> {
    tokio::task::spawn_blocking(move || {
        let mut cfg = load_config();
        // Patch the field identified by `key`
        match key.as_str() {
            "retentionDays"  => { cfg.retention_days  = value.as_u64().unwrap_or(30) as u32; }
            "blockedApps"    => { cfg.blocked_apps    = serde_json::from_value(value).unwrap_or_default(); }
            "rawStorage"     => { cfg.raw_storage     = value.as_bool().unwrap_or(false); }
            "compressRaw"    => { cfg.compress_raw    = value.as_bool().unwrap_or(false); }
            "githubToken"    => { cfg.github_token    = value.as_str().unwrap_or("").to_string(); }
            "enabledPlugins" => { cfg.enabled_plugins = serde_json::from_value(value).unwrap_or_default(); }
            "fileRoots"      => { cfg.file_roots      = serde_json::from_value(value).unwrap_or_default(); }
            "quotaBytes"     => { cfg.quota_bytes     = value.as_u64().unwrap_or(5 * 1024 * 1024 * 1024); }
            "terminal"       => { cfg.terminal        = value.as_str().unwrap_or("Terminal").to_string(); }
            _                => {}
        }
        save_config(&cfg).map_err(|e| e.to_string())
    })
    .await
    .map_err(|e| e.to_string())?
}

/* ─── IPC: clear_captures ───────────────────────────────── */

#[tauri::command]
pub async fn clear_captures(_state: State<'_, AppState>) -> Result<(), String> {
    tokio::task::spawn_blocking(|| {
        let captures = dirs::home_dir()
            .unwrap_or_default()
            .join(".cortex/captures");
        if captures.exists() {
            std::fs::remove_dir_all(&captures)
                .map_err(|e| e.to_string())?;
            std::fs::create_dir_all(&captures)
                .map_err(|e| e.to_string())?;
        }
        Ok::<_, String>(())
    })
    .await
    .map_err(|e| e.to_string())?
}

/* ─── IPC: open_data_folder ─────────────────────────────── */

#[tauri::command]
pub async fn open_data_folder(_state: State<'_, AppState>) -> Result<(), String> {
    let path = dirs::home_dir().unwrap_or_default().join(".cortex");
    tokio::task::spawn_blocking(move || {
        opener::open(&path).map_err(|e| e.to_string())
    })
    .await
    .map_err(|e| e.to_string())?
}

/* ─── IPC: read_file_preview ────────────────────────────── */

#[tauri::command]
pub async fn read_file_preview(
    path:      String,
    max_lines: Option<usize>,
) -> Result<String, String> {
    let limit = max_lines.unwrap_or(100).min(2_000);
    tokio::task::spawn_blocking(move || {
        use std::io::Read;
        // Read at most 256 KB — previewing a multi-GB log must not load it all.
        let mut buf = Vec::with_capacity(64 * 1024);
        std::fs::File::open(&path)
            .and_then(|f| f.take(256 * 1024).read_to_end(&mut buf))
            .map_err(|e| e.to_string())?;
        if buf.iter().take(8_192).any(|&b| b == 0) {
            return Err("Binary file — no text preview".to_string());
        }
        let content = String::from_utf8_lossy(&buf);
        let lines: Vec<&str> = content.lines().take(limit).collect();
        Ok::<String, String>(lines.join("\n"))
    })
    .await
    .map_err(|e| e.to_string())?
}

/* ─── IPC: set_onboarding_complete ─────────────────────── */

#[tauri::command]
pub async fn set_onboarding_complete(_state: State<'_, AppState>) -> Result<(), String> {
    tokio::task::spawn_blocking(|| {
        let flag = dirs::home_dir()
            .unwrap_or_default()
            .join(".cortex/.onboarding_complete");
        std::fs::write(flag, "1").map_err(|e| e.to_string())
    })
    .await
    .map_err(|e| e.to_string())?
}

/* ─── IPC: get_onboarding_complete ─────────────────────── */

#[tauri::command]
pub async fn get_onboarding_complete() -> bool {
    let flag = dirs::home_dir()
        .unwrap_or_default()
        .join(".cortex/.onboarding_complete");
    flag.exists()
}

/* ─── IPC: get_ollama_status ────────────────────────────── */

#[tauri::command]
pub async fn get_ollama_status(
    state: State<'_, AppState>,
) -> Result<crate::ollama::OllamaStatus, String> {
    // Cloud chat configured → AI works without any local daemon. Report Ready.
    if crate::exec_ipc::ollama_cfg().api_key.is_some() {
        return Ok(crate::ollama::OllamaStatus::Ready);
    }
    // Always do a live check — don't return cached Unavailable from before first poll.
    Ok(state.inner().ollama.check_health().await)
}

/* ─── IPC: check_ollama_health ──────────────────────────── */
// Returns { available, models } shape expected by Onboarding.tsx

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct OllamaHealthResult {
    pub available:      bool,
    pub models:         Vec<String>,
    pub missing_models: Vec<String>,
}

#[tauri::command]
pub async fn check_ollama_health(
    state: State<'_, AppState>,
) -> Result<OllamaHealthResult, String> {
    // Cloud chat configured → AI available regardless of any local models.
    if crate::exec_ipc::ollama_cfg().api_key.is_some() {
        let names = state.inner().ollama.list_models().await
            .map(|m| m.into_iter().map(|x| x.name).collect())
            .unwrap_or_default();
        return Ok(OllamaHealthResult { available: true, models: names, missing_models: vec![] });
    }
    match state.inner().ollama.list_models().await {
        Err(_) => Ok(OllamaHealthResult {
            available: false, models: vec![],
            missing_models: vec!["nomic-embed-text".into()],
        }),
        Ok(models) => {
            // phi3 removed — chat is cloud. nomic only (local semantic search).
            const REQUIRED: &[&str] = &["nomic-embed-text"];
            let names: Vec<String> = models.into_iter().map(|m| m.name).collect();
            let missing: Vec<String> = REQUIRED.iter()
                .filter(|&&req| !names.iter().any(|n| n.starts_with(req)))
                .map(|s| s.to_string())
                .collect();
            Ok(OllamaHealthResult { available: true, models: names, missing_models: missing })
        }
    }
}

/* ─── IPC: oauth_connect ────────────────────────────────── */

#[tauri::command]
pub async fn oauth_connect(
    source: String,
    _state: State<'_, AppState>,
) -> Result<bool, String> {
    tracing::info!("oauth_connect requested for: {source}");
    Ok(false) // per-source extended in auth.rs
}

/* ─── IPC: check_google_auth ────────────────────────────── */

#[tauri::command]
pub async fn check_google_auth() -> Result<crate::auth::GoogleAuthStatus, String> {
    tokio::task::spawn_blocking(crate::auth::check_google_auth_sync)
        .await
        .map_err(|e| e.to_string())
}

/* ─── IPC: connect_google ───────────────────────────────── */

#[tauri::command]
pub async fn connect_google() -> Result<crate::auth::GoogleAuthStatus, String> {
    crate::auth::connect_google_oauth()
        .await
        .map_err(|e| e.to_string())
}

/* ─── IPC: check_github_token ───────────────────────────── */

#[tauri::command]
pub async fn check_github_token() -> crate::auth::GithubAuthStatus {
    crate::auth::check_github_token().await
}

/* ─── IPC: open_url ─────────────────────────────────────── */
// Uses the `opener` crate (not the shell plugin scope) so arbitrary
// schemes work — e.g. macOS deeplinks `x-apple.systempreferences:...`.

#[tauri::command]
pub async fn open_url(url: String) -> Result<(), String> {
    tokio::task::spawn_blocking(move || opener::open(&url).map_err(|e| e.to_string()))
        .await
        .map_err(|e| e.to_string())?
}

/* ─── IPC: spotlight_search (whole-Mac file search) ─────── */

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FileHit { pub name: String, pub path: String, #[serde(default)] pub is_dir: bool }

const NOISE: &[&str] = &["/node_modules/", "/.git/", "/Library/Caches/", "/.Trash/", "/DerivedData/", "/.cargo/", "/.rustup/", "/Library/Developer/"];
// Bundle suffixes — these are "apps", not files; exclude from file search.
const BUNDLE_EXT: &[&str] = &[".app", ".framework", ".bundle", ".appex", ".xpc", ".prefPane", ".kext"];

/// Directory names never descended into during the fallback walk.
const WALK_SKIP: &[&str] = &[
    "node_modules", ".git", "Library", ".Trash", ".cache", "target", "dist",
    "build", "out", ".venv", "venv", "__pycache__", "Pods", "DerivedData",
    ".cargo", ".rustup", ".npm", ".pnpm-store", "vendor", ".next", ".gradle",
];

#[tauri::command]
pub async fn spotlight_search(query: String, limit: Option<usize>) -> Vec<FileHit> {
    let lim = limit.unwrap_or(20);
    let q = query.trim().to_string();
    if q.len() < 2 { return vec![]; }
    tokio::task::spawn_blocking(move || {
        let home = dirs::home_dir().unwrap_or_default();

        // 1) Try Spotlight (fast, whole-disk) — but it's off on some Macs.
        #[cfg(target_os = "macos")]
        {
            let out = std::process::Command::new("mdfind")
                .args(["-onlyin", &home.to_string_lossy(), "-name", &q]).output();
            if let Ok(out) = out {
                let hits: Vec<FileHit> = String::from_utf8_lossy(&out.stdout).lines()
                    .filter(|p| !NOISE.iter().any(|n| p.contains(n)))
                    .filter(|p| !BUNDLE_EXT.iter().any(|e| p.ends_with(e) || p.contains(&format!("{e}/"))))
                    .take(lim)
                    .map(|p| FileHit {
                        name: std::path::Path::new(p).file_name().map(|f| f.to_string_lossy().to_string()).unwrap_or_else(|| p.to_string()),
                        path: p.to_string(),
                        is_dir: std::path::Path::new(p).is_dir(),
                    }).collect();
                if !hits.is_empty() { return hits; }
            }
        }

        // 2) Fallback: direct filename walk of $HOME (works without Spotlight).
        let ql = q.to_lowercase();
        let mut hits: Vec<FileHit> = Vec::new();
        let walker = walkdir::WalkDir::new(&home).max_depth(7).follow_links(false)
            .into_iter()
            .filter_entry(|e| {
                let name = e.file_name().to_string_lossy();
                // prune hidden + heavy/noise dirs
                if e.file_type().is_dir() {
                    if name.starts_with('.') && name != "." { return false; }
                    if WALK_SKIP.contains(&name.as_ref()) { return false; }
                }
                true
            });
        for entry in walker.filter_map(|e| e.ok()) {
            // Match BOTH files and folders (skip the root itself).
            let is_dir = entry.file_type().is_dir();
            if entry.depth() == 0 { continue; }
            let name = entry.file_name().to_string_lossy().to_string();
            if name.to_lowercase().contains(&ql) {
                let p = entry.path().to_string_lossy().to_string();
                if BUNDLE_EXT.iter().any(|e| p.ends_with(e) || p.contains(&format!("{e}/"))) { continue; }
                hits.push(FileHit { name, path: p, is_dir });
                if hits.len() >= lim { break; }
            }
        }
        // Folders first, then files — Finder-like.
        hits.sort_by(|a, b| b.is_dir.cmp(&a.is_dir));
        hits
    }).await.unwrap_or_default()
}

/// List a directory's immediate children — Finder-style browse for the Files
/// scope when the search box is empty. Folders first, then files; hidden
/// dotfiles skipped. `path` defaults to the home directory.
#[tauri::command]
pub async fn list_dir(path: Option<String>) -> Vec<FileHit> {
    tokio::task::spawn_blocking(move || {
        let dir = path.map(std::path::PathBuf::from)
            .unwrap_or_else(|| dirs::home_dir().unwrap_or_default());
        let rd = match std::fs::read_dir(&dir) { Ok(r) => r, Err(_) => return vec![] };
        let mut entries: Vec<FileHit> = rd.filter_map(|e| e.ok())
            .filter_map(|e| {
                let name = e.file_name().to_string_lossy().to_string();
                if name.starts_with('.') { return None; } // hide dotfiles (Finder default)
                let p = e.path();
                let is_dir = p.is_dir();
                // Treat .app etc as openable files, not browsable dirs.
                let bundle = BUNDLE_EXT.iter().any(|x| name.ends_with(x));
                Some(FileHit { name, path: p.to_string_lossy().to_string(), is_dir: is_dir && !bundle })
            })
            .collect();
        // Folders first, then alphabetical (case-insensitive).
        entries.sort_by(|a, b| b.is_dir.cmp(&a.is_dir)
            .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase())));
        entries.truncate(300);
        entries
    }).await.unwrap_or_default()
}

/* ─── IPC: github_stats ─────────────────────────────────── */

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GithubStats {
    pub total_repos: i64, pub commits_7d: i64, pub repos_active_7d: i64,
    pub top_langs: Vec<String>, pub summary: String,
}

/// Computes a quick activity summary from the indexed github DB. Returns None
/// if there's no data yet. Also used to feed the AI grounding context.
pub fn github_stats() -> Option<GithubStats> {
    let db = dirs::home_dir()?.join(".cortex/github/items.db");
    let conn = rusqlite::Connection::open(db).ok()?;
    let now = chrono::Utc::now().timestamp();
    let wk = now - 7 * 86_400;

    let total_repos: i64 = conn.query_row("SELECT COUNT(*) FROM items WHERE kind='repo'", [], |r| r.get(0)).unwrap_or(0);
    let commits_7d: i64 = conn.query_row("SELECT COUNT(*) FROM items WHERE kind='commit' AND updated_unix > ?1", [wk], |r| r.get(0)).unwrap_or(0);
    let repos_active_7d: i64 = conn.query_row("SELECT COUNT(DISTINCT repo) FROM items WHERE kind='commit' AND updated_unix > ?1", [wk], |r| r.get(0)).unwrap_or(0);

    // Top languages across repos (labels_json holds [lang, tags...]).
    let mut lang_count: HashMap<String, i64> = HashMap::new();
    if let Ok(mut stmt) = conn.prepare("SELECT labels_json FROM items WHERE kind='repo'") {
        if let Ok(rows) = stmt.query_map([], |r| r.get::<_, String>(0)) {
            for j in rows.flatten() {
                if let Ok(tags) = serde_json::from_str::<Vec<String>>(&j) {
                    if let Some(lang) = tags.first() {
                        if !["private", "fork"].contains(&lang.as_str()) {
                            *lang_count.entry(lang.clone()).or_insert(0) += 1;
                        }
                    }
                }
            }
        }
    }
    let mut langs: Vec<(String, i64)> = lang_count.into_iter().collect();
    langs.sort_by(|a, b| b.1.cmp(&a.1));
    let top_langs: Vec<String> = langs.into_iter().take(4).map(|(l, _)| l).collect();

    if total_repos == 0 && commits_7d == 0 { return None; }
    let summary = format!(
        "{total_repos} repos · {commits_7d} commits in the last 7 days across {repos_active_7d} repos{}",
        if top_langs.is_empty() { String::new() } else { format!(" · top languages: {}", top_langs.join(", ")) }
    );
    Some(GithubStats { total_repos, commits_7d, repos_active_7d, top_langs, summary })
}

#[tauri::command]
pub async fn get_github_stats() -> Option<GithubStats> {
    tokio::task::spawn_blocking(github_stats).await.ok().flatten()
}

/* ─── IPC: snippets (saved reusable text) ───────────────── */

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Snippet { pub id: String, pub label: String, pub content: String, pub ts: i64 }

fn snippets_db() -> Result<rusqlite::Connection, String> {
    let path = dirs::home_dir().unwrap_or_default().join(".cortex/snippets.db");
    if let Some(p) = path.parent() { let _ = std::fs::create_dir_all(p); }
    let conn = rusqlite::Connection::open(path).map_err(|e| e.to_string())?;
    conn.execute_batch("CREATE TABLE IF NOT EXISTS snippets (id TEXT PRIMARY KEY, label TEXT, content TEXT, ts INTEGER)")
        .map_err(|e| e.to_string())?;
    Ok(conn)
}

#[tauri::command]
pub async fn snippet_list() -> Vec<Snippet> {
    tokio::task::spawn_blocking(|| {
        let Ok(conn) = snippets_db() else { return vec![] };
        let Ok(mut stmt) = conn.prepare("SELECT id, label, content, ts FROM snippets ORDER BY ts DESC LIMIT 200") else { return vec![] };
        stmt.query_map([], |r| Ok(Snippet { id: r.get(0)?, label: r.get(1)?, content: r.get(2)?, ts: r.get(3)? }))
            .map(|rs| rs.filter_map(|x| x.ok()).collect()).unwrap_or_default()
    }).await.unwrap_or_default()
}

#[tauri::command]
pub async fn snippet_add(label: String, content: String) -> Result<(), String> {
    tokio::task::spawn_blocking(move || {
        let conn = snippets_db()?;
        let id = uuid::Uuid::new_v4().to_string();
        let lbl = if label.trim().is_empty() { content.lines().next().unwrap_or("snippet").chars().take(50).collect() } else { label };
        conn.execute("INSERT INTO snippets (id, label, content, ts) VALUES (?1,?2,?3,?4)",
            rusqlite::params![id, lbl, content, chrono::Utc::now().timestamp()]).map_err(|e| e.to_string())?;
        Ok::<_, String>(())
    }).await.map_err(|e| e.to_string())?
}

#[tauri::command]
pub async fn snippet_delete(id: String) -> Result<(), String> {
    tokio::task::spawn_blocking(move || {
        let conn = snippets_db()?;
        conn.execute("DELETE FROM snippets WHERE id = ?1", rusqlite::params![id]).map_err(|e| e.to_string())?;
        Ok::<_, String>(())
    }).await.map_err(|e| e.to_string())?
}

/* ─── IPC: get_clipboard_history ────────────────────────── */

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ClipHit { pub id: String, pub preview: String, pub content: String, pub source_app: String, pub ts: i64 }

#[tauri::command]
pub async fn get_clipboard_history(limit: Option<usize>) -> Vec<ClipHit> {
    let lim = limit.unwrap_or(50);
    tokio::task::spawn_blocking(move || {
        let path = dirs::home_dir().unwrap_or_default().join(".cortex/clipboard/clipboard.db");
        let Ok(conn) = rusqlite::Connection::open(path) else { return vec![] };
        let Ok(mut stmt) = conn.prepare("SELECT id, content, COALESCE(source_app,''), ts FROM clips ORDER BY ts DESC LIMIT ?1") else { return vec![] };
        let rows = stmt.query_map([lim as i64], |r| {
            let content: String = r.get(1)?;
            let preview = content.split_whitespace().collect::<Vec<_>>().join(" ").chars().take(90).collect::<String>();
            Ok(ClipHit { id: r.get(0)?, preview, content, source_app: r.get(2)?, ts: r.get(3)? })
        });
        rows.map(|rs| rs.filter_map(|r| r.ok()).collect()).unwrap_or_default()
    }).await.unwrap_or_default()
}

/* ─── IPC: window_action (resize the previously-active app) ── */

#[tauri::command]
pub async fn window_action(action: String, state: State<'_, AppState>) -> Result<(), String> {
    let app = state.inner().last_app.lock().map(|g| g.clone()).unwrap_or_default();
    tracing::info!(target: "aio_cortex_lib", "window_action: action={action} last_app={app:?}");
    if app.is_empty() { return Err("no recent app to manage — switch to an app first, then ⌘K".into()); }
    let app_log = app.clone();
    let action_log = action.clone();
    let r = tokio::task::spawn_blocking(move || {
        #[cfg(target_os = "macos")]
        {
            // Fullscreen is a separate keystroke toggle (always needs Accessibility).
            if action == "full" {
                let s = format!("tell application \"{app}\" to activate\ndelay 0.1\ntell application \"System Events\" to keystroke \"f\" using {{control down, command down}}");
                let o = std::process::Command::new("osascript").args(["-e", &s]).output().map_err(|e| e.to_string())?;
                if o.status.success() { return Ok(()); }
                let err = String::from_utf8_lossy(&o.stderr);
                return Err(if err.contains("-1719") || err.contains("not allowed assistive") {
                    "Fullscreen needs Accessibility: System Settings → Privacy → Accessibility → enable Cortex".into()
                } else { err.trim().to_string() });
            }

            // Compute integer L/T/R/B (AppleScript `div` = integer division; floats
            // like 840.0 make some apps reject `set bounds` with -10006).
            let geom = match action.as_str() {
                "left"   => "set L to x0\nset T to 25\nset R to x0 + (W div 2)\nset B to y1",
                "right"  => "set L to x0 + (W div 2)\nset T to 25\nset R to x1\nset B to y1",
                "max"    => "set L to x0\nset T to 25\nset R to x1\nset B to y1",
                "center" => "set ww to (W * 2) div 3\nset hh to (H * 4) div 5\nset L to x0 + ((W - ww) div 2)\nset T to 25 + ((H - hh) div 2)\nset R to L + ww\nset B to T + hh",
                _ => return Err("unknown window action".into()),
            };

            // Two-tier: try Standard-Suite `set bounds` (no Accessibility — works for
            // Safari/Chrome/Brave/Finder/most Cocoa apps). On apps that don't support
            // it (kitty, Alacritty, … → -10006/-1708), fall back to System Events
            // position+size (needs Accessibility).
            let script = format!(
                "tell application \"Finder\" to set sb to bounds of window of desktop\n\
                 set {{x0, y0, x1, y1}} to sb\n\
                 set W to x1 - x0\n\
                 set H to y1 - y0\n\
                 {geom}\n\
                 tell application \"{app}\" to activate\n\
                 try\n\
                 \ttell application \"{app}\" to set bounds of front window to {{L, T, R, B}}\n\
                 on error\n\
                 \ttell application \"System Events\" to tell process \"{app}\"\n\
                 \t\tset position of front window to {{L, T}}\n\
                 \t\tset size of front window to {{R - L, B - T}}\n\
                 \tend tell\n\
                 end try"
            );
            let o = std::process::Command::new("osascript").args(["-e", &script]).output().map_err(|e| e.to_string())?;
            if o.status.success() { return Ok(()); }
            let err = String::from_utf8_lossy(&o.stderr);
            if err.contains("-1719") || err.contains("not allowed assistive") {
                Err(format!("{app} needs Accessibility to resize (doesn't support native bounds): System Settings → Privacy → Accessibility → enable Cortex"))
            } else if err.contains("-1728") || err.contains("doesn't understand") {
                Err(format!("{app} has no resizable window"))
            } else {
                Err(err.trim().to_string())
            }
        }
        #[cfg(not(target_os = "macos"))]
        { let _ = action; Err("window actions are macOS-only".into()) }
    }).await.map_err(|e| e.to_string())?;
    tracing::info!(target: "aio_cortex_lib", "window_action result: app={app_log:?} action={action_log} -> {r:?}");
    r
}

/* ─── IPC: get_open_tabs (live browser tabs via AppleScript) ─ */

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TabInfo { pub browser: String, pub title: String, pub url: String }

/// Read currently-open tabs from running Chromium-family browsers + Safari via
/// AppleScript. Only queries browsers that are ALREADY running (so we never
/// launch one). No browser extension required.
pub fn read_open_tabs() -> Vec<TabInfo> {
    #[cfg(not(target_os = "macos"))]
    { return vec![]; }
    #[cfg(target_os = "macos")]
    {
        // Fast running-check so we never spawn AppleScript (or launch) a
        // browser that isn't open — that was the multi-second delay.
        let is_running = |proc: &str| {
            std::process::Command::new("pgrep").args(["-x", proc]).output()
                .map(|o| o.status.success()).unwrap_or(false)
        };

        let mut tabs = Vec::new();
        // Chromium family: same scripting dictionary.
        for app in ["Brave Browser", "Google Chrome", "Arc", "Chromium", "Microsoft Edge"] {
            if !is_running(app) { continue; }
            let script = format!(
                r#"tell application "{app}"
                        set out to ""
                        repeat with w in windows
                            repeat with t in tabs of w
                                set out to out & (title of t) & "\t" & (URL of t) & linefeed
                            end repeat
                        end repeat
                        return out
                    end tell"#);
            if let Ok(o) = std::process::Command::new("osascript").args(["-e", &script]).output() {
                for line in String::from_utf8_lossy(&o.stdout).lines() {
                    if let Some((title, url)) = line.split_once('\t') {
                        if url.starts_with("http") {
                            tabs.push(TabInfo { browser: app.to_string(), title: title.to_string(), url: url.to_string() });
                        }
                    }
                }
            }
        }
        // Safari.
        let safari = r#"tell application "Safari"
                set out to ""
                repeat with w in windows
                    repeat with t in tabs of w
                        set out to out & (name of t) & "\t" & (URL of t) & linefeed
                    end repeat
                end repeat
                return out
            end tell"#;
        if is_running("Safari") {
        if let Ok(o) = std::process::Command::new("osascript").args(["-e", safari]).output() {
            for line in String::from_utf8_lossy(&o.stdout).lines() {
                if let Some((title, url)) = line.split_once('\t') {
                    if url.starts_with("http") {
                        tabs.push(TabInfo { browser: "Safari".into(), title: title.to_string(), url: url.to_string() });
                    }
                }
            }
        }
        }
        tabs
    }
}

#[tauri::command]
pub async fn get_open_tabs() -> Vec<TabInfo> {
    tokio::task::spawn_blocking(read_open_tabs).await.unwrap_or_default()
}

/* ─── IPC: get_running_apps (currently open apps) ───────── */

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RunningApp { pub name: String, pub path: String }

#[tauri::command]
pub async fn get_running_apps() -> Vec<RunningApp> {
    tokio::task::spawn_blocking(|| {
        #[cfg(target_os = "macos")]
        {
            let script = r#"tell application "System Events"
                set out to ""
                repeat with p in (every process whose background only is false)
                    try
                        set out to out & (POSIX path of (file of p)) & linefeed
                    end try
                end repeat
                return out
            end tell"#;
            let Ok(out) = std::process::Command::new("osascript").args(["-e", script]).output() else { return vec![] };
            String::from_utf8_lossy(&out.stdout).lines()
                .filter(|p| p.ends_with(".app"))
                .map(|p| RunningApp {
                    name: std::path::Path::new(p).file_stem().map(|f| f.to_string_lossy().to_string()).unwrap_or_default(),
                    path: p.to_string(),
                })
                .filter(|a| !a.name.is_empty() && a.name != "Cortex")
                .collect()
        }
        #[cfg(not(target_os = "macos"))]
        { vec![] }
    }).await.unwrap_or_default()
}

/* ─── IPC: file metadata + Finder / Quick Look ──────────── */

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FileMeta {
    pub size:     u64,
    pub modified: i64,   // unix secs
    pub is_dir:   bool,
    pub kind:     String,
    pub exists:   bool,
}

fn kind_for(path: &std::path::Path, is_dir: bool) -> String {
    if path.extension().and_then(|e| e.to_str()) == Some("app") { return "Application".into(); }
    if is_dir { return "Folder".into(); }
    match path.extension().and_then(|e| e.to_str()).unwrap_or("").to_lowercase().as_str() {
        "rs" => "Rust Source", "ts" | "tsx" => "TypeScript", "js" | "jsx" => "JavaScript",
        "py" => "Python", "go" => "Go", "md" | "mdx" => "Markdown", "json" => "JSON",
        "toml" => "TOML", "yaml" | "yml" => "YAML", "png" | "jpg" | "jpeg" | "gif" | "webp" => "Image",
        "pdf" => "PDF", "txt" => "Text", "sh" | "bash" | "zsh" => "Shell Script",
        "html" => "HTML", "css" | "scss" => "Stylesheet", "lock" => "Lockfile",
        "" => "File", other => return format!("{} File", other.to_uppercase()),
    }.to_string()
}

#[tauri::command]
pub async fn get_file_meta(path: String) -> Result<FileMeta, String> {
    tokio::task::spawn_blocking(move || {
        let p = std::path::Path::new(&path);
        let Ok(meta) = std::fs::metadata(p) else {
            return FileMeta { size: 0, modified: 0, is_dir: false, kind: "Unknown".into(), exists: false };
        };
        let modified = meta.modified().ok()
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|d| d.as_secs() as i64).unwrap_or(0);
        let is_dir = meta.is_dir();
        FileMeta { size: meta.len(), modified, is_dir, kind: kind_for(p, is_dir), exists: true }
    })
    .await
    .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn reveal_in_finder(path: String) -> Result<(), String> {
    tokio::task::spawn_blocking(move || {
        #[cfg(target_os = "macos")]
        { std::process::Command::new("open").args(["-R", &path]).spawn().map(|_| ()).map_err(|e| e.to_string()) }
        #[cfg(not(target_os = "macos"))]
        {
            let dir = std::path::Path::new(&path).parent().map(|p| p.to_path_buf()).unwrap_or_default();
            opener::open(dir).map_err(|e| e.to_string())
        }
    }).await.map_err(|e| e.to_string())?
}

#[tauri::command]
pub async fn quick_look(path: String) -> Result<(), String> {
    tokio::task::spawn_blocking(move || {
        #[cfg(target_os = "macos")]
        { std::process::Command::new("qlmanage").args(["-p", &path]).spawn().map(|_| ()).map_err(|e| e.to_string()) }
        #[cfg(not(target_os = "macos"))]
        { opener::open(&path).map_err(|e| e.to_string()) }
    }).await.map_err(|e| e.to_string())?
}

/* ─── IPC: get_app_icon ─────────────────────────────────── */
// Extracts a macOS .app icon → 64px PNG (via `sips`), cached under
// ~/.cortex/iconcache/, returned as a base64 data URL for <img>.

#[cfg(target_os = "macos")]
fn resolve_icns(app_path: &str) -> Option<PathBuf> {
    use std::process::Command;
    let resources = PathBuf::from(app_path).join("Contents/Resources");

    // 1) Info.plist → CFBundleIconFile
    if let Ok(out) = Command::new("defaults")
        .arg("read")
        .arg(format!("{app_path}/Contents/Info"))
        .arg("CFBundleIconFile")
        .output()
    {
        if out.status.success() {
            let mut name = String::from_utf8_lossy(&out.stdout).trim().to_string();
            if !name.is_empty() {
                if !name.ends_with(".icns") { name.push_str(".icns"); }
                let cand = resources.join(&name);
                if cand.exists() { return Some(cand); }
            }
        }
    }
    // 2) Fallback: first *.icns in Resources
    std::fs::read_dir(&resources).ok()?.flatten()
        .map(|e| e.path())
        .find(|p| p.extension().and_then(|x| x.to_str()) == Some("icns"))
}

/// Swift helper using NSWorkspace — returns the REAL displayed icon for any
/// app, including those whose icon lives in Assets.car (no .icns). Compiled
/// once into ~/.cortex/iconhelper and reused.
#[cfg(target_os = "macos")]
fn icon_helper() -> Option<std::path::PathBuf> {
    use std::sync::OnceLock;
    static HELPER: OnceLock<Option<std::path::PathBuf>> = OnceLock::new();
    HELPER.get_or_init(|| {
        let dir = dirs::home_dir()?.join(".cortex");
        let _ = std::fs::create_dir_all(&dir);
        let bin = dir.join("iconhelper");
        if bin.exists() { return Some(bin); }
        let src = dir.join("iconhelper.swift");
        let code = r#"import AppKit
let a = CommandLine.arguments
guard a.count >= 3 else { exit(2) }
let img = NSWorkspace.shared.icon(forFile: a[1])
let target = NSSize(width: 128, height: 128)
let out = NSImage(size: target)
out.lockFocus()
img.draw(in: NSRect(origin: .zero, size: target), from: .zero, operation: .sourceOver, fraction: 1.0)
out.unlockFocus()
guard let tiff = out.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
do { try png.write(to: URL(fileURLWithPath: a[2])) } catch { exit(1) }
"#;
        std::fs::write(&src, code).ok()?;
        let ok = std::process::Command::new("swiftc")
            .args(["-O"]).arg(&src).args(["-o"]).arg(&bin)
            .output().map(|o| o.status.success()).unwrap_or(false);
        if ok && bin.exists() {
            tracing::info!(target: "aio_cortex_lib", "icon helper compiled");
            Some(bin)
        } else {
            tracing::warn!(target: "aio_cortex_lib", "icon helper compile failed — falling back to sips/icns");
            None
        }
    }).clone()
}

#[cfg(target_os = "macos")]
fn app_icon_data_url(app_path: &str) -> Option<String> {
    use base64::Engine;
    use std::process::Command;

    let cache_dir = dirs::home_dir()?.join(".cortex/iconcache");
    let _ = std::fs::create_dir_all(&cache_dir);

    let key = {
        use sha2::{Digest, Sha256};
        let mut h = Sha256::new();
        h.update(app_path.as_bytes());
        hex::encode(&h.finalize()[..8])
    };
    let png = cache_dir.join(format!("{key}.png"));

    if !png.exists() {
        // Primary: NSWorkspace helper (handles every app).
        let mut done = false;
        if let Some(helper) = icon_helper() {
            done = Command::new(&helper).arg(app_path).arg(&png)
                .output().map(|o| o.status.success()).unwrap_or(false) && png.exists();
        }
        // Fallback: .icns + sips (for systems without swiftc, or if helper failed).
        if !done {
            let icns = resolve_icns(app_path)?;
            let ok = Command::new("sips").args(["-s", "format", "png"]).arg(&icns)
                .args(["--out"]).arg(&png).args(["-Z", "128"])
                .output().map(|o| o.status.success()).unwrap_or(false);
            if !ok || !png.exists() { return None; }
        }
    }

    let bytes = std::fs::read(&png).ok()?;
    Some(format!("data:image/png;base64,{}", base64::engine::general_purpose::STANDARD.encode(bytes)))
}

#[cfg(not(target_os = "macos"))]
fn app_icon_data_url(_app_path: &str) -> Option<String> { None }

#[tauri::command]
pub async fn get_app_icon(path: String) -> Option<String> {
    tokio::task::spawn_blocking(move || app_icon_data_url(&path)).await.ok().flatten()
}

/* ─── IPC: set_autohide ─────────────────────────────────── */
// Frontend disables autohide during onboarding/OAuth, re-enables on main palette.

#[tauri::command]
pub async fn set_autohide(enabled: bool, state: State<'_, AppState>) -> Result<(), String> {
    state.inner().autohide.store(enabled, std::sync::atomic::Ordering::Relaxed);
    Ok(())
}
