/// Clipboard plugin — polls arboard every 500 ms in a background task.
///
/// Dedup:      SHA-256 of clipboard text; last hash kept in memory.
///             Also stores hash in SQLite — prevents re-inserting content
///             that was added in a previous session.
///
/// source_app: macOS → AppleScript `frontmost application process name`
///             Linux → xdotool getactivewindow getwindowname (best-effort)
///             Windows → GetForegroundWindow + GetWindowText (best-effort)
///
/// Schema:     id TEXT PK, content TEXT, content_hash TEXT UNIQUE,
///             source_app TEXT, ts INTEGER

use anyhow::Result;
use async_trait::async_trait;
use chrono::{DateTime, Utc};
use fuzzy_matcher::{skim::SkimMatcherV2, FuzzyMatcher};
use sha2::{Digest, Sha256};
use std::path::PathBuf;
use tokio::sync::RwLock;

use crate::plugin::{Plugin, ResultAction, SearchQuery, SearchResult, SourceType};

/* ─── Schema helpers ────────────────────────────────────── */

const INIT_SQL: &str = "
CREATE TABLE IF NOT EXISTS clips (
    id           TEXT PRIMARY KEY,
    content      TEXT NOT NULL,
    content_hash TEXT NOT NULL,
    source_app   TEXT,
    ts           INTEGER NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS clips_hash ON clips(content_hash);
CREATE INDEX IF NOT EXISTS clips_ts   ON clips(ts DESC);
";

/* ─── In-memory entry ───────────────────────────────────── */

#[derive(Debug, Clone)]
pub struct ClipEntry {
    pub id:         String,
    pub content:    String,
    pub source_app: Option<String>,
    pub timestamp:  DateTime<Utc>,
}

/* ─── Plugin struct ─────────────────────────────────────── */

pub struct ClipboardPlugin {
    pub db_path: PathBuf,
    cache:       RwLock<Vec<ClipEntry>>,
    matcher:     SkimMatcherV2,
}

impl ClipboardPlugin {
    pub fn new(data_dir: PathBuf) -> Result<Self> {
        std::fs::create_dir_all(&data_dir)?;
        let db_path = data_dir.join("clipboard.db");
        let conn = rusqlite::Connection::open(&db_path)?;
        conn.execute_batch(INIT_SQL)?;
        Ok(Self {
            db_path,
            cache:   RwLock::new(Vec::new()),
            matcher: SkimMatcherV2::default(),
        })
    }

    /// Insert a new clip.  `INSERT OR IGNORE` — UNIQUE(content_hash) handles dedup.
    pub fn ingest(&self, content: String, source_app: Option<String>) -> Result<()> {
        let hash = sha256_hex(&content);
        let id   = uuid::Uuid::new_v4().to_string();
        let now  = Utc::now().timestamp();
        let conn = rusqlite::Connection::open(&self.db_path)?;
        conn.execute(
            "INSERT OR IGNORE INTO clips (id, content, content_hash, source_app, ts)
             VALUES (?1, ?2, ?3, ?4, ?5)",
            rusqlite::params![id, content, hash, source_app, now],
        )?;
        Ok(())
    }

    fn load_recent(db_path: &PathBuf, limit: usize) -> Vec<ClipEntry> {
        let Ok(conn) = rusqlite::Connection::open(db_path) else { return vec![] };
        let Ok(mut stmt) = conn.prepare(
            "SELECT id, content, source_app, ts FROM clips ORDER BY ts DESC LIMIT ?1",
        ) else { return vec![] };

        // Collect eagerly so all borrows of conn+stmt are resolved before the
        // block ends — required by rusqlite's lifetime constraints.
        let rows = stmt.query_map([limit as i64], |row| {
            let ts_unix: i64 = row.get(3)?;
            Ok(ClipEntry {
                id:         row.get(0)?,
                content:    row.get(1)?,
                source_app: row.get(2)?,
                timestamp:  DateTime::from_timestamp(ts_unix, 0)
                    .unwrap_or_default()
                    .with_timezone(&Utc),
            })
        });
        let result: Vec<ClipEntry> = match rows {
            Ok(mapped) => mapped.filter_map(|r| r.ok()).collect(),
            Err(_)     => vec![],
        };
        result
    }
}

/* ─── Plugin impl ───────────────────────────────────────── */

#[async_trait]
impl Plugin for ClipboardPlugin {
    fn id(&self)   -> &str { "clipboard" }
    fn name(&self) -> &str { "Clipboard" }
    fn icon(&self) -> &str { "📋" }

    async fn count(&self) -> u64 {
        let db = self.db_path.clone();
        tokio::task::spawn_blocking(move || {
            rusqlite::Connection::open(&db)
                .ok()
                .and_then(|c| {
                    c.query_row("SELECT COUNT(*) FROM clips", [], |r| r.get::<_, i64>(0))
                        .ok()
                })
                .unwrap_or(0) as u64
        })
        .await
        .unwrap_or(0)
    }

    async fn sync(&self) -> Result<usize> {
        let entries = Self::load_recent(&self.db_path, 1_000);
        let count = entries.len();
        *self.cache.write().await = entries;
        Ok(count)
    }

    async fn search(&self, query: &SearchQuery) -> Result<Vec<SearchResult>> {
        let cache = self.cache.read().await;
        let q = &query.raw;

        let mut scored: Vec<(i64, &ClipEntry)> = cache
            .iter()
            .filter_map(|e| self.matcher.fuzzy_match(&e.content, q).map(|s| (s, e)))
            .collect();

        scored.sort_unstable_by(|a, b| b.0.cmp(&a.0));
        scored.truncate(10);

        let results = scored.into_iter().map(|(score, e)| {
            let preview = e.content.lines().next().unwrap_or("").chars().take(80).collect::<String>();
            let mut r = SearchResult::new("clipboard", preview);
            r.source_type = SourceType::ClipboardText;
            r.content     = Some(e.content.chars().take(512).collect());
            r.subtitle    = e.source_app.clone().map(|a| format!("from {a}"));
            r.score       = (score as f32 / 300.0).min(0.90);
            r.timestamp   = Some(e.timestamp);
            r.action      = ResultAction::Copy;
            r
        }).collect();

        Ok(results)
    }

    async fn execute(&self, result: &SearchResult) -> Result<()> {
        if let Some(content) = &result.content {
            let mut ctx = arboard::Clipboard::new()?;
            ctx.set_text(content.clone())?;
        }
        Ok(())
    }
}

/* ─── SHA-256 helper ─────────────────────────────────────── */

fn sha256_hex(s: &str) -> String {
    let mut h = Sha256::new();
    h.update(s.as_bytes());
    hex::encode(h.finalize())
}

/* ─── Active-app detection ───────────────────────────────── */

/// Returns the name of the currently focused application, best-effort.
fn get_active_app() -> Option<String> {
    #[cfg(target_os = "macos")]
    {
        let out = std::process::Command::new("osascript")
            .args([
                "-e",
                "tell application \"System Events\" \
                 to get name of first application process whose frontmost is true",
            ])
            .output()
            .ok()?;
        let name = String::from_utf8_lossy(&out.stdout).trim().to_string();
        return if name.is_empty() { None } else { Some(name) };
    }

    #[cfg(target_os = "linux")]
    {
        // xdotool is optional; fail silently if not installed
        let wid = std::process::Command::new("xdotool")
            .arg("getactivewindow")
            .output()
            .ok()?;
        let wid_str = String::from_utf8_lossy(&wid.stdout).trim().to_string();
        let name = std::process::Command::new("xdotool")
            .args(["getwindowname", &wid_str])
            .output()
            .ok()?;
        let s = String::from_utf8_lossy(&name.stdout).trim().to_string();
        return if s.is_empty() { None } else { Some(s) };
    }

    #[cfg(target_os = "windows")]
    {
        // GetForegroundWindow → GetWindowTextW — requires winapi
        // Stub for now; returns None until winapi dep is added
        return None;
    }

    #[allow(unreachable_code)]
    None
}

/* ─── Background watcher task ────────────────────────────── */

/// Polls arboard every 500 ms.  Deduplicates by SHA-256; only persists when
/// the hash differs from the last-seen value.  Gets the active app name
/// before writing so the entry is annotated with its source.
pub async fn watch_clipboard(plugin: std::sync::Arc<ClipboardPlugin>) {
    let mut last_hash: Option<String> = None;
    let interval = std::time::Duration::from_millis(500);

    loop {
        tokio::time::sleep(interval).await;

        // arboard is not async; run on blocking thread to avoid stalling executor
        let text = tokio::task::spawn_blocking(|| {
            arboard::Clipboard::new().ok()?.get_text().ok()
        })
        .await
        .unwrap_or(None);

        let Some(text) = text else { continue };
        if text.trim().is_empty() { continue }

        let hash = sha256_hex(&text);
        if Some(&hash) == last_hash.as_ref() {
            continue; // identical content — skip
        }

        // Capture active app (may be slow on macOS; run on blocking thread)
        let app = tokio::task::spawn_blocking(get_active_app)
            .await
            .unwrap_or(None);

        if let Err(e) = plugin.ingest(text, app) {
            tracing::warn!("clipboard ingest: {e}");
        }
        last_hash = Some(hash);
    }
}
