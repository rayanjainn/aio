//! Coding-assistant usage from local session logs — nothing leaves the Mac.
//!
//! * Claude Code: `~/.claude/projects/**/*.jsonl`, assistant messages carry
//!   `message.usage` (input/output/cache tokens) and `message.model`.
//! * Codex CLI: `~/.codex/sessions/**/*.jsonl`, `event_msg` payloads of type
//!   `token_count` carry `info.last_token_usage`.
//!
//! Files are read incrementally (byte offset per file), so polling every few
//! seconds only parses newly appended lines.

use serde::Serialize;
use std::{collections::{HashMap, HashSet}, path::{Path, PathBuf}, sync::{Mutex, OnceLock}};

#[derive(Debug, Clone, Copy)]
pub struct Entry { pub ts: i64, pub tokens: u64 }

#[derive(Default)]
struct FileState { offset: u64, entries: Vec<Entry>, seen: HashSet<String>, model: String, project: String, last_ts: i64 }

#[derive(Debug, Clone, Serialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct ToolUsage {
    pub installed: bool,
    pub today_tokens: u64,
    pub today_messages: u64,
    /// Tokens per day, oldest first, the last entry is today (7 days).
    pub week: Vec<u64>,
    /// Current 5-hour usage block (how Claude plans meter usage).
    pub block_tokens: u64,
    pub block_ends_at: Option<i64>,
    pub last_active: Option<i64>,
    /// Activity in the last 2 minutes — "working right now".
    pub active: bool,
    pub model: String,
    pub project: String,
}

#[derive(Debug, Clone, Serialize, Default)]
pub struct CodingUsage { pub claude: ToolUsage, pub codex: ToolUsage }

fn cache() -> &'static Mutex<HashMap<PathBuf, FileState>> {
    static C: OnceLock<Mutex<HashMap<PathBuf, FileState>>> = OnceLock::new();
    C.get_or_init(Default::default)
}

fn ts_of(v: &serde_json::Value) -> Option<i64> {
    v["timestamp"].as_str()
        .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
        .map(|d| d.timestamp())
}

/// One Claude Code log line → (dedupe key, entry, model, cwd).
pub fn parse_claude_line(line: &str) -> Option<(String, Entry, String, String)> {
    if !line.contains("\"usage\"") { return None; }
    let v: serde_json::Value = serde_json::from_str(line).ok()?;
    let msg = &v["message"];
    let u = &msg["usage"];
    if !u.is_object() { return None; }
    let n = |k: &str| u[k].as_u64().unwrap_or(0);
    let tokens = n("input_tokens") + n("output_tokens") + n("cache_creation_input_tokens") + n("cache_read_input_tokens");
    // Streaming writes the same message more than once; count it once.
    let key = format!("{}:{}", msg["id"].as_str().unwrap_or(""), v["requestId"].as_str().unwrap_or(""));
    Some((key, Entry { ts: ts_of(&v)?, tokens }, msg["model"].as_str().unwrap_or("").to_string(), v["cwd"].as_str().unwrap_or("").to_string()))
}

/// One Codex log line → entry (token_count events only).
pub fn parse_codex_line(line: &str) -> Option<(Entry, String)> {
    if !line.contains("token_count") && !line.contains("\"model\"") { return None; }
    let v: serde_json::Value = serde_json::from_str(line).ok()?;
    let p = &v["payload"];
    if p["type"] == "token_count" {
        let last = &p["info"]["last_token_usage"];
        let tokens = last["total_tokens"].as_u64()
            .unwrap_or_else(|| last["input_tokens"].as_u64().unwrap_or(0) + last["output_tokens"].as_u64().unwrap_or(0));
        return Some((Entry { ts: ts_of(&v)?, tokens }, String::new()));
    }
    // turn_context lines name the model
    p["model"].as_str().map(|m| (Entry { ts: ts_of(&v).unwrap_or(0), tokens: 0 }, m.to_string()))
}

fn jsonl_files(root: &Path, max_age_days: i64) -> Vec<PathBuf> {
    let cutoff = std::time::SystemTime::now() - std::time::Duration::from_secs(max_age_days as u64 * 86_400);
    walkdir::WalkDir::new(root).max_depth(5).into_iter().flatten()
        .filter(|e| e.file_type().is_file() && e.path().extension().is_some_and(|x| x == "jsonl"))
        .filter(|e| e.metadata().ok().and_then(|m| m.modified().ok()).is_some_and(|t| t >= cutoff))
        .map(|e| e.into_path())
        .collect()
}

fn refresh(path: &Path, codex: bool, st: &mut FileState) {
    use std::io::{BufRead, Seek, SeekFrom};
    let Ok(meta) = std::fs::metadata(path) else { return };
    if meta.len() < st.offset { *st = FileState::default(); } // truncated / rotated
    if meta.len() == st.offset { return; }
    let Ok(mut f) = std::fs::File::open(path) else { return };
    if f.seek(SeekFrom::Start(st.offset)).is_err() { return; }
    let mut reader = std::io::BufReader::new(f);
    let mut line = String::new();
    let mut consumed = st.offset;
    loop {
        line.clear();
        let Ok(n) = reader.read_line(&mut line) else { break };
        if n == 0 || !line.ends_with('\n') { break; } // keep a partial last line for next time
        consumed += n as u64;
        if codex {
            if let Some((e, model)) = parse_codex_line(&line) {
                if !model.is_empty() { st.model = model; }
                if e.tokens > 0 { st.last_ts = st.last_ts.max(e.ts); st.entries.push(e); }
            }
        } else if let Some((key, e, model, cwd)) = parse_claude_line(&line) {
            if !st.seen.insert(key) { continue; }
            if !model.is_empty() && !model.starts_with('<') { st.model = model; }
            if !cwd.is_empty() { st.project = Path::new(&cwd).file_name().map(|s| s.to_string_lossy().to_string()).unwrap_or_default(); }
            st.last_ts = st.last_ts.max(e.ts);
            st.entries.push(e);
        }
    }
    st.offset = consumed;
    // Keep 8 days of entries in memory.
    let cutoff = chrono::Utc::now().timestamp() - 8 * 86_400;
    st.entries.retain(|e| e.ts >= cutoff);
}

/// Summarise entries: today, 7-day series, and the current 5-hour block
/// (blocks start at the first activity, floored to the hour, after a gap).
pub fn summarize(entries: &mut Vec<Entry>, now: i64, tz_offset: i64) -> ToolUsage {
    entries.sort_by_key(|e| e.ts);
    let day = |ts: i64| (ts + tz_offset).div_euclid(86_400);
    let today = day(now);
    let mut week = vec![0u64; 7];
    let mut u = ToolUsage { installed: true, ..Default::default() };
    for e in entries.iter() {
        let d = today - day(e.ts);
        if (0..7).contains(&d) { week[6 - d as usize] += e.tokens; }
        if d == 0 { u.today_tokens += e.tokens; u.today_messages += 1; }
    }
    u.week = week;
    let mut block_start: Option<i64> = None;
    let mut prev = i64::MIN;
    for e in entries.iter() {
        let expired = block_start.is_some_and(|s| e.ts >= s + 5 * 3600);
        if block_start.is_none() || expired || e.ts - prev > 5 * 3600 {
            block_start = Some(e.ts - e.ts.rem_euclid(3600));
        }
        prev = e.ts;
    }
    if let Some(s) = block_start.filter(|s| now < s + 5 * 3600) {
        u.block_tokens = entries.iter().filter(|e| e.ts >= s).map(|e| e.tokens).sum();
        u.block_ends_at = Some(s + 5 * 3600);
    }
    u.last_active = entries.last().map(|e| e.ts);
    u.active = u.last_active.is_some_and(|t| now - t < 120);
    u
}

fn collect(root: Option<PathBuf>, codex: bool) -> ToolUsage {
    let Some(root) = root.filter(|r| r.exists()) else { return ToolUsage::default() };
    let files = jsonl_files(&root, 8);
    let Ok(mut c) = cache().lock() else { return ToolUsage::default() };
    let mut all = Vec::new();
    let (mut model, mut project, mut latest) = (String::new(), String::new(), 0i64);
    for f in files {
        let st = c.entry(f.clone()).or_default();
        refresh(&f, codex, st);
        all.extend(st.entries.iter().copied());
        if st.last_ts >= latest { latest = st.last_ts; model = st.model.clone(); project = st.project.clone(); }
    }
    let offset = chrono::Local::now().offset().local_minus_utc() as i64;
    let mut u = summarize(&mut all, chrono::Utc::now().timestamp(), offset);
    u.model = pretty_model(&model);
    u.project = project;
    u
}

/// "claude-sonnet-4-5-20250929" → "Sonnet 4.5"; others unchanged.
pub fn pretty_model(m: &str) -> String {
    let Some(rest) = m.strip_prefix("claude-") else { return m.to_string() };
    let parts: Vec<&str> = rest.split('-').filter(|p| !(p.len() == 8 && p.chars().all(|c| c.is_ascii_digit()))).collect();
    let (name, ver): (Vec<&str>, Vec<&str>) = parts.iter().partition(|p| p.chars().any(|c| c.is_ascii_alphabetic()));
    let name = name.first().map(|n| { let mut c = n.chars(); c.next().map(|f| f.to_uppercase().collect::<String>() + c.as_str()).unwrap_or_default() }).unwrap_or_default();
    if ver.is_empty() { name } else { format!("{name} {}", ver.join(".")) }
}

#[tauri::command]
pub async fn coding_usage() -> CodingUsage {
    tokio::task::spawn_blocking(|| {
        let home = dirs::home_dir();
        CodingUsage {
            claude: collect(home.as_ref().map(|h| h.join(".claude/projects")), false),
            codex: collect(home.as_ref().map(|h| h.join(".codex/sessions")), true),
        }
    }).await.unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn claude_line_parses_and_counts_all_token_kinds() {
        let l = r#"{"type":"assistant","timestamp":"2026-11-03T10:00:00Z","requestId":"r1","cwd":"/Users/me/code/aio","message":{"id":"m1","model":"claude-sonnet-4-5-20250929","usage":{"input_tokens":10,"output_tokens":20,"cache_creation_input_tokens":30,"cache_read_input_tokens":40}}}"#;
        let (key, e, model, cwd) = parse_claude_line(l).unwrap();
        assert_eq!(key, "m1:r1");
        assert_eq!(e.tokens, 100);
        assert_eq!(model, "claude-sonnet-4-5-20250929");
        assert_eq!(cwd, "/Users/me/code/aio");
        assert!(parse_claude_line(r#"{"type":"user","message":{"content":"hi"}}"#).is_none());
    }

    #[test]
    fn codex_line_parses() {
        let l = r#"{"timestamp":"2026-11-03T10:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":5,"output_tokens":7,"total_tokens":12}}}}"#;
        assert_eq!(parse_codex_line(l).unwrap().0.tokens, 12);
        let ctx = r#"{"timestamp":"2026-11-03T10:00:00Z","type":"turn_context","payload":{"model":"gpt-5-codex"}}"#;
        assert_eq!(parse_codex_line(ctx).unwrap().1, "gpt-5-codex");
    }

    #[test]
    fn summary_today_week_and_block() {
        let now = 1_000_000 * 86_400 + 12 * 3600; // noon UTC
        let mut es = vec![
            Entry { ts: now - 3 * 86_400, tokens: 5 },
            Entry { ts: now - 3600 * 2 - 600, tokens: 10 }, // 09:50 → block from 09:00
            Entry { ts: now - 60, tokens: 20 },
        ];
        let u = summarize(&mut es, now, 0);
        assert_eq!(u.today_tokens, 30);
        assert_eq!(u.today_messages, 2);
        assert_eq!(u.week, vec![0, 0, 0, 5, 0, 0, 30]);
        assert_eq!(u.block_tokens, 30);
        assert_eq!(u.block_ends_at, Some(now - 3 * 3600 + 5 * 3600));
        assert!(u.active);
    }

    #[test]
    fn old_block_expires() {
        let now = 1_000_000 * 86_400 + 20 * 3600;
        let mut es = vec![Entry { ts: now - 6 * 3600, tokens: 9 }];
        let u = summarize(&mut es, now, 0);
        assert_eq!(u.block_tokens, 0);
        assert!(!u.active);
    }

    #[test]
    fn incremental_reads_dedupe_and_handle_partial_lines() {
        let dir = std::env::temp_dir().join(format!("cortex-cc-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let f = dir.join("s.jsonl");
        let line = |id: &str| format!(r#"{{"timestamp":"2026-11-03T10:00:00Z","requestId":"r","message":{{"id":"{id}","model":"claude-opus-4-1","usage":{{"input_tokens":1,"output_tokens":1}}}}}}"#);
        std::fs::write(&f, format!("{}\n{}\n{}", line("a"), line("a"), &line("b")[..20])).unwrap();
        let mut st = FileState::default();
        refresh(&f, false, &mut st);
        assert_eq!(st.entries.len(), 1, "duplicate streamed message counted once, partial line deferred");
        std::fs::write(&f, format!("{}\n{}\n{}\n", line("a"), line("a"), line("b"))).unwrap();
        refresh(&f, false, &mut st);
        assert_eq!(st.entries.len(), 2);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn model_names() {
        assert_eq!(pretty_model("claude-sonnet-4-5-20250929"), "Sonnet 4.5");
        assert_eq!(pretty_model("claude-opus-4-1"), "Opus 4.1");
        assert_eq!(pretty_model("gpt-5-codex"), "gpt-5-codex");
    }
}
