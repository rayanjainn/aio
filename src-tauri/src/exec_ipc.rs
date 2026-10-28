// exec_ipc.rs
// Tauri commands for execution mode.
//
// Wire into lib.rs invoke_handler:
//   .invoke_handler(tauri::generate_handler![
//       ..existing handlers..,
//       exec_ipc::plan_execution,
//       exec_ipc::run_execution,
//   ])

use crate::{
    executor::{ExecOutput, Executor, ExecutorPlan, ExecutorRequest},
    plugin::{QueryIntent, SearchQuery},
    AppState,
};
use std::time::Duration;
use tauri::{ipc::Channel, State};

const STOPWORDS: &[&str] = &["what","whats","what's","was","were","are","is","my","the","a","an","do","did","i","have","of","in","on","at","me","show","list","find","tell","about","you","your","cortex","can","please","all","back","ago","hour","hours","open","tab","tabs","recently","recent"];

/// Human relative time, e.g. "2h ago", "yesterday".
fn rel_time(ts: chrono::DateTime<chrono::Utc>) -> String {
    let secs = (chrono::Utc::now() - ts).num_seconds().max(0);
    if secs < 90 { "just now".into() }
    else if secs < 5400 { format!("{}m ago", secs / 60) }
    else if secs < 172_800 { format!("{}h ago", secs / 3600) }
    else { format!("{}d ago", secs / 86_400) }
}

/// A grounding source the AI used — surfaced in the UI as a clickable chip.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatSource {
    pub id: String, pub plugin_id: String, pub title: String, pub subtitle: String,
}

/// RAG retrieval — search the user's sources for `prompt`. Returns a formatted
/// context block (with relative timestamps) AND the source list. Caches the
/// results so the UI can execute/open them by id.
async fn retrieve_context(s: &AppState, prompt: &str) -> (String, Vec<ChatSource>) {
    let mut terms: Vec<String> = prompt.split_whitespace()
        .map(|w| w.trim_matches(|c: char| !c.is_alphanumeric()).to_lowercase())
        .filter(|w| w.len() > 1 && !STOPWORDS.contains(&w.as_str()))
        .collect();
    terms.dedup();
    if terms.is_empty() { terms = prompt.split_whitespace().map(|w| w.to_lowercase()).collect(); }
    terms.truncate(4); // cap search rounds — keeps retrieval fast

    // Live browser tabs as FIRST-CLASS results: when the question is about tabs,
    // each open tab becomes a high-score, clickable (opens the URL) result — not
    // just context text. This makes the source chips the actual tabs.
    let pl = prompt.to_lowercase();
    let mut tab_results: Vec<crate::plugin::SearchResult> = Vec::new();
    if pl.contains("tab") {
        let tabs = tokio::task::spawn_blocking(crate::config_ipc::read_open_tabs).await.unwrap_or_default();
        for t in tabs.into_iter().take(30) {
            let mut r = crate::plugin::SearchResult::new("browser", &t.title);
            r.id = format!("tab:{}", t.url);
            r.source_type = crate::plugin::SourceType::Url;
            r.subtitle = Some(t.url.clone());
            r.url = Some(t.url);
            r.score = 1.0;
            r.action = crate::plugin::ResultAction::Open;
            tab_results.push(r);
        }
    }

    // Search EACH keyword separately and merge — fuzzy/keyword matchers fail on
    // a full sentence ("what did i surf on youtube…"), so per-term recall is far
    // better. Keep the best score seen per result id.
    let mut best: std::collections::HashMap<String, crate::plugin::SearchResult> = std::collections::HashMap::new();
    {
        let reg = s.registry.read().await;
        // whole phrase first (helps exact/semantic), then each keyword
        let mut queries: Vec<String> = vec![terms.join(" ")];
        queries.extend(terms.iter().cloned());
        for raw in queries {
            if raw.trim().is_empty() { continue; }
            let q = SearchQuery {
                raw:           raw.clone(),
                terms:         raw.split_whitespace().map(|w| w.to_string()).collect(),
                temporal:      None, source_filter: None, intent: QueryIntent::Retrieval,
            };
            for r in reg.search_all(&q).await {
                best.entry(r.id.clone())
                    .and_modify(|e| if r.score > e.score { *e = r.clone() })
                    .or_insert(r);
            }
        }
    }
    let mut all: Vec<crate::plugin::SearchResult> = best.into_values().collect();
    // Recency boost ONLY for temporal/activity questions ("what was I doing
    // recently"). For topical questions ("which repo did I commit to") it would
    // wrongly lift recently-visited pages into the sources, so skip it.
    let temporal = ["recent", "recently", "ago", "today", "yesterday", "earlier",
        "tonight", "morning", "afternoon", "evening", "minute", "hour", "watching",
        "watched", "doing", "lately", "just now"].iter().any(|w| pl.contains(w));
    if temporal {
        let now = chrono::Utc::now();
        for r in &mut all {
            if let Some(ts) = r.timestamp {
                let age_h = (now - ts).num_hours();
                if age_h <= 24 { r.score += 0.35; } else if age_h <= 24 * 7 { r.score += 0.12; }
            }
        }
    }
    all.sort_by(|a, b| b.score.partial_cmp(&a.score).unwrap_or(std::cmp::Ordering::Equal));
    // Per-source cap so one chatty source (e.g. files) can't crowd out browser
    // history, github, clipboard, etc. Keep up to 5 of each.
    let mut per: std::collections::HashMap<String, usize> = std::collections::HashMap::new();
    let mut capped: Vec<crate::plugin::SearchResult> = Vec::new();
    for r in all {
        let c = per.entry(r.plugin_id.clone()).or_insert(0);
        if *c < 5 { *c += 1; capped.push(r); }
    }
    capped.truncate(24);

    // Open tabs come FIRST and are exempt from the per-source cap (so all of
    // them show, not just 5), then the capped RAG results.
    let mut results: Vec<crate::plugin::SearchResult> = tab_results;
    results.extend(capped);

    // Cache so the UI can open/run a cited source by id.
    { let mut cache = s.result_cache.write().await; for r in &results { cache.insert(r.id.clone(), r.clone()); } }

    // ── Episodic memory: search captured screen frames per keyword (union) ──
    let mut memory_lines = String::new();
    let sg = s.session_graph.clone();
    let mem_terms = terms.clone();
    let frames = tokio::task::spawn_blocking(move || {
        let mut seen = std::collections::HashSet::new();
        let mut out: Vec<crate::daemon::FrameHit> = Vec::new();
        for t in &mem_terms {
            if let Ok(hits) = sg.search_frames(t, 5) {
                for h in hits { if seen.insert(h.timestamp) { out.push(h); } }
            }
        }
        out.sort_by(|a, b| b.timestamp.cmp(&a.timestamp));
        out.truncate(8);
        out
    }).await.unwrap_or_default();
    for f in &frames {
        let when = chrono::DateTime::from_timestamp(f.timestamp, 0).map(|dt| rel_time(dt.with_timezone(&chrono::Utc))).unwrap_or_default();
        let loc = f.url.clone().unwrap_or_else(|| f.window_title.clone());
        memory_lines.push_str(&format!("\n- [screen] {} · {} ({})\n    {}", f.app_name, loc, when, f.snippet.chars().take(160).collect::<String>()));
    }

    let ctx = results.iter().enumerate().map(|(i, r)| {
        let loc   = r.url.clone().or_else(|| r.path.clone()).unwrap_or_default();
        let extra = r.subtitle.clone().unwrap_or_default();
        let when  = r.timestamp.map(rel_time).unwrap_or_default();
        let snip  = r.content.as_deref().unwrap_or("").chars().take(140).collect::<String>();
        format!("{}. [{}] {}{}{}{}{}",
            i + 1, r.plugin_id, r.title,
            if extra.is_empty() { String::new() } else { format!(" — {extra}") },
            if when.is_empty()  { String::new() } else { format!("  ({when})") },
            if loc.is_empty()   { String::new() } else { format!("  {loc}") },
            if snip.is_empty()  { String::new() } else { format!("\n    {snip}") })
    }).collect::<Vec<_>>().join("\n");

    // Screen memory leads — it's the most relevant for "what was I doing / watching"
    // questions; indexed files/apps follow. Open tabs prepended when relevant.
    let ctx = if memory_lines.is_empty() { ctx }
              else { format!("SCREEN MEMORY (what you actually viewed, newest first):{memory_lines}\n\nOTHER INDEXED DATA:\n{ctx}") };

    // GitHub activity stats for github/commit/stats questions.
    let ctx = if pl.contains("github") || pl.contains("commit") || pl.contains("stat") || pl.contains("week") || pl.contains("repo") {
        match tokio::task::spawn_blocking(crate::config_ipc::github_stats).await.ok().flatten() {
            Some(s) => format!("GITHUB STATS: {}\n\n{ctx}", s.summary),
            None => ctx,
        }
    } else { ctx };

    // Dedupe by BOTH title and url (so "100xdevs" ×5 with differing urls but the
    // same title collapse to one), and cap per source type so no type floods.
    let mut seen_title = std::collections::HashSet::new();
    let mut seen_url = std::collections::HashSet::new();
    let mut per_src: std::collections::HashMap<String, usize> = std::collections::HashMap::new();
    let sources: Vec<ChatSource> = results.iter()
        .filter(|r| {
            let t = r.title.to_lowercase();
            let u = r.url.clone().or_else(|| r.path.clone()).map(|s| s.to_lowercase());
            if !seen_title.insert(t) { return false; }
            if let Some(u) = u { if !seen_url.insert(u) { return false; } }
            let c = per_src.entry(r.plugin_id.clone()).or_insert(0);
            if *c >= 5 { return false; }
            *c += 1; true
        })
        .take(10)
        .map(|r| ChatSource {
            id: r.id.clone(), plugin_id: r.plugin_id.clone(), title: r.title.clone(),
            subtitle: r.subtitle.clone().or_else(|| r.url.clone()).or_else(|| r.path.clone()).unwrap_or_default(),
        }).collect();
    (ctx, sources)
}

fn ollama_client() -> Result<reqwest::Client, String> {
    reqwest::Client::builder().timeout(Duration::from_secs(90)).build().map_err(|e| e.to_string())
}

/// Ollama connection settings from ~/.cortex/config.toml `[ollama]`.
/// When `api_key` is present, chat runs on Ollama Cloud (host=https://ollama.com);
/// otherwise it falls back to a local daemon. Embeddings always stay local.
pub struct OllamaCfg { pub host: String, pub api_key: Option<String>, pub model: String }

pub fn ollama_cfg() -> OllamaCfg {
    fn field(raw: &str, key: &str) -> Option<String> {
        let section = raw.split("[ollama]").nth(1)?;
        let section = section.split("\n[").next().unwrap_or(section);
        regex::Regex::new(&format!(r#"(?m)^\s*{key}\s*=\s*"([^"]+)""#)).ok()?
            .captures(section).map(|c| c[1].to_string())
    }
    let raw = dirs::home_dir().map(|h| h.join(".cortex/config.toml"))
        .and_then(|p| std::fs::read_to_string(p).ok()).unwrap_or_default();
    let api_key = field(&raw, "api_key").filter(|s| !s.is_empty());
    let host = field(&raw, "host").filter(|s| !s.is_empty())
        .unwrap_or_else(|| "http://localhost:11434".into())
        .trim_end_matches('/').to_string();
    let model = field(&raw, "chat_model").filter(|s| !s.is_empty()).unwrap_or_default();
    OllamaCfg { host, api_key, model }
}

/// Resolve the chat model: configured `chat_model` wins; else probe a local
/// daemon for the best installed model. Cached after first call.
async fn best_chat_model() -> String {
    use std::sync::OnceLock;
    use tokio::sync::Mutex;
    static CACHE: OnceLock<Mutex<Option<String>>> = OnceLock::new();
    let cell = CACHE.get_or_init(|| Mutex::new(None));
    let mut guard = cell.lock().await;
    if let Some(m) = guard.as_ref() { return m.clone(); }

    let cfg = ollama_cfg();
    // Cloud / explicitly-configured model: use it, skip the probe.
    if !cfg.model.is_empty() {
        tracing::info!(target: "aio_cortex_lib", "AI chat model: {} ({})", cfg.model, if cfg.api_key.is_some() { "cloud" } else { "local" });
        *guard = Some(cfg.model.clone());
        return cfg.model;
    }

    const PREF: &[&str] = &["llama3.1:8b", "qwen2.5:7b", "qwen2.5:3b", "mistral:7b", "llama3.2:3b", "phi3:mini"];
    let installed: Vec<String> = match ollama_client() {
        Ok(c) => match c.get(format!("{}/api/tags", cfg.host)).send().await {
            Ok(r) => r.json::<serde_json::Value>().await.ok()
                .and_then(|v| v["models"].as_array().map(|a| a.iter().filter_map(|m| m["name"].as_str().map(|s| s.to_string())).collect()))
                .unwrap_or_default(),
            Err(_) => vec![],
        },
        Err(_) => vec![],
    };
    let chosen = PREF.iter()
        .find(|&&p| installed.iter().any(|m| m == p || m.starts_with(&format!("{p}"))))
        .map(|s| s.to_string())
        .unwrap_or_else(|| "phi3:mini".to_string());
    tracing::info!(target: "aio_cortex_lib", "AI chat model: {chosen} (local)");
    *guard = Some(chosen.clone());
    chosen
}

/* ─── Conversational chat (multi-turn, grounded, persisted) ─── */

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct ChatMsg {
    pub role: String,
    pub content: String,
    #[serde(default)]
    pub sources: Vec<ChatSource>,
}

#[derive(Debug, serde::Serialize)]
pub struct AiReply { pub answer: String, pub sources: Vec<ChatSource> }

#[derive(Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatSummary { pub id: String, pub title: String, pub updated: i64 }

fn chats_db() -> Result<rusqlite::Connection, String> {
    let path = dirs::home_dir().unwrap_or_default().join(".cortex/chats.db");
    let conn = rusqlite::Connection::open(path).map_err(|e| e.to_string())?;
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS chats (id TEXT PRIMARY KEY, title TEXT, updated INTEGER, messages_json TEXT);",
    ).map_err(|e| e.to_string())?;
    Ok(conn)
}

/// Multi-turn chat. `messages` is the full prior conversation (incl. the new
/// user turn). RAG-grounds the latest user message, replies with phi3 via
/// /api/chat, persists the thread under `thread_id`, returns the assistant text.
#[tauri::command]
pub async fn ask_ai_chat(
    thread_id: String,
    messages: Vec<ChatMsg>,
    on_chunk: Channel<String>,
    state: State<'_, AppState>,
) -> Result<AiReply, String> {
    let _ = &thread_id;
    let s = state.inner();
    let last_user = messages.iter().rev().find(|m| m.role == "user").map(|m| m.content.clone()).unwrap_or_default();
    let (context, sources) = retrieve_context(s, &last_user).await;
    tracing::info!(target: "aio_cortex_lib", "ask_ai_chat: '{last_user}' → {} sources, {} turns", sources.len(), messages.len());

    let now = chrono::Local::now().format("%A %Y-%m-%d %H:%M").to_string();
    let system = if context.is_empty() {
        format!("You are Cortex, the user's personal assistant with access to their indexed data (apps, files, browser history, git, github, clipboard, screen memory). Right now it is {now}. For this question nothing relevant was found — say so in one short sentence. Never claim you lack access in general.")
    } else {
        format!("You are Cortex, the user's personal assistant. Right now it is {now}.\n\
The app displays the relevant items (tabs, files, videos, etc.) as a clickable list directly below your reply — so you do NOT need to repeat URLs or dump the full list.\n\
Give a SHORT, natural answer (1-3 sentences). For \"what/list\" questions, state the count and summarize the gist (e.g. \"You have 11 tabs open — mostly Gmail, docs, and a YouTube video.\"). You may mention a few notable item TITLES, but never paste raw URLs and never repeat an item.\n\
Use ONLY the data below. Never narrate searching or say \"no matches\". Never claim you lack access.\n\n\
USER DATA:\n{context}")
    };

    // Ollama /api/chat: system + conversation turns.
    let mut chat_msgs = vec![serde_json::json!({ "role": "system", "content": system })];
    for m in &messages {
        let role = if m.role == "assistant" { "assistant" } else { "user" };
        chat_msgs.push(serde_json::json!({ "role": role, "content": m.content }));
    }
    let cfg = ollama_cfg();
    let model = best_chat_model().await;
    let chat_url = format!("{}/api/chat", cfg.host);
    // num_ctx must be large — default 2048 truncates our RAG context.
    // (Cloud ignores num_ctx/keep_alive; harmless to send.)
    let opts = serde_json::json!({ "temperature": 0.2, "num_predict": 900, "num_ctx": 8192 });

    // ── Attempt streaming (live tokens via "ai-chunk" events) ──
    let mut answer = String::new();
    let mut stream_err: Option<String> = None;
    let stream_req = {
        let mut r = ollama_client()?
            .post(&chat_url)
            .json(&serde_json::json!({ "model": model, "messages": chat_msgs, "stream": true, "keep_alive": "30m", "options": opts }));
        if let Some(k) = &cfg.api_key { r = r.bearer_auth(k); }
        r
    };
    match stream_req.send().await
    {
        Ok(mut resp) => {
            // `.chunk()` reads the body incrementally — reliable across reqwest
            // builds (no `stream` feature / StreamExt needed).
            let mut buf: Vec<u8> = Vec::new();
            loop {
                match resp.chunk().await {
                    Ok(Some(bytes)) => {
                        buf.extend_from_slice(&bytes);
                        while let Some(nl) = buf.iter().position(|&b| b == b'\n') {
                            let line: Vec<u8> = buf.drain(..=nl).collect();
                            if let Ok(v) = serde_json::from_slice::<serde_json::Value>(&line) {
                                if let Some(e) = v["error"].as_str() { stream_err = Some(e.to_string()); }
                                if let Some(c) = v["message"]["content"].as_str() {
                                    if !c.is_empty() {
                                        answer.push_str(c);
                                        let _ = on_chunk.send(c.to_string());
                                    }
                                }
                            }
                        }
                    }
                    Ok(None) => break,
                    Err(e) => { stream_err = Some(e.to_string()); break; }
                }
            }
        }
        Err(e) => { stream_err = Some(format!("Ollama unreachable: {e}")); }
    }

    // ── Fallback: if streaming produced nothing, do a plain non-stream call ──
    if answer.trim().is_empty() {
        tracing::warn!(target: "aio_cortex_lib", "stream empty ({:?}) — falling back to non-stream", stream_err);
        let fb_req = {
            let mut r = ollama_client()?
                .post(&chat_url)
                .json(&serde_json::json!({ "model": model, "messages": chat_msgs, "stream": false, "keep_alive": "30m", "options": opts }));
            if let Some(k) = &cfg.api_key { r = r.bearer_auth(k); }
            r
        };
        let resp: serde_json::Value = fb_req
            .send().await.map_err(|e| format!("Ollama unreachable: {e}"))?
            .json().await.map_err(|e| e.to_string())?;
        if let Some(err) = resp["error"].as_str() { return Err(format!("AI error: {err}")); }
        answer = resp["message"]["content"].as_str().unwrap_or("").to_string();
        // Send the whole answer as one chunk so the UI shows it.
        if !answer.trim().is_empty() { let _ = on_chunk.send(answer.clone()); }
    }

    let answer = answer.trim().to_string();
    if answer.is_empty() {
        return Err(format!("AI error: {}", stream_err.unwrap_or_else(|| "no response".into())));
    }

    // Persist the thread (assistant message carries its sources).
    if !thread_id.is_empty() {
        let mut full = messages.clone();
        full.push(ChatMsg { role: "assistant".into(), content: answer.clone(), sources: sources.clone() });
        let title = full.iter().find(|m| m.role == "user").map(|m| m.content.chars().take(60).collect::<String>()).unwrap_or_else(|| "Chat".into());
        if let Ok(json) = serde_json::to_string(&full) {
            if let Ok(conn) = chats_db() {
                let _ = conn.execute(
                    "INSERT OR REPLACE INTO chats (id, title, updated, messages_json) VALUES (?1, ?2, ?3, ?4)",
                    rusqlite::params![thread_id, title, chrono::Utc::now().timestamp(), json],
                );
            }
        }
    }
    Ok(AiReply { answer, sources })
}

#[tauri::command]
pub async fn list_chats() -> Result<Vec<ChatSummary>, String> {
    tokio::task::spawn_blocking(|| {
        let conn = chats_db()?;
        let mut stmt = conn.prepare("SELECT id, title, updated FROM chats ORDER BY updated DESC LIMIT 50").map_err(|e| e.to_string())?;
        let rows = stmt.query_map([], |r| Ok(ChatSummary { id: r.get(0)?, title: r.get(1)?, updated: r.get(2)? }))
            .map_err(|e| e.to_string())?;
        Ok::<_, String>(rows.filter_map(|r| r.ok()).collect())
    }).await.map_err(|e| e.to_string())?
}

#[tauri::command]
pub async fn delete_chat(id: String) -> Result<(), String> {
    tokio::task::spawn_blocking(move || {
        let conn = chats_db()?;
        conn.execute("DELETE FROM chats WHERE id = ?1", rusqlite::params![id]).map_err(|e| e.to_string())?;
        Ok::<_, String>(())
    }).await.map_err(|e| e.to_string())?
}

#[tauri::command]
pub async fn clear_chats() -> Result<(), String> {
    tokio::task::spawn_blocking(|| {
        let conn = chats_db()?;
        conn.execute("DELETE FROM chats", []).map_err(|e| e.to_string())?;
        Ok::<_, String>(())
    }).await.map_err(|e| e.to_string())?
}

#[tauri::command]
pub async fn get_chat(id: String) -> Result<Vec<ChatMsg>, String> {
    tokio::task::spawn_blocking(move || {
        let conn = chats_db()?;
        let json: String = conn.query_row("SELECT messages_json FROM chats WHERE id = ?1", rusqlite::params![id], |r| r.get(0))
            .map_err(|e| e.to_string())?;
        serde_json::from_str(&json).map_err(|e| e.to_string())
    }).await.map_err(|e| e.to_string())?
}

/// Generate an execution plan (NL → shell command via phi3:mini).
/// Called when the user presses Enter on a query detected as execution-mode.
/// Returns ExecutorPlan { command, explanation, is_destructive }.
/// The frontend should show an ExecutionConfirm dialog before calling run_execution.
#[tauri::command]
pub async fn plan_execution(
    query: String,
    session_context: String,
    state: State<'_, AppState>,
) -> Result<ExecutorPlan, String> {
    let _ = state; // AppState available for future context injection (Phase 3)
    let executor = Executor::new();
    let plan = executor
        .plan(&ExecutorRequest { query, session_context })
        .await;
    Ok(plan)
}

/// Execute a confirmed shell command and return all output lines.
/// Each ExecOutput has { line, is_stderr, exit_code? }.
/// The final entry in the Vec carries the process exit_code.
///
/// For real-time streaming, replace the Vec return with
/// window.emit("exec-output", &line) inside executor.run_command().
#[tauri::command]
pub async fn run_execution(
    command: String,
    _state: State<'_, AppState>,
) -> Result<Vec<ExecOutput>, String> {
    let executor = Executor::new();
    executor
        .run_command(&command)
        .await
        .map_err(|e| e.to_string())
}
