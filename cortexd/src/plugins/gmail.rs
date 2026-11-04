/// Email plugin — Gmail (OAuth2) + Apple Mail (.emlx) indexer.
///
/// SQLite schema: ~/.cortex/email/emails.db
/// Qdrant collection: cortex_email
/// Embedding: nomic-embed-text (subject + snippet)

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
use tokio::task::spawn_blocking;

use crate::{
    embed::VectorStore,
    plugin::{Plugin, ResultAction, SearchQuery, SearchResult, SourceType},
};

const GMAIL_MESSAGES_URL: &str =
    "https://gmail.googleapis.com/gmail/v1/users/me/messages";

/* ─── Data types ────────────────────────────────────────── */

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EmailEntry {
    pub message_id: String,
    pub source:     String, // "gmail" | "apple_mail"
    pub subject:    String,
    pub from_addr:  String,
    pub date_unix:  i64,
    pub snippet:    String,
    pub thread_id:  Option<String>,
}

/* ─── Plugin ────────────────────────────────────────────── */

pub struct EmailPlugin {
    db_path:  PathBuf,
    cache:    RwLock<Vec<EmailEntry>>,
    matcher:  SkimMatcherV2,
    vs:       VectorStore,
    http:     reqwest::Client,
}

impl EmailPlugin {
    pub fn new(data_dir: PathBuf) -> Result<Self> {
        std::fs::create_dir_all(&data_dir)?;
        let db_path = data_dir.join("emails.db");
        Self::init_db(&db_path)?;
        Ok(Self {
            db_path,
            cache:   RwLock::new(vec![]),
            matcher: SkimMatcherV2::default(),
            vs:      VectorStore::new(),
            http:    reqwest::Client::builder()
                .timeout(Duration::from_secs(30))
                .build()?,
        })
    }

    fn init_db(path: &PathBuf) -> Result<()> {
        let conn = Connection::open(path)?;
        conn.execute_batch("
            CREATE TABLE IF NOT EXISTS emails (
                message_id  TEXT PRIMARY KEY,
                source      TEXT NOT NULL,
                subject     TEXT NOT NULL,
                from_addr   TEXT NOT NULL,
                date_unix   INTEGER NOT NULL,
                snippet     TEXT NOT NULL DEFAULT '',
                thread_id   TEXT
            );
            CREATE INDEX IF NOT EXISTS emails_date ON emails(date_unix DESC);
            CREATE INDEX IF NOT EXISTS emails_source ON emails(source);
        ")?;
        Ok(())
    }

    fn db(&self) -> Result<Connection> {
        Connection::open(&self.db_path).context("email db open")
    }

    fn load_cache(&self) -> Result<()> {
        let conn = self.db()?;
        let mut stmt = conn.prepare(
            "SELECT message_id, source, subject, from_addr, date_unix, snippet, thread_id \
             FROM emails ORDER BY date_unix DESC LIMIT 5000"
        )?;
        let entries: Vec<EmailEntry> = stmt.query_map([], |row| {
            Ok(EmailEntry {
                message_id: row.get(0)?,
                source:     row.get(1)?,
                subject:    row.get(2)?,
                from_addr:  row.get(3)?,
                date_unix:  row.get(4)?,
                snippet:    row.get(5)?,
                thread_id:  row.get(6)?,
            })
        })?
        .filter_map(|r| r.ok())
        .collect();

        *self.cache.write().unwrap() = entries;
        Ok(())
    }

    /* ── Gmail ─────────────────────────────────────────────── */

    async fn sync_gmail(&self) -> Result<usize> {
        let token = match crate::auth::get_valid_access_token().await {
            Ok(t)  => t,
            Err(e) => {
                tracing::debug!("Gmail: {e}");
                return Ok(0);
            }
        };

        // List message IDs — last 6 months, max 500 per page
        let after = Utc::now()
            .checked_sub_signed(chrono::Duration::days(180))
            .unwrap_or_else(Utc::now)
            .timestamp();
        let after_dt = chrono::DateTime::<Utc>::from_timestamp(after, 0)
            .unwrap()
            .format("%Y/%m/%d")
            .to_string();

        let mut page_token: Option<String> = None;
        let mut ids: Vec<(String, Option<String>)> = vec![]; // (messageId, threadId)
        let http = self.http.clone();
        let token_c = token.clone();

        loop {
            let mut req = http
                .get(GMAIL_MESSAGES_URL)
                .bearer_auth(&token_c)
                .query(&[
                    ("maxResults", "500"),
                    ("q", &format!("after:{after_dt}")),
                ]);
            if let Some(pt) = &page_token {
                req = req.query(&[("pageToken", pt.as_str())]);
            }

            #[derive(Deserialize)]
            struct ListResp {
                messages:      Option<Vec<MsgRef>>,
                #[serde(rename = "nextPageToken")]
                next_page_token: Option<String>,
            }
            #[derive(Deserialize)]
            struct MsgRef { id: String, #[serde(rename = "threadId")] thread_id: String }

            let resp: ListResp = req.send().await?.json().await?;
            if let Some(msgs) = resp.messages {
                for m in msgs {
                    ids.push((m.id, Some(m.thread_id)));
                }
            }
            page_token = resp.next_page_token;
            if page_token.is_none() { break; }
        }

        // Fetch metadata for each message (skip already-indexed)
        let conn = self.db()?;
        let mut new_count = 0usize;

        for (msg_id, thread_id) in &ids {
            // Check existing
            let exists: bool = conn.query_row(
                "SELECT 1 FROM emails WHERE message_id = ?",
                params![msg_id],
                |_| Ok(true),
            ).unwrap_or(false);
            if exists { continue; }

            let url = format!("{}/{}", GMAIL_MESSAGES_URL, msg_id);
            #[derive(Deserialize)]
            struct MsgResp {
                snippet: Option<String>,
                payload: Option<MsgPayload>,
                #[serde(rename = "internalDate")]
                internal_date: Option<String>,
            }
            #[derive(Deserialize)]
            struct MsgPayload { headers: Option<Vec<Header>> }
            #[derive(Deserialize)]
            struct Header { name: String, value: String }

            let msg: MsgResp = match self.http
                .get(&url)
                .bearer_auth(&token)
                .query(&[("format", "metadata"), ("metadataHeaders", "From"), ("metadataHeaders", "Subject")])
                .send().await?.json().await {
                    Ok(m) => m,
                    Err(e) => { tracing::debug!("gmail fetch {msg_id}: {e}"); continue; }
                };

            let headers = msg.payload
                .and_then(|p| p.headers)
                .unwrap_or_default();
            let subject = headers.iter()
                .find(|h| h.name.eq_ignore_ascii_case("Subject"))
                .map(|h| h.value.clone())
                .unwrap_or_default();
            let from_addr = headers.iter()
                .find(|h| h.name.eq_ignore_ascii_case("From"))
                .map(|h| h.value.clone())
                .unwrap_or_default();
            let snippet = msg.snippet.unwrap_or_default();
            let date_unix = msg.internal_date
                .and_then(|s| s.parse::<i64>().ok())
                .map(|ms| ms / 1000)
                .unwrap_or(0);

            conn.execute(
                "INSERT OR IGNORE INTO emails \
                 (message_id, source, subject, from_addr, date_unix, snippet, thread_id) \
                 VALUES (?1, 'gmail', ?2, ?3, ?4, ?5, ?6)",
                params![msg_id, subject, from_addr, date_unix, snippet, thread_id],
            )?;

            // Embed subject + snippet
            let embed_text = format!("{subject} {snippet}");
            let msg_id_c = msg_id.clone();
            let vs = self.vs.clone();
            let payload = serde_json::json!({ "id": msg_id_c, "source": "gmail" });
            tokio::spawn(async move {
                vs.index("cortex_email", &msg_id_c, &embed_text, payload).await;
            });

            new_count += 1;
        }

        tracing::info!("Gmail: indexed {new_count} new messages ({} total)", ids.len());
        Ok(new_count)
    }

    /* ── Apple Mail (.emlx) ────────────────────────────────── */

    async fn sync_apple_mail(&self) -> Result<usize> {
        let mail_root = dirs::home_dir()
            .unwrap_or_default()
            .join("Library/Mail");
        if !mail_root.exists() {
            return Ok(0);
        }

        let db_path = self.db_path.clone();
        let vs      = self.vs.clone();

        let count = spawn_blocking(move || -> Result<usize> {
            let conn = Connection::open(&db_path)?;
            let cutoff = Utc::now().timestamp() - 180 * 86400; // 6 months
            let mut new_count = 0usize;

            for entry in walkdir::WalkDir::new(&mail_root)
                .into_iter()
                .filter_map(|e| e.ok())
                .filter(|e| {
                    e.path().extension().map(|x| x == "emlx").unwrap_or(false)
                })
            {
                let path = entry.path().to_path_buf();
                // Use inode+size as a cheap unique key
                let meta = match std::fs::metadata(&path) { Ok(m) => m, Err(_) => continue };
                let mtime = meta.modified()
                    .ok()
                    .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                    .map(|d| d.as_secs() as i64)
                    .unwrap_or(0);

                if mtime < cutoff { continue; }

                // message_id based on path hash
                use std::hash::{Hash, Hasher};
                let mut hasher = std::collections::hash_map::DefaultHasher::new();
                path.hash(&mut hasher);
                let msg_id = format!("emlx:{:x}", hasher.finish());

                let exists: bool = conn.query_row(
                    "SELECT 1 FROM emails WHERE message_id = ?",
                    params![msg_id],
                    |_| Ok(true),
                ).unwrap_or(false);
                if exists { continue; }

                // Parse .emlx
                let (subject, from_addr, date_unix, snippet) =
                    match parse_emlx(&path) {
                        Ok(r) => r,
                        Err(e) => {
                            tracing::debug!("emlx parse {path:?}: {e}");
                            continue;
                        }
                    };

                if date_unix < cutoff { continue; }

                conn.execute(
                    "INSERT OR IGNORE INTO emails \
                     (message_id, source, subject, from_addr, date_unix, snippet) \
                     VALUES (?1, 'apple_mail', ?2, ?3, ?4, ?5)",
                    params![msg_id, subject, from_addr, date_unix, snippet],
                )?;

                // Spawn embed (non-blocking in separate task)
                let embed_text = format!("{subject} {snippet}");
                let mid = msg_id.clone();
                let vs2 = vs.clone();
                let payload = serde_json::json!({ "id": mid, "source": "apple_mail" });
                tokio::spawn(async move {
                    vs2.index("cortex_email", &mid, &embed_text, payload).await;
                });

                new_count += 1;
            }

            tracing::info!("Apple Mail: indexed {new_count} new .emlx files");
            Ok(new_count)
        }).await??;

        Ok(count)
    }

    fn count(&self) -> usize {
        self.cache.read().unwrap().len()
    }
}

/* ─── .emlx parser ──────────────────────────────────────── */

/// .emlx format: first line = byte count, then RFC 2822 email bytes, then XML plist.
/// Returns (subject, from, date_unix, snippet).
fn parse_emlx(path: &PathBuf) -> Result<(String, String, i64, String)> {
    let raw = std::fs::read(path)?;
    let text = String::from_utf8_lossy(&raw);

    // First line: byte count
    let newline = text.find('\n').unwrap_or(text.len());
    let byte_count: usize = text[..newline].trim().parse().unwrap_or(0);
    if byte_count == 0 {
        anyhow::bail!("invalid emlx byte count");
    }

    // Email body is next `byte_count` bytes after the newline
    let email_start = newline + 1;
    let email_end   = (email_start + byte_count).min(raw.len());
    let email_bytes = &raw[email_start..email_end];

    let parsed = mailparse::parse_mail(email_bytes)?;

    let subject = parsed.headers.iter()
        .find(|h| h.get_key_ref().eq_ignore_ascii_case("Subject"))
        .map(|h| h.get_value())
        .unwrap_or_default();
    let from_addr = parsed.headers.iter()
        .find(|h| h.get_key_ref().eq_ignore_ascii_case("From"))
        .map(|h| h.get_value())
        .unwrap_or_default();
    let date_str = parsed.headers.iter()
        .find(|h| h.get_key_ref().eq_ignore_ascii_case("Date"))
        .map(|h| h.get_value())
        .unwrap_or_default();

    let date_unix = mailparse::dateparse(&date_str).unwrap_or(0);

    // Body snippet — first 300 chars of first text/plain part
    let snippet = extract_body_snippet(&parsed);

    Ok((subject, from_addr, date_unix, snippet))
}

fn extract_body_snippet(mail: &mailparse::ParsedMail) -> String {
    if mail.subparts.is_empty() {
        return mail.get_body()
            .unwrap_or_default()
            .chars()
            .take(300)
            .collect();
    }
    for part in &mail.subparts {
        let ct = part.ctype.mimetype.to_ascii_lowercase();
        if ct == "text/plain" {
            return part.get_body()
                .unwrap_or_default()
                .chars()
                .take(300)
                .collect();
        }
    }
    String::new()
}

/* ─── Plugin impl ───────────────────────────────────────── */

#[async_trait]
impl Plugin for EmailPlugin {
    fn id(&self)   -> &str { "email" }
    fn name(&self) -> &str { "Email" }
    fn icon(&self) -> &str { "✉️" }

    async fn count(&self) -> u64 {
        let db = self.db_path.clone();
        tokio::task::spawn_blocking(move || {
            Connection::open(&db).ok()
                .and_then(|c| c.query_row("SELECT COUNT(*) FROM emails", [], |r| r.get::<_, i64>(0)).ok())
                .unwrap_or(0) as u64
        }).await.unwrap_or(0)
    }

    async fn sync(&self) -> Result<usize> {
        let g = self.sync_gmail().await.unwrap_or_else(|e| {
            tracing::warn!("gmail sync: {e}"); 0
        });
        let a = self.sync_apple_mail().await.unwrap_or_else(|e| {
            tracing::warn!("apple mail sync: {e}"); 0
        });
        let _ = self.load_cache();
        Ok(g + a)
    }

    async fn search(&self, query: &SearchQuery) -> Result<Vec<SearchResult>> {
        let q = &query.raw;

        // Semantic hits
        let semantic_ids: Vec<String> = self.vs
            .search("cortex_email", q, 20)
            .await
            .into_iter()
            .map(|(id, _)| id)
            .collect();

        let cache = self.cache.read().unwrap();

        let mut results: Vec<SearchResult> = cache.iter()
            .filter_map(|e| {
                let haystack = format!("{} {} {}", e.subject, e.from_addr, e.snippet);
                let fuzzy = self.matcher.fuzzy_match(&haystack, q)
                    .map(|s| s as f32 / 300.0)
                    .unwrap_or(0.0);
                let boost = if semantic_ids.contains(&e.message_id) { 0.2 } else { 0.0 };
                let score = (fuzzy + boost).min(0.99);
                if score > 0.0 {
                    Some(to_search_result(e, score))
                } else {
                    None
                }
            })
            .collect();

        // Add semantic-only hits not in fuzzy results
        for sid in &semantic_ids {
            if !results.iter().any(|r| r.id.contains(sid)) {
                if let Some(e) = cache.iter().find(|e| &e.message_id == sid) {
                    results.push(to_search_result(e, 0.5));
                }
            }
        }

        results.sort_by(|a, b| b.score.partial_cmp(&a.score).unwrap());
        results.truncate(30);
        Ok(results)
    }

    async fn execute(&self, result: &SearchResult) -> Result<()> {
        if let Some(tid) = result.metadata.get("thread_id").and_then(|v| v.as_str()) {
            let url = format!("https://mail.google.com/mail/u/0/#inbox/{tid}");
            opener::open_browser(&url)?;
        } else if result.plugin_id == "email" {
            opener::open_browser("https://mail.google.com")?;
        }
        Ok(())
    }
}

fn to_search_result(e: &EmailEntry, score: f32) -> SearchResult {
    let date = chrono::DateTime::<Utc>::from_timestamp(e.date_unix, 0)
        .map(|dt| dt.format("%b %d").to_string())
        .unwrap_or_default();

    let icon = if e.source == "gmail" { "✉" } else { "📧" };

    let mut r = SearchResult::new("email", &e.subject);
    r.id          = format!("email:{}:{}", e.source, e.message_id);
    r.source_type = SourceType::Url;
    r.subtitle    = Some(format!("{icon} {} · {date}", e.from_addr));
    r.score       = score;
    r.action      = ResultAction::Open;
    r.timestamp   = chrono::DateTime::<Utc>::from_timestamp(e.date_unix, 0);
    r.metadata.insert("source".into(),  e.source.as_str().into());
    r.metadata.insert("from".into(),    e.from_addr.as_str().into());
    r.metadata.insert("date".into(),    date.as_str().into());
    r.metadata.insert("snippet".into(), e.snippet.as_str().into());
    if let Some(tid) = &e.thread_id {
        r.metadata.insert("thread_id".into(), tid.as_str().into());
    }
    r
}
