/// Tauri command handlers.
///
/// All commands receive `State<'_, AppState>` — access via `.inner()`.
/// `search` is the hot path: query → fan-out → rank → top-50 → respond.

use crate::{
    dir_size_bytes,
    plugin::{QueryIntent, SearchQuery, SearchResult, SourceType, TemporalFilter},
    ranker::Ranker,
    temporal::parse_time_expression,
    AppState,
};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::atomic::Ordering;
use tauri::State;

/* ─── Wire types ────────────────────────────────────────── */

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SearchRequest {
    pub query:         String,
    pub source_filter: Option<Vec<String>>,
    /// Client-requested max results. Capped at 50.
    pub limit:         Option<usize>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SearchResponse {
    pub results:           Vec<SearchResult>,
    pub sessions:          Vec<crate::daemon::SessionRecord>,
    pub total_ms:          u64,
    pub source_counts:     HashMap<String, usize>,
    pub mode:              String,
    /// Only present when mode == "execution"; the shell command we would run.
    pub execution_preview: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DaemonStatus {
    pub recording:      bool,
    /// Sum of all per-plugin counts.
    pub indexed_items:  u64,
    /// Bytes used under ~/.cortex/
    pub storage_bytes:  u64,
    /// plugin_id → item count
    pub plugin_counts:  HashMap<String, u64>,
    /// plugin_ids in registration order
    pub active_plugins: Vec<String>,
    pub last_sync:      String,
}

/* ─── search ─────────────────────────────────────────────
   Fan-out across all registered plugins in parallel,
   rank results with BM25 + temporal decay + behavioral boost,
   return the top N (≤ 50).
────────────────────────────────────────────────────────── */

#[tauri::command]
pub async fn search(
    req: SearchRequest,
    state: State<'_, AppState>,
) -> Result<SearchResponse, String> {
    let t0 = std::time::Instant::now();
    let s  = state.inner();

    tracing::info!(target: "aio_cortex_lib", "search: query={:?} filter={:?}", req.query, req.source_filter);

    let intent = detect_intent(&req.query);

    // Temporal filter: pure regex parse (fast, no LLM)
    let temporal = parse_time_expression(&req.query).map(|tr| TemporalFilter {
        after:  chrono::DateTime::from_timestamp(tr.start_unix, 0)
                    .map(|dt| dt.with_timezone(&chrono::Utc)),
        before: chrono::DateTime::from_timestamp(tr.end_unix, 0)
                    .map(|dt| dt.with_timezone(&chrono::Utc)),
        label:  tr.label,
    });

    let query = SearchQuery {
        raw:           req.query.clone(),
        terms:         tokenize(&req.query),
        temporal:      temporal.clone(),
        source_filter: req.source_filter.clone(),
        intent:        intent.clone(),
    };

    // ── Fan-out: every plugin searched in parallel ─────────
    let mut results: Vec<SearchResult> = {
        let registry = s.registry.read().await;
        registry.search_all(&query).await
    };
    tracing::debug!(target: "aio_cortex_lib", "search: fan-out returned {} raw results", results.len());

    // ── Temporal filter: drop results outside detected range ─
    if let Some(ref tf) = temporal {
        results.retain(|r| {
            let Some(ts) = r.timestamp else { return true }; // keep untimedstamped
            tf.after.map_or(true,  |a| ts >= a) &&
            tf.before.map_or(true, |b| ts <= b)
        });
    }

    // ── Cosine scores: try Qdrant search (500ms timeout) ──
    let cosine_scores = {
        let vs = s.vector_store.clone();
        let q  = req.query.clone();
        match tokio::time::timeout(
            std::time::Duration::from_millis(500),
            vs.search("cortex_index", &q, 50),
        ).await {
            Ok(hits) => hits.into_iter().collect::<HashMap<String, f32>>(),
            Err(_)   => HashMap::new(), // timeout — pure BM25
        }
    };

    // ── Rank: BM25 × cosine × temporal decay × behavioral ─
    {
        let mut ranker = s.ranker.write().await;
        ranker.inject_cosine_scores(cosine_scores);
        ranker.rank_top(&mut results, 50);
    }

    // ── Populate result cache for execute_result() ─────────
    {
        let mut cache = s.result_cache.write().await;
        // Evict old entries when cache grows beyond 500
        if cache.len() > 500 {
            cache.clear();
        }
        for r in &results {
            cache.insert(r.id.clone(), r.clone());
        }
    }

    // ── Slice to requested limit (hard cap 50) ─────────────
    let limit = req.limit.unwrap_or(50).min(50);
    results.truncate(limit);

    // ── Per-source counts ──────────────────────────────────
    let mut source_counts: HashMap<String, usize> = HashMap::new();
    for r in &results {
        *source_counts.entry(r.plugin_id.clone()).or_insert(0) += 1;
    }

    // ── Session context — most recent 3 sessions ───────────
    let sessions = s.session_graph
        .recent_sessions(3)
        .unwrap_or_default();

    let ms = t0.elapsed().as_millis() as u64;
    tracing::info!(target: "aio_cortex_lib", "search: {} results in {ms}ms ({:?})", results.len(), source_counts);

    Ok(SearchResponse {
        results,
        sessions,
        total_ms: ms,
        source_counts,
        mode: match intent {
            QueryIntent::Execution => "execution".into(),
            QueryIntent::Retrieval => "retrieval".into(),
        },
        execution_preview: None, // set by AI layer (Phase 3)
    })
}

/* ─── get_suggestions ────────────────────────────────────
   Default palette content (empty query): installed apps +
   most recently opened items. Cached so execute_result works.
────────────────────────────────────────────────────────── */

#[tauri::command]
pub async fn get_suggestions(
    state: State<'_, AppState>,
) -> Result<SearchResponse, String> {
    let t0 = std::time::Instant::now();
    let s  = state.inner();

    // Empty-query search → apps plugin returns its suggestion list.
    let empty = SearchQuery {
        raw:           String::new(),
        terms:         vec![],
        temporal:      None,
        source_filter: None,
        intent:        QueryIntent::Retrieval,
    };

    let mut results = {
        let registry = s.registry.read().await;
        registry.search_all(&empty).await
    };
    results.sort_unstable_by(|a, b| b.score.partial_cmp(&a.score).unwrap_or(std::cmp::Ordering::Equal));
    results.truncate(12);

    // Cache so clicking a suggestion can execute by id.
    {
        let mut cache = s.result_cache.write().await;
        for r in &results { cache.insert(r.id.clone(), r.clone()); }
    }

    let mut source_counts: HashMap<String, usize> = HashMap::new();
    for r in &results { *source_counts.entry(r.plugin_id.clone()).or_insert(0) += 1; }

    tracing::info!(target: "aio_cortex_lib", "suggestions: {} items in {}ms", results.len(), t0.elapsed().as_millis());

    Ok(SearchResponse {
        results,
        sessions: vec![],
        total_ms: t0.elapsed().as_millis() as u64,
        source_counts,
        mode: "retrieval".into(),
        execution_preview: None,
    })
}

/* ─── execute_result ─────────────────────────────────────
   Dispatch by SourceType — no plugin roundtrip needed for
   the common cases. After execution, boost the result in
   the ranker so it surfaces higher in future queries.
────────────────────────────────────────────────────────── */

#[tauri::command]
pub async fn execute_result(
    result_id: String,
    state: State<'_, AppState>,
) -> Result<(), String> {
    let s = state.inner();

    let result: SearchResult = {
        let cache = s.result_cache.read().await;
        cache.get(&result_id)
            .cloned()
            .ok_or_else(|| format!("result {result_id} not in cache — re-search first"))?
    };

    tracing::info!(target: "aio_cortex_lib", "execute: {} '{}' (path={:?} url={:?})",
        result.plugin_id, result.title, result.path, result.url);

    // Plugins that perform their own side-effecting action (system commands)
    // execute through the plugin; everything else goes through the type dispatcher.
    if result.plugin_id == "commands" {
        let reg = s.registry.read().await;
        if let Some(p) = reg.get("commands") {
            p.execute(&result).await
                .map_err(|e| { tracing::error!(target: "aio_cortex_lib", "command exec failed: {e}"); e.to_string() })?;
        }
    } else {
        execute_by_type(&result)
            .map_err(|e| { tracing::error!(target: "aio_cortex_lib", "execute failed: {e}"); e.to_string() })?;
    }

    // Behavioral boost — update in-memory + persist to SQLite
    s.ranker.write().await.record_open(&result_id);
    let db_path = s.data_dir.join("interactions.db");
    let id_clone = result_id.clone();
    tokio::task::spawn_blocking(move || Ranker::persist_open(&db_path, &id_clone));

    Ok(())
}

/// Dispatch an action based on the result's `source_type`.
fn execute_by_type(result: &SearchResult) -> anyhow::Result<()> {
    match &result.source_type {
        // ── File: open with OS default application ─────────
        SourceType::File => {
            let path = result.path.as_deref()
                .ok_or_else(|| anyhow::anyhow!("File result has no path"))?;
            opener::open(path)?;
        }

        // ── URL: open in default browser ───────────────────
        SourceType::Url => {
            let url = result.url.as_deref()
                .ok_or_else(|| anyhow::anyhow!("Url result has no url"))?;
            webbrowser::open(url)?;
        }

        // ── Shell command: run in a visible terminal ────────
        SourceType::ShellCommand => {
            let cmd = result.title.as_str();
            spawn_in_terminal(cmd)?;
        }

        // ── Git commit: git show <sha> in terminal ──────────
        SourceType::GitCommit => {
            let sha = result.metadata
                .get("sha")
                .and_then(|v| v.as_str())
                .unwrap_or("HEAD");
            let repo_path = result.metadata
                .get("repo_path")
                .and_then(|v| v.as_str())
                .unwrap_or(".");
            // Pipe through `less` so output is scrollable
            let cmd = format!("git -C {repo_path} show {sha}");
            spawn_in_terminal(&cmd)?;
        }

        // ── Clipboard: write content back to clipboard ──────
        SourceType::ClipboardText => {
            let text = result.content.as_deref()
                .unwrap_or(result.title.as_str());
            arboard::Clipboard::new()?.set_text(text.to_string())?;
        }

        // ── Unknown: best-effort fallback ───────────────────
        SourceType::Unknown => {
            if let Some(path) = &result.path {
                opener::open(path)?;
            } else if let Some(url) = &result.url {
                webbrowser::open(url)?;
            }
            // else: no-op
        }
    }
    Ok(())
}

/* ─── Terminal spawn ─────────────────────────────────────
   Opens a new terminal window running `cmd`.
   macOS  → Terminal.app via AppleScript
   Linux  → detects $TERM_PROGRAM, falls back to xterm
   Windows → cmd.exe /c start cmd /k
────────────────────────────────────────────────────────── */

fn spawn_in_terminal(cmd: &str) -> anyhow::Result<()> {
    let term = crate::config_ipc::configured_terminal();

    #[cfg(target_os = "macos")]
    {
        let escaped = cmd.replace('\\', "\\\\").replace('"', "\\\"");
        match term.as_str() {
            // AppleScript-driven terminals.
            "Terminal" | "iTerm" | "iTerm2" => {
                let app = if term.starts_with("iTerm") { "iTerm" } else { "Terminal" };
                let script = if app == "iTerm" {
                    format!(r#"tell application "iTerm"
                        create window with default profile
                        tell current session of current window to write text "{escaped}"
                        activate
                    end tell"#)
                } else {
                    format!(r#"tell application "Terminal"
                        do script "{escaped}"
                        activate
                    end tell"#)
                };
                std::process::Command::new("osascript").args(["-e", &script]).spawn()?;
            }
            // CLI terminals that accept `-e`/`start`.
            "kitty"     => { std::process::Command::new("kitty").args(["sh", "-c", &format!("{cmd}; exec $SHELL")]).spawn()?; }
            "Alacritty" => { std::process::Command::new("alacritty").args(["-e", "sh", "-c", &format!("{cmd}; exec $SHELL")]).spawn()?; }
            "WezTerm"   => { std::process::Command::new("wezterm").args(["start", "--", "sh", "-c", &format!("{cmd}; exec $SHELL")]).spawn()?; }
            "Ghostty"   => { std::process::Command::new("open").args(["-a", "Ghostty"]).spawn()?;
                             std::process::Command::new("osascript").args(["-e", &format!(r#"tell application "Terminal" to do script "{escaped}""#)]).spawn().ok(); }
            other       => { std::process::Command::new("open").args(["-a", other]).spawn()?; }
        }
        return Ok(());
    }

    #[cfg(target_os = "linux")]
    {
        // Prefer the running terminal emulator; fall back down the list
        let term = detect_linux_terminal();
        std::process::Command::new(&term)
            .args(terminal_exec_args(&term, cmd))
            .spawn()?;
        return Ok(());
    }

    #[cfg(target_os = "windows")]
    {
        std::process::Command::new("cmd")
            .args(["/c", "start", "cmd", "/k", cmd])
            .spawn()?;
        return Ok(());
    }

    #[allow(unreachable_code)]
    Ok(())
}

#[cfg(target_os = "linux")]
fn detect_linux_terminal() -> String {
    // $TERM_PROGRAM is set by VS Code, Ghostty, Warp, etc.
    // $COLORTERM / $TERM are weaker signals but useful fallbacks.
    for var in &["TERM_PROGRAM", "TERMINAL"] {
        if let Ok(v) = std::env::var(var) {
            if !v.is_empty() {
                return v;
            }
        }
    }
    // Binary availability check
    for candidate in &["ghostty", "kitty", "alacritty", "wezterm", "xterm"] {
        if which_exists(candidate) {
            return candidate.to_string();
        }
    }
    "xterm".to_string()
}

#[cfg(target_os = "linux")]
fn terminal_exec_args<'a>(term: &str, cmd: &'a str) -> Vec<&'a str> {
    // Different terminals use different flags to pass a command
    match term {
        "kitty" | "alacritty" | "ghostty" => vec!["-e", cmd],
        "wezterm"                          => vec!["start", "--", "sh", "-c", cmd],
        _                                  => vec!["-e", cmd],
    }
}

#[cfg(target_os = "linux")]
fn which_exists(bin: &str) -> bool {
    std::process::Command::new("which")
        .arg(bin)
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

/* ─── get_daemon_status ──────────────────────────────────
   Calls count() on every plugin in parallel — each impl
   reads its own live index (Tantivy num_docs / cache len /
   SQLite COUNT(*)).  Fast: no sync, no heavy I/O.
────────────────────────────────────────────────────────── */

#[tauri::command]
pub async fn get_daemon_status(
    state: State<'_, AppState>,
) -> Result<DaemonStatus, String> {
    let s = state.inner();

    let (plugin_counts, active_plugins) = {
        let registry = s.registry.read().await;
        let counts   = registry.count_all().await;
        let names    = registry.all().iter().map(|p| p.id().to_string()).collect();
        (counts, names)
    };

    let from_counts: u64 = plugin_counts.values().sum();
    // The background sync task may have counted more — never go backward
    let cached = s.indexed_count.load(Ordering::Relaxed);
    let indexed_items = from_counts.max(cached);
    s.indexed_count.store(indexed_items, Ordering::Relaxed);

    // Dir walk runs on blocking thread — won't stall the async executor
    let data_dir    = s.data_dir.clone();
    let storage_bytes = tokio::task::spawn_blocking(move || dir_size_bytes(&data_dir))
        .await
        .unwrap_or(0);

    Ok(DaemonStatus {
        recording: !s.memory_daemon.is_paused(),
        indexed_items,
        storage_bytes,
        plugin_counts,
        active_plugins,
        last_sync: chrono::Utc::now().to_rfc3339(),
    })
}

/* ─── Memory: search + timeline (Rewind) ────────────────── */

#[tauri::command]
pub async fn search_memory(
    query: String,
    state: State<'_, AppState>,
) -> Result<Vec<crate::daemon::FrameHit>, String> {
    let sg = state.inner().session_graph.clone();
    tokio::task::spawn_blocking(move || sg.search_frames(&query, 30))
        .await.map_err(|e| e.to_string())?.map_err(|e| e.to_string())
}

/// Frames from the last `hours` hours, newest first — powers the Rewind view.
#[tauri::command]
pub async fn memory_timeline(
    hours: Option<i64>,
    state: State<'_, AppState>,
) -> Result<Vec<crate::daemon::FrameHit>, String> {
    let sg = state.inner().session_graph.clone();
    let now = chrono::Utc::now().timestamp();
    let start = now - hours.unwrap_or(6) * 3600;
    tokio::task::spawn_blocking(move || sg.frames_in_range(start, now, 60))
        .await.map_err(|e| e.to_string())?.map_err(|e| e.to_string())
}

/* ─── toggle_recording ────────────────────────────────── */

#[tauri::command]
pub async fn toggle_recording(
    state: State<'_, AppState>,
) -> Result<bool, String> {
    let daemon = &state.inner().memory_daemon;
    if daemon.is_paused() {
        daemon.resume();
        Ok(true)
    } else {
        daemon.pause();
        Ok(false)
    }
}

/* ─── sync_plugins ────────────────────────────────────── */

#[tauri::command]
pub async fn sync_plugins(
    state: State<'_, AppState>,
) -> Result<HashMap<String, usize>, String> {
    let s = state.inner();
    let counts = {
        let registry = s.registry.read().await;
        registry.sync_all().await
    };
    let total: u64 = counts.values().map(|&n| n as u64).sum();
    s.indexed_count.store(total, Ordering::Relaxed);
    Ok(counts)
}

/* ─── Private helpers ────────────────────────────────────
   These run on every search request — keep them fast.
────────────────────────────────────────────────────────── */

/// Split query into lowercase search terms, drop stop-words under 2 chars.
fn tokenize(q: &str) -> Vec<String> {
    q.split_whitespace()
        .filter(|t| t.len() > 1)
        .map(|t| t.to_lowercase())
        .collect()
}

/// Heuristic intent detection — upgraded to Phi-3 in Phase 3.
/// "run redis", "restart api" → Execution.
/// Everything else → Retrieval.
fn detect_intent(q: &str) -> QueryIntent {
    const EXEC_PREFIXES: &[&str] = &[
        "run ",
        "restart ",
        "kill ",
        "start ",
        "stop ",
        "deploy ",
        "open all ",
        "exec ",
        "launch ",
    ];
    let lower = q.trim().to_lowercase();
    if EXEC_PREFIXES.iter().any(|p| lower.starts_with(p)) {
        QueryIntent::Execution
    } else {
        QueryIntent::Retrieval
    }
}
