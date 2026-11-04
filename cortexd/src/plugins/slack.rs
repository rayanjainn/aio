/// Slack plugin — desktop LevelDB cache + API fallback.
///
/// Primary: read Slack's local IndexedDB LevelDB at
///   ~/Library/Application Support/Slack/IndexedDB/
/// Fallback: SLACK_BOT_TOKEN → conversations.history API
///
/// SQLite schema: ~/.cortex/slack/messages.db
/// Qdrant collection: cortex_slack

use anyhow::{Context, Result};
use async_trait::async_trait;
use chrono::Utc;
use fuzzy_matcher::{skim::SkimMatcherV2, FuzzyMatcher};
use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};
use std::{
    path::PathBuf,
    sync::RwLock,
    time::Duration,
};
use rusty_leveldb::LdbIterator;
use tokio::task::spawn_blocking;

use crate::{
    embed::VectorStore,
    plugin::{Plugin, ResultAction, SearchQuery, SearchResult, SourceType},
};

const SLACK_API: &str = "https://slack.com/api";

/* ─── Data types ────────────────────────────────────────── */

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SlackMessage {
    pub msg_id:    String,  // "{channel_id}:{ts}"
    pub channel:   String,
    pub channel_name: String,
    pub user:      String,
    pub text:      String,
    pub ts_unix:   i64,
    pub source:    String, // "leveldb" | "api"
}

/* ─── Plugin ────────────────────────────────────────────── */

pub struct SlackPlugin {
    db_path:   PathBuf,
    cache:     RwLock<Vec<SlackMessage>>,
    matcher:   SkimMatcherV2,
    bot_token: Option<String>,
    vs:        VectorStore,
    http:      reqwest::Client,
}

impl SlackPlugin {
    pub fn new(data_dir: PathBuf) -> Result<Self> {
        std::fs::create_dir_all(&data_dir)?;
        let db_path = data_dir.join("messages.db");
        Self::init_db(&db_path)?;
        // Load token from env or ~/.cortex/config.env
        let _ = load_cortex_env();
        Ok(Self {
            db_path,
            cache:     RwLock::new(vec![]),
            matcher:   SkimMatcherV2::default(),
            bot_token: std::env::var("SLACK_BOT_TOKEN").ok(),
            vs:        VectorStore::new(),
            http:      reqwest::Client::builder()
                .timeout(Duration::from_secs(30))
                .build()?,
        })
    }

    fn init_db(path: &PathBuf) -> Result<()> {
        let conn = Connection::open(path)?;
        conn.execute_batch("
            CREATE TABLE IF NOT EXISTS messages (
                msg_id       TEXT PRIMARY KEY,
                channel      TEXT NOT NULL,
                channel_name TEXT NOT NULL DEFAULT '',
                user_id      TEXT NOT NULL DEFAULT '',
                text         TEXT NOT NULL,
                ts_unix      INTEGER NOT NULL,
                source       TEXT NOT NULL DEFAULT 'api'
            );
            CREATE INDEX IF NOT EXISTS msgs_ts ON messages(ts_unix DESC);
            CREATE INDEX IF NOT EXISTS msgs_channel ON messages(channel);
        ")?;
        Ok(())
    }

    fn db(&self) -> Result<Connection> {
        Connection::open(&self.db_path).context("slack db open")
    }

    fn load_cache(&self) -> Result<()> {
        let conn = self.db()?;
        let mut stmt = conn.prepare(
            "SELECT msg_id, channel, channel_name, user_id, text, ts_unix, source \
             FROM messages ORDER BY ts_unix DESC LIMIT 5000"
        )?;
        let msgs: Vec<SlackMessage> = stmt.query_map([], |row| {
            Ok(SlackMessage {
                msg_id:       row.get(0)?,
                channel:      row.get(1)?,
                channel_name: row.get(2)?,
                user:         row.get(3)?,
                text:         row.get(4)?,
                ts_unix:      row.get(5)?,
                source:       row.get(6)?,
            })
        })?
        .filter_map(|r| r.ok())
        .collect();

        *self.cache.write().unwrap() = msgs;
        Ok(())
    }

    /* ── LevelDB path detection ────────────────────────────── */

    fn leveldb_path() -> Option<PathBuf> {
        let base = dirs::home_dir()?
            .join("Library/Application Support/Slack/IndexedDB");
        if !base.exists() { return None; }

        // Find the .leveldb directory inside (named something like
        // "https_app.slack.com_0.indexeddb.leveldb")
        std::fs::read_dir(&base).ok()?
            .filter_map(|e| e.ok())
            .find(|e| {
                let name = e.file_name();
                let s = name.to_string_lossy();
                s.contains("slack") && s.ends_with(".leveldb")
            })
            .map(|e| e.path())
    }

    /* ── LevelDB extraction ─────────────────────────────────── */

    async fn sync_leveldb(&self) -> Result<usize> {
        let ldb_path = match Self::leveldb_path() {
            Some(p) => p,
            None => {
                tracing::debug!("Slack LevelDB not found, skip");
                return Ok(0);
            }
        };

        let db_path = self.db_path.clone();
        let vs      = self.vs.clone();

        let count = spawn_blocking(move || -> Result<usize> {
            // Open LevelDB read-only by copying to a temp dir first
            // (Slack keeps an exclusive lock while running)
            let tmp = std::env::temp_dir().join("cortex_slack_ldb");
            if tmp.exists() { let _ = std::fs::remove_dir_all(&tmp); }
            copy_dir(&ldb_path, &tmp)?;

            let mut ldb = rusty_leveldb::DB::open(&tmp, rusty_leveldb::Options {
                create_if_missing: false,
                ..Default::default()
            }).context("leveldb open")?;

            let conn = Connection::open(&db_path)?;
            let cutoff = Utc::now().timestamp() - 180 * 86400;
            let mut new_count = 0usize;

            let mut iter = ldb.new_iter()?;
            iter.seek_to_first();

            let mut key_buf = Vec::new();
            let mut val_buf = Vec::new();
            while iter.valid() {
                key_buf.clear();
                val_buf.clear();
                if !iter.current(&mut key_buf, &mut val_buf) {
                    iter.advance();
                    continue;
                }
                let key = String::from_utf8_lossy(&key_buf).into_owned();
                let val = String::from_utf8_lossy(&val_buf).into_owned();

                // Slack stores messages under keys that contain channel IDs
                // Value is a JSON blob; try to parse it
                if let Some(msgs) = try_extract_messages(&key, &val, cutoff) {
                    for m in msgs {
                        let exists: bool = conn.query_row(
                            "SELECT 1 FROM messages WHERE msg_id = ?",
                            params![m.msg_id],
                            |_| Ok(true),
                        ).unwrap_or(false);
                        if exists { continue; }

                        conn.execute(
                            "INSERT OR IGNORE INTO messages \
                             (msg_id, channel, channel_name, user_id, text, ts_unix, source) \
                             VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'leveldb')",
                            params![m.msg_id, m.channel, m.channel_name, m.user, m.text, m.ts_unix],
                        )?;

                        let embed_text = format!("{} {}", m.channel_name, m.text);
                        let mid = m.msg_id.clone();
                        let vs2 = vs.clone();
                        let payload = serde_json::json!({ "id": mid, "source": "leveldb" });
                        tokio::spawn(async move {
                            vs2.index("cortex_slack", &mid, &embed_text, payload).await;
                        });
                        new_count += 1;
                    }
                }
                iter.advance();
            }

            let _ = std::fs::remove_dir_all(&tmp);
            tracing::info!("Slack LevelDB: indexed {new_count} messages");
            Ok(new_count)
        }).await??;

        Ok(count)
    }

    /* ── API fallback ───────────────────────────────────────── */

    async fn sync_api(&self) -> Result<usize> {
        let token = match &self.bot_token {
            Some(t) => t.clone(),
            None => {
                tracing::debug!("No SLACK_BOT_TOKEN, skip API sync");
                return Ok(0);
            }
        };

        // List public channels
        #[derive(Deserialize)]
        struct ChannelsResp { ok: bool, channels: Option<Vec<Channel>>, #[serde(rename="response_metadata")] meta: Option<RespMeta> }
        #[derive(Deserialize)]
        struct Channel { id: String, name: String }
        #[derive(Deserialize)]
        struct RespMeta { next_cursor: Option<String> }

        let mut channels: Vec<Channel> = vec![];
        let mut cursor: Option<String> = None;
        loop {
            let mut req = self.http
                .get(format!("{SLACK_API}/conversations.list"))
                .bearer_auth(&token)
                .query(&[("limit", "200"), ("types", "public_channel,private_channel")]);
            if let Some(c) = &cursor {
                req = req.query(&[("cursor", c.as_str())]);
            }
            let resp: ChannelsResp = req.send().await?.json().await?;
            if !resp.ok { break; }
            if let Some(ch) = resp.channels {
                channels.extend(ch);
            }
            cursor = resp.meta.and_then(|m| m.next_cursor).filter(|c| !c.is_empty());
            if cursor.is_none() { break; }
        }

        let cutoff = Utc::now().timestamp() - 180 * 86400;
        let cutoff_ts = format!("{}.000000", cutoff);
        let mut total_new = 0usize;

        for ch in &channels {
            #[derive(Deserialize)]
            struct HistoryResp { ok: bool, messages: Option<Vec<ApiMsg>>, has_more: Option<bool>, #[serde(rename="response_metadata")] meta: Option<RespMeta> }
            #[derive(Deserialize)]
            struct ApiMsg { ts: String, user: Option<String>, text: Option<String>, subtype: Option<String> }

            let mut page_cursor: Option<String> = None;
            'pages: loop {
                let mut req = self.http
                    .get(format!("{SLACK_API}/conversations.history"))
                    .bearer_auth(&token)
                    .query(&[
                        ("channel", ch.id.as_str()),
                        ("limit", "200"),
                        ("oldest", cutoff_ts.as_str()),
                    ]);
                if let Some(c) = &page_cursor {
                    req = req.query(&[("cursor", c.as_str())]);
                }
                let resp: HistoryResp = match req.send().await?.json().await {
                    Ok(r) => r,
                    Err(e) => { tracing::debug!("slack history {}: {e}", ch.id); break 'pages; }
                };
                if !resp.ok { break; }

                let msgs = resp.messages.unwrap_or_default();
                for m in &msgs {
                    // Skip bot messages and system messages
                    if m.subtype.is_some() { continue; }
                    let text = match &m.text { Some(t) if !t.is_empty() => t.clone(), _ => continue };

                    let ts_unix = m.ts.split('.').next()
                        .and_then(|s| s.parse::<i64>().ok())
                        .unwrap_or(0);
                    let msg_id = format!("{}:{}", ch.id, m.ts);

                    let conn = self.db()?;
                    let exists: bool = conn.query_row(
                        "SELECT 1 FROM messages WHERE msg_id = ?",
                        params![msg_id],
                        |_| Ok(true),
                    ).unwrap_or(false);
                    if exists { continue; }

                    let user = m.user.clone().unwrap_or_default();
                    conn.execute(
                        "INSERT OR IGNORE INTO messages \
                         (msg_id, channel, channel_name, user_id, text, ts_unix, source) \
                         VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'api')",
                        params![msg_id, ch.id, ch.name, user, text, ts_unix],
                    )?;

                    let embed_text = format!("#{} {text}", ch.name);
                    let mid = msg_id.clone();
                    let vs2 = self.vs.clone();
                    let payload = serde_json::json!({ "id": mid, "source": "api" });
                    tokio::spawn(async move {
                        vs2.index("cortex_slack", &mid, &embed_text, payload).await;
                    });
                    total_new += 1;
                }

                let has_more = resp.has_more.unwrap_or(false);
                page_cursor = resp.meta.and_then(|m| m.next_cursor).filter(|c| !c.is_empty());
                if !has_more || page_cursor.is_none() { break; }
            }
        }

        tracing::info!("Slack API: indexed {total_new} new messages");
        Ok(total_new)
    }

    fn count(&self) -> usize {
        self.cache.read().unwrap().len()
    }
}

/* ─── LevelDB helpers ───────────────────────────────────── */

/// Try to parse a LevelDB key/value pair as Slack messages.
/// Slack's IndexedDB schema stores JSON-encoded message arrays.
fn try_extract_messages(
    _key: &str,
    val: &str,
    cutoff: i64,
) -> Option<Vec<SlackMessage>> {
    // Values are JSON; try top-level array or object with 'messages' field
    let v: serde_json::Value = serde_json::from_str(val).ok()?;

    let arr = if v.is_array() {
        v.as_array()?.clone()
    } else if let Some(a) = v.get("messages").and_then(|x| x.as_array()) {
        a.clone()
    } else {
        return None;
    };

    let mut out = vec![];
    for item in &arr {
        let text = item.get("text")
            .or_else(|| item.get("body"))
            .and_then(|x| x.as_str())
            .unwrap_or_default();
        if text.is_empty() { continue; }

        let ts_str = item.get("ts")
            .or_else(|| item.get("timestamp"))
            .and_then(|x| x.as_str())
            .unwrap_or("");
        let ts_unix = ts_str.split('.').next()
            .and_then(|s| s.parse::<i64>().ok())
            .unwrap_or(0);
        if ts_unix < cutoff { continue; }

        let channel = item.get("channel")
            .and_then(|x| x.as_str())
            .unwrap_or("unknown")
            .to_string();
        let user = item.get("user")
            .or_else(|| item.get("user_id"))
            .and_then(|x| x.as_str())
            .unwrap_or("")
            .to_string();
        let msg_id = format!("{channel}:{ts_str}");

        out.push(SlackMessage {
            msg_id,
            channel:      channel.clone(),
            channel_name: channel.clone(),
            user,
            text: text.to_string(),
            ts_unix,
            source: "leveldb".into(),
        });
    }

    if out.is_empty() { None } else { Some(out) }
}

/// Recursively copy a directory (best-effort, skips locked files).
fn copy_dir(src: &PathBuf, dst: &PathBuf) -> Result<()> {
    std::fs::create_dir_all(dst)?;
    for entry in std::fs::read_dir(src)? {
        let entry = match entry { Ok(e) => e, Err(_) => continue };
        let ty = match entry.file_type() { Ok(t) => t, Err(_) => continue };
        let to = dst.join(entry.file_name());
        if ty.is_dir() {
            let _ = copy_dir(&entry.path(), &to);
        } else {
            let _ = std::fs::copy(entry.path(), to);
        }
    }
    Ok(())
}

fn load_cortex_env() {
    let path = dirs::home_dir()
        .unwrap_or_default()
        .join(".cortex/config.env");
    if !path.exists() { return; }
    if let Ok(content) = std::fs::read_to_string(&path) {
        for line in content.lines() {
            let line = line.trim();
            if line.starts_with('#') || line.is_empty() { continue; }
            if let Some((k, v)) = line.split_once('=') {
                std::env::set_var(k.trim(), v.trim().trim_matches('"'));
            }
        }
    }
}

/* ─── Plugin impl ───────────────────────────────────────── */

#[async_trait]
impl Plugin for SlackPlugin {
    fn id(&self)   -> &str { "slack" }
    fn name(&self) -> &str { "Slack" }
    fn icon(&self) -> &str { "💬" }

    async fn count(&self) -> u64 {
        let db = self.db_path.clone();
        tokio::task::spawn_blocking(move || {
            Connection::open(&db).ok()
                .and_then(|c| c.query_row("SELECT COUNT(*) FROM messages", [], |r| r.get::<_, i64>(0)).ok())
                .unwrap_or(0) as u64
        }).await.unwrap_or(0)
    }

    async fn sync(&self) -> Result<usize> {
        let ldb = self.sync_leveldb().await.unwrap_or_else(|e| {
            tracing::warn!("slack leveldb sync: {e}"); 0
        });
        // API fallback only if LevelDB empty
        let api = if ldb == 0 {
            self.sync_api().await.unwrap_or_else(|e| {
                tracing::warn!("slack api sync: {e}"); 0
            })
        } else { 0 };
        let _ = self.load_cache();
        Ok(ldb + api)
    }

    async fn search(&self, query: &SearchQuery) -> Result<Vec<SearchResult>> {
        let q = &query.raw;

        let semantic_ids: Vec<String> = self.vs
            .search("cortex_slack", q, 20)
            .await
            .into_iter()
            .map(|(id, _)| id)
            .collect();

        let cache = self.cache.read().unwrap();
        let mut results: Vec<SearchResult> = cache.iter()
            .filter_map(|m| {
                let haystack = format!("{} {} {}", m.channel_name, m.user, m.text);
                let fuzzy = self.matcher.fuzzy_match(&haystack, q)
                    .map(|s| s as f32 / 300.0)
                    .unwrap_or(0.0);
                let boost = if semantic_ids.contains(&m.msg_id) { 0.2 } else { 0.0 };
                let score = (fuzzy + boost).min(0.99);
                if score > 0.0 {
                    Some(to_search_result(m, score))
                } else {
                    None
                }
            })
            .collect();

        results.sort_by(|a, b| b.score.partial_cmp(&a.score).unwrap());
        results.truncate(30);
        Ok(results)
    }

    async fn execute(&self, result: &SearchResult) -> Result<()> {
        if let Some(channel) = result.metadata.get("channel").and_then(|v| v.as_str()) {
            let url = format!("slack://channel?id={channel}&team=");
            if opener::open(&url).is_err() {
                opener::open_browser("https://app.slack.com")?;
            }
        }
        Ok(())
    }
}

fn to_search_result(m: &SlackMessage, score: f32) -> SearchResult {
    let ts = chrono::DateTime::<Utc>::from_timestamp(m.ts_unix, 0)
        .map(|dt| dt.format("%b %d").to_string())
        .unwrap_or_default();

    let title: String = m.text.chars().take(120).collect();
    let mut r = SearchResult::new("slack", &title);
    r.id          = format!("slack:{}", m.msg_id);
    r.source_type = SourceType::Url;
    r.subtitle    = Some(format!("#{} · {} · {ts}", m.channel_name, m.user));
    r.score       = score;
    r.action      = ResultAction::Open;
    r.timestamp   = chrono::DateTime::<Utc>::from_timestamp(m.ts_unix, 0);
    r.metadata.insert("channel".into(),      m.channel.as_str().into());
    r.metadata.insert("channel_name".into(), m.channel_name.as_str().into());
    r.metadata.insert("user".into(),         m.user.as_str().into());
    r.metadata.insert("ts".into(),           ts.as_str().into());
    r
}
