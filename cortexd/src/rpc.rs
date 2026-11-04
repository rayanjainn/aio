//! JSON-RPC over a unix socket (`~/.cortex/cortexd.sock`), one JSON object per line.
//!
//!   → {"id": 7, "method": "search", "params": {"query": "foo"}}
//!   ← {"id": 7, "result": {...}}      or      {"id": 7, "error": "..."}
//!
//! Requests on one connection run concurrently (a fast keystroke never waits for a
//! slow search); the client matches replies by `id`.

use crate::{
    config_ipc::{self, AppConfig},
    engine::Engine,
    exec,
    plugin::{QueryIntent, SearchQuery, SearchResult, TemporalFilter},
    ranker::Ranker,
    temporal::parse_time_expression,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{collections::HashMap, path::PathBuf, sync::{atomic::Ordering, Arc}};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    net::{UnixListener, UnixStream},
    sync::Mutex,
};

#[derive(Debug, Deserialize)]
struct Request {
    id:     Value,
    method: String,
    #[serde(default)]
    params: Value,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SearchRequest {
    query:         String,
    source_filter: Option<Vec<String>>,
    limit:         Option<usize>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct SearchResponse {
    results:           Vec<SearchResult>,
    sessions:          Vec<crate::daemon::SessionRecord>,
    total_ms:          u64,
    source_counts:     HashMap<String, usize>,
    mode:              String,
    execution_preview: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct DaemonStatus {
    recording:      bool,
    indexed_items:  u64,
    storage_bytes:  u64,
    plugin_counts:  HashMap<String, u64>,
    active_plugins: Vec<String>,
}

pub fn socket_path() -> PathBuf {
    dirs::home_dir().unwrap_or_default().join(".cortex/cortexd.sock")
}

pub async fn serve(engine: Arc<Engine>) -> anyhow::Result<()> {
    let path = socket_path();
    if let Some(dir) = path.parent() { std::fs::create_dir_all(dir)?; }
    let _ = std::fs::remove_file(&path); // stale socket from a previous run
    let listener = UnixListener::bind(&path)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));
    }
    tracing::info!("cortexd listening on {}", path.display());
    loop {
        match listener.accept().await {
            Ok((stream, _)) => { tokio::spawn(handle(stream, engine.clone())); }
            Err(e) => tracing::warn!("accept: {e}"),
        }
    }
}

async fn handle(stream: UnixStream, engine: Arc<Engine>) {
    let (read, write) = stream.into_split();
    let write = Arc::new(Mutex::new(write));
    let mut lines = BufReader::new(read).lines();
    while let Ok(Some(line)) = lines.next_line().await {
        if line.trim().is_empty() { continue; }
        let engine = engine.clone();
        let write = write.clone();
        tokio::spawn(async move {
            let reply = match serde_json::from_str::<Request>(&line) {
                Ok(req) => {
                    let id = req.id.clone();
                    match dispatch(&engine, &req.method, req.params).await {
                        Ok(v)  => json!({ "id": id, "result": v }),
                        Err(e) => { tracing::warn!("rpc {} failed: {e}", req.method); json!({ "id": id, "error": e }) }
                    }
                }
                Err(e) => json!({ "id": Value::Null, "error": format!("bad request: {e}") }),
            };
            let mut text = reply.to_string();
            text.push('\n');
            let _ = write.lock().await.write_all(text.as_bytes()).await;
        });
    }
}

fn parse<T: for<'de> Deserialize<'de>>(params: Value) -> Result<T, String> {
    serde_json::from_value(params).map_err(|e| format!("bad params: {e}"))
}

fn ok<T: Serialize>(v: T) -> Result<Value, String> {
    serde_json::to_value(v).map_err(|e| e.to_string())
}

async fn dispatch(s: &Arc<Engine>, method: &str, params: Value) -> Result<Value, String> {
    match method {
        "ping" => Ok(json!({ "version": env!("CARGO_PKG_VERSION"), "uptimeMs": s.started.elapsed().as_millis() as u64 })),
        "search" => ok(search(s, parse(params)?).await?),
        "suggestions" => ok(suggestions(s).await?),
        "status" => ok(status(s).await),
        "execute" => {
            #[derive(Deserialize)] struct P { id: String }
            execute(s, parse::<P>(params)?.id).await?;
            Ok(Value::Null)
        }
        "search_memory" => {
            #[derive(Deserialize)] struct P { query: String }
            let sg = s.session_graph.clone();
            let q = parse::<P>(params)?.query;
            let hits = tokio::task::spawn_blocking(move || sg.search_frames(&q, 30))
                .await.map_err(|e| e.to_string())?.map_err(|e| e.to_string())?;
            ok(hits)
        }
        "memory_timeline" => {
            #[derive(Deserialize)] struct P { hours: Option<i64> }
            let sg = s.session_graph.clone();
            let now = chrono::Utc::now().timestamp();
            let start = now - parse::<P>(params)?.hours.unwrap_or(6) * 3600;
            let hits = tokio::task::spawn_blocking(move || sg.frames_in_range(start, now, 60))
                .await.map_err(|e| e.to_string())?.map_err(|e| e.to_string())?;
            ok(hits)
        }
        "sync" => {
            let counts = s.registry.read().await.sync_all().await;
            s.indexed_count.store(counts.values().map(|&n| n as u64).sum(), Ordering::Relaxed);
            ok(counts)
        }
        "config_get" => ok(config_ipc::load_config()),
        "config_set" => {
            let cfg: AppConfig = parse(params)?;
            config_ipc::save_config(&cfg).map_err(|e| e.to_string())?;
            s.memory_daemon.set_blocked_apps(cfg.blocked_apps.clone());
            Ok(Value::Null)
        }
        "recording_get" => ok(!s.memory_daemon.is_paused()),
        "recording_toggle" => {
            let d = &s.memory_daemon;
            let recording = if d.is_paused() { d.resume(); true } else { d.pause(); false };
            tracing::info!("capture {}", if recording { "resumed" } else { "PAUSED" });
            ok(recording)
        }
        other => Err(format!("unknown method {other}")),
    }
}

/* ─── search ─────────────────────────────────────────────── */

fn tokenize(q: &str) -> Vec<String> {
    q.split_whitespace().filter(|t| t.len() > 1).map(|t| t.to_lowercase()).collect()
}

fn detect_intent(q: &str) -> QueryIntent {
    const EXEC_PREFIXES: &[&str] = &["run ", "restart ", "kill ", "start ", "stop ", "deploy ", "open all ", "exec ", "launch "];
    let lower = q.trim().to_lowercase();
    if EXEC_PREFIXES.iter().any(|p| lower.starts_with(p)) { QueryIntent::Execution } else { QueryIntent::Retrieval }
}

static VECTOR_MISS_AT: std::sync::atomic::AtomicI64 = std::sync::atomic::AtomicI64::new(0);
fn note_vector_miss() { VECTOR_MISS_AT.store(chrono::Utc::now().timestamp(), Ordering::Relaxed); }
fn vector_backoff_ok() -> bool { chrono::Utc::now().timestamp() - VECTOR_MISS_AT.load(Ordering::Relaxed) > 60 }

async fn search(s: &Arc<Engine>, req: SearchRequest) -> Result<SearchResponse, String> {
    let t0 = std::time::Instant::now();
    let intent = detect_intent(&req.query);
    let temporal = parse_time_expression(&req.query).map(|tr| TemporalFilter {
        after:  chrono::DateTime::from_timestamp(tr.start_unix, 0).map(|dt| dt.with_timezone(&chrono::Utc)),
        before: chrono::DateTime::from_timestamp(tr.end_unix, 0).map(|dt| dt.with_timezone(&chrono::Utc)),
        label:  tr.label,
    });
    let query = SearchQuery {
        raw: req.query.clone(),
        terms: tokenize(&req.query),
        temporal: temporal.clone(),
        source_filter: req.source_filter.clone(),
        intent: intent.clone(),
    };

    let vector = async {
        if !vector_backoff_ok() || req.query.trim().chars().count() < 3 { return HashMap::new(); }
        match tokio::time::timeout(std::time::Duration::from_millis(150), s.vector_store.search("cortex_index", &req.query, 50)).await {
            Ok(hits) => { if hits.is_empty() { note_vector_miss(); } hits.into_iter().collect::<HashMap<String, f32>>() }
            Err(_) => { note_vector_miss(); HashMap::new() }
        }
    };
    let fanout = async { s.registry.read().await.search_all(&query).await };
    let (mut results, cosine_scores) = tokio::join!(fanout, vector);

    if let Some(ref tf) = temporal {
        results.retain(|r| {
            let Some(ts) = r.timestamp else { return true };
            tf.after.map_or(true, |a| ts >= a) && tf.before.map_or(true, |b| ts <= b)
        });
    }
    {
        let mut ranker = s.ranker.write().await;
        ranker.inject_cosine_scores(cosine_scores);
        ranker.rank_top(&mut results, 50);
    }
    {
        let mut cache = s.result_cache.write().await;
        if cache.len() > 500 { cache.clear(); }
        for r in &results { cache.insert(r.id.clone(), r.clone()); }
    }
    results.truncate(req.limit.unwrap_or(50).min(50));

    let mut source_counts: HashMap<String, usize> = HashMap::new();
    for r in &results { *source_counts.entry(r.plugin_id.clone()).or_insert(0) += 1; }
    let sessions = s.session_graph.recent_sessions(3).unwrap_or_default();
    let ms = t0.elapsed().as_millis() as u64;
    tracing::info!("search {:?}: {} results in {ms}ms", req.query, results.len());

    Ok(SearchResponse {
        results, sessions, total_ms: ms, source_counts,
        mode: match intent { QueryIntent::Execution => "execution".into(), QueryIntent::Retrieval => "retrieval".into() },
        execution_preview: None,
    })
}

async fn suggestions(s: &Arc<Engine>) -> Result<SearchResponse, String> {
    let t0 = std::time::Instant::now();
    let empty = SearchQuery { raw: String::new(), terms: vec![], temporal: None, source_filter: None, intent: QueryIntent::Retrieval };
    let mut results = s.registry.read().await.search_all(&empty).await;
    results.sort_unstable_by(|a, b| b.score.partial_cmp(&a.score).unwrap_or(std::cmp::Ordering::Equal));
    results.truncate(12);
    {
        let mut cache = s.result_cache.write().await;
        for r in &results { cache.insert(r.id.clone(), r.clone()); }
    }
    let mut source_counts: HashMap<String, usize> = HashMap::new();
    for r in &results { *source_counts.entry(r.plugin_id.clone()).or_insert(0) += 1; }
    Ok(SearchResponse { results, sessions: vec![], total_ms: t0.elapsed().as_millis() as u64, source_counts, mode: "retrieval".into(), execution_preview: None })
}

/* ─── execute ────────────────────────────────────────────── */

async fn execute(s: &Arc<Engine>, id: String) -> Result<(), String> {
    let result = s.result_cache.read().await.get(&id).cloned()
        .ok_or_else(|| format!("result {id} not in cache — search again first"))?;
    tracing::info!("execute: {} '{}'", result.plugin_id, result.title);

    if result.plugin_id == "commands" {
        let reg = s.registry.read().await;
        if let Some(p) = reg.get("commands") {
            p.execute(&result).await.map_err(|e| e.to_string())?;
        }
    } else {
        exec::execute_by_type(&result).map_err(|e| e.to_string())?;
    }
    s.ranker.write().await.record_open(&id);
    let db_path = s.data_dir.join("interactions.db");
    tokio::task::spawn_blocking(move || Ranker::persist_open(&db_path, &id));
    Ok(())
}

/* ─── status ─────────────────────────────────────────────── */

async fn status(s: &Arc<Engine>) -> DaemonStatus {
    let (plugin_counts, active_plugins) = {
        let registry = s.registry.read().await;
        (registry.count_all().await, registry.all().iter().map(|p| p.id().to_string()).collect())
    };
    let from_counts: u64 = plugin_counts.values().sum();
    let indexed = from_counts.max(s.indexed_count.load(Ordering::Relaxed));
    s.indexed_count.store(indexed, Ordering::Relaxed);
    let dir = s.data_dir.clone();
    let storage_bytes = tokio::task::spawn_blocking(move || crate::dir_size_bytes(&dir)).await.unwrap_or(0);
    DaemonStatus { recording: !s.memory_daemon.is_paused(), indexed_items: indexed, storage_bytes, plugin_counts, active_plugins }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tokenize_and_intent() {
        assert_eq!(tokenize("a Big  Query x"), vec!["big", "query"]);
        assert!(matches!(detect_intent("run redis"), QueryIntent::Execution));
        assert!(matches!(detect_intent("runbook"), QueryIntent::Retrieval));
    }

    #[test]
    fn requests_parse() {
        let r: Request = serde_json::from_str(r#"{"id":3,"method":"search","params":{"query":"x","limit":5}}"#).unwrap();
        assert_eq!(r.method, "search");
        let p: SearchRequest = serde_json::from_value(r.params).unwrap();
        assert_eq!((p.query.as_str(), p.limit), ("x", Some(5)));
    }
}
