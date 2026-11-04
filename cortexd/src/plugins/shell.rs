/// Shell plugin — zsh/bash/fish history + real-time hook receiver.
///
/// History: parses ~/.zsh_history (extended + plain), ~/.bash_history, fish_history
/// Hook:    HTTP server on :27184 receives JSON {cmd, cwd, exit_code, timestamp}
///          from shell preexec/precmd hooks (zsh/bash snippets below)
///
/// SQLite: ~/.cortex/shell/commands.db
/// Tantivy: ~/.cortex/indices/shell/ — indexed on `command` text
///
/// ## Shell hook setup (add to ~/.zshrc)
/// ```zsh
/// _cortex_hook() {
///   local exit_code=$?
///   curl -s -X POST http://localhost:27184/hook \
///     -H 'Content-Type: application/json' \
///     -d "{\"cmd\":\"${(q)1}\",\"cwd\":\"$PWD\",\"exit_code\":$exit_code,\"timestamp\":$(date +%s)}" &!
/// }
/// preexec_functions+=(_cortex_hook)
/// ```

use anyhow::Result;
use async_trait::async_trait;
use chrono::{DateTime, Utc};
use dirs::home_dir;
use fuzzy_matcher::{skim::SkimMatcherV2, FuzzyMatcher};
use rusqlite::{params, Connection};
use serde::Deserialize;
use std::{
    io::{BufRead, BufReader},
    path::PathBuf,
    sync::Arc,
};
use tantivy::{
    collector::TopDocs,
    doc,
    query::QueryParser,
    schema::{Field, Schema, Value, FAST, STORED, TEXT},
    Index, IndexWriter, TantivyDocument, Term,
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpListener,
    sync::Mutex,
};

use crate::plugin::{Plugin, ResultAction, SearchQuery, SearchResult, SourceType};

const HOOK_PORT: u16 = 27184;

/* ─── Tantivy fields ────────────────────────────────────── */

#[derive(Clone)]
pub(crate) struct ShellFields {
    command: Field,
    cwd:     Field,
    source:  Field,
    ts:      Field,
}

/* ─── Hook payload ──────────────────────────────────────── */

#[derive(Deserialize)]
pub struct HookPayload {
    pub cmd:       String,
    #[serde(default)]
    pub cwd:       String,
    #[serde(default)]
    pub exit_code: i32,
    #[serde(default)]
    pub timestamp: i64,
}

/* ─── Plugin ────────────────────────────────────────────── */

pub struct ShellPlugin {
    index:   Index,
    writer:  Arc<Mutex<IndexWriter>>,
    fields:  ShellFields,
    db_path: PathBuf,
    matcher: SkimMatcherV2,
}

impl ShellPlugin {
    pub fn new(data_dir: PathBuf) -> Result<Self> {
        std::fs::create_dir_all(&data_dir)?;

        let index_dir = data_dir.join("index");
        std::fs::create_dir_all(&index_dir)?;
        let db_path = data_dir.join("commands.db");
        Self::init_db(&db_path)?;

        let mut sb = Schema::builder();
        let command = sb.add_text_field("command", TEXT | STORED);
        let cwd     = sb.add_text_field("cwd",     TEXT | STORED);
        let source  = sb.add_text_field("source",  STORED);
        let ts      = sb.add_u64_field("ts",        FAST | STORED);
        let schema  = sb.build();

        let index = if index_dir.join("meta.json").exists() {
            Index::open_in_dir(&index_dir)?
        } else {
            Index::create_in_dir(&index_dir, schema)?
        };
        let writer = index.writer(32_000_000)?;

        Ok(Self {
            index,
            writer: Arc::new(Mutex::new(writer)),
            fields: ShellFields { command, cwd, source, ts },
            db_path,
            matcher: SkimMatcherV2::default(),
        })
    }

    fn init_db(path: &PathBuf) -> Result<()> {
        let conn = Connection::open(path)?;
        conn.execute_batch("
            CREATE TABLE IF NOT EXISTS commands (
                id         INTEGER PRIMARY KEY AUTOINCREMENT,
                command    TEXT NOT NULL,
                cwd        TEXT NOT NULL DEFAULT '',
                exit_code  INTEGER,
                timestamp  INTEGER NOT NULL DEFAULT 0,
                source     TEXT NOT NULL DEFAULT 'history'
            );
            CREATE UNIQUE INDEX IF NOT EXISTS cmds_dedup
                ON commands(command, timestamp);
            CREATE INDEX IF NOT EXISTS cmds_ts ON commands(timestamp DESC);
        ")?;
        Ok(())
    }

    fn db(&self) -> Result<Connection> {
        Connection::open(&self.db_path).map_err(|e| anyhow::anyhow!("shell db: {e}"))
    }

    #[allow(dead_code)]
    pub(crate) fn index_writer(&self) -> Arc<Mutex<IndexWriter>> {
        self.writer.clone()
    }

    #[allow(dead_code)]
    pub(crate) fn fields(&self) -> ShellFields {
        self.fields.clone()
    }

    /* ── History parsers ─────────────────────────────────── */

    fn history_paths() -> Vec<PathBuf> {
        let home = home_dir().unwrap_or_default();
        vec![
            home.join(".zsh_history"),
            home.join(".bash_history"),
            home.join(".local/share/fish/fish_history"),
        ]
        .into_iter()
        .filter(|p| p.exists())
        .collect()
    }

    fn parse_zsh(path: &PathBuf) -> Vec<(String, i64, String)> {
        let Ok(file) = std::fs::File::open(path) else { return vec![] };
        let reader = BufReader::new(file);
        let mut entries = Vec::new();

        for line in reader.lines().filter_map(|l| l.ok()) {
            if let Some(rest) = line.strip_prefix(": ") {
                if let Some((ts_dur, cmd)) = rest.split_once(';') {
                    let ts = ts_dur.split_once(':')
                        .and_then(|(ts, _)| ts.parse::<i64>().ok())
                        .unwrap_or(0);
                    let cmd = cmd.trim().to_string();
                    if !cmd.is_empty() {
                        entries.push((cmd, ts, "history".to_string()));
                    }
                    continue;
                }
            }
            let line = line.trim().to_string();
            if !line.is_empty() {
                entries.push((line, 0, "history".to_string()));
            }
        }
        entries
    }

    fn parse_fish(path: &PathBuf) -> Vec<(String, i64, String)> {
        let Ok(content) = std::fs::read_to_string(path) else { return vec![] };
        let mut entries = Vec::new();
        let mut current_cmd: Option<String> = None;
        let mut current_ts = 0i64;

        for line in content.lines() {
            if let Some(cmd) = line.strip_prefix("- cmd: ") {
                if let Some(c) = current_cmd.take() {
                    entries.push((c, current_ts, "history".to_string()));
                }
                current_cmd = Some(cmd.to_string());
                current_ts = 0;
            } else if let Some(ts) = line.strip_prefix("  when: ") {
                current_ts = ts.parse().unwrap_or(0);
            }
        }
        if let Some(c) = current_cmd {
            entries.push((c, current_ts, "history".to_string()));
        }
        entries
    }

    /// Insert command into DB + Tantivy (deduplicated).
    pub async fn index_command(
        &self,
        cmd: &str,
        cwd: &str,
        exit_code: Option<i32>,
        ts: i64,
        source: &str,
    ) {
        let cmd = cmd.trim();
        if cmd.is_empty() { return; }

        let db = match self.db() {
            Ok(c) => c,
            Err(_) => return,
        };

        let inserted = db.execute(
            "INSERT OR IGNORE INTO commands (command, cwd, exit_code, timestamp, source) \
             VALUES (?1, ?2, ?3, ?4, ?5)",
            params![cmd, cwd, exit_code, ts, source],
        ).map(|n| n > 0).unwrap_or(false);

        if !inserted { return; }

        let mut writer = self.writer.lock().await;
        // Delete any old entry for same command text
        let term = Term::from_field_text(self.fields.command, cmd);
        writer.delete_term(term);
        let _ = writer.add_document(doc!(
            self.fields.command => cmd,
            self.fields.cwd     => cwd,
            self.fields.source  => source,
            self.fields.ts      => ts.max(0) as u64,
        ));
        let _ = writer.commit();
    }
}

/* ─── Hook server ───────────────────────────────────────── */

/// Spawn the HTTP hook receiver on :27184.
/// Accepts POST /hook with JSON body { cmd, cwd, exit_code, timestamp }.
pub async fn start_hook_server(plugin: Arc<ShellPlugin>) {
    let listener = match TcpListener::bind(("127.0.0.1", HOOK_PORT)).await {
        Ok(l) => l,
        Err(e) => {
            tracing::warn!("shell hook server bind :{HOOK_PORT}: {e}");
            return;
        }
    };
    tracing::info!("Shell hook server on :{HOOK_PORT}");

    loop {
        let (mut stream, _) = match listener.accept().await {
            Ok(c) => c,
            Err(_) => continue,
        };
        let plugin = plugin.clone();
        tokio::spawn(async move {
            let mut buf = vec![0u8; 16_384];
            let n = match stream.read(&mut buf).await {
                Ok(n) => n,
                Err(_) => return,
            };
            let request = String::from_utf8_lossy(&buf[..n]);

            // Parse body from HTTP POST
            let body = if let Some(body_start) = request.find("\r\n\r\n") {
                &request[body_start + 4..]
            } else if let Some(body_start) = request.find("\n\n") {
                &request[body_start + 2..]
            } else {
                return;
            };

            if let Ok(payload) = serde_json::from_str::<HookPayload>(body) {
                let ts = if payload.timestamp > 0 {
                    payload.timestamp
                } else {
                    Utc::now().timestamp()
                };
                plugin.index_command(
                    &payload.cmd,
                    &payload.cwd,
                    Some(payload.exit_code),
                    ts,
                    "hook",
                ).await;
            }

            // 200 OK response
            let _ = stream.write_all(
                b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
            ).await;
        });
    }
}

/* ─── Plugin impl ───────────────────────────────────────── */

#[async_trait]
impl Plugin for ShellPlugin {
    fn id(&self)   -> &str { "shell" }
    fn name(&self) -> &str { "Shell" }
    fn icon(&self) -> &str { "⚡" }

    async fn count(&self) -> u64 {
        let reader = match self.index.reader() {
            Ok(r) => r,
            Err(_) => return 0,
        };
        reader.searcher().num_docs()
    }

    async fn sync(&self) -> Result<usize> {
        let mut all: Vec<(String, i64, String)> = Vec::new();

        for path in Self::history_paths() {
            let parsed = if path.file_name().map(|n| n == "fish_history").unwrap_or(false) {
                Self::parse_fish(&path)
            } else {
                Self::parse_zsh(&path)
            };
            all.extend(parsed);
        }

        // Dedup by command, keep most-recent timestamp
        all.sort_unstable_by(|a, b| b.1.cmp(&a.1));
        all.dedup_by(|a, b| a.0 == b.0);

        let count = all.len();

        // Batch-index into SQLite + Tantivy
        for (cmd, ts, source) in &all {
            self.index_command(cmd, "", None, *ts, source).await;
        }

        tracing::info!("Shell: indexed {count} history entries");
        Ok(count)
    }

    async fn search(&self, query: &SearchQuery) -> Result<Vec<SearchResult>> {
        let q = &query.raw;
        if q.trim().is_empty() { return Ok(vec![]); }

        let reader  = self.index.reader()?;
        let searcher = reader.searcher();
        let qp = QueryParser::for_index(&self.index, vec![self.fields.command]);
        let tq = qp.parse_query_lenient(q).0;
        let top = searcher.search(&tq, &TopDocs::with_limit(15))?;

        let fields = &self.fields;
        let mut results: Vec<SearchResult> = top.iter().map(|(score, addr)| {
            let doc: TantivyDocument = searcher.doc(*addr).unwrap_or_default();
            let command = doc.get_first(fields.command)
                .and_then(|v| v.as_str()).unwrap_or("").to_string();
            let cwd = doc.get_first(fields.cwd)
                .and_then(|v| v.as_str()).unwrap_or("").to_string();
            let ts = doc.get_first(fields.ts)
                .and_then(|v| v.as_u64()).map(|t| t as i64).unwrap_or(0);

            let mut r = SearchResult::new("shell", &command);
            r.source_type = SourceType::ShellCommand;
            r.subtitle    = if !cwd.is_empty() { Some(format!("in {cwd}")) } else { None };
            r.score       = (*score).min(0.99);
            r.timestamp   = DateTime::from_timestamp(ts, 0).map(|dt| dt.with_timezone(&Utc));
            r.action      = ResultAction::Run;
            r
        }).collect();

        // Fuzzy fallback via matcher if Tantivy returns nothing
        if results.is_empty() {
            let all_top = searcher.search(
                &tantivy::query::AllQuery,
                &TopDocs::with_limit(500),
            )?;
            let matcher = &self.matcher;
            let mut fuzzy: Vec<(i64, TantivyDocument)> = all_top.iter()
                .filter_map(|(_, addr)| searcher.doc::<TantivyDocument>(*addr).ok())
                .filter_map(|doc: TantivyDocument| {
                    let cmd = doc.get_first(fields.command)
                        .and_then(|v| v.as_str()).unwrap_or("");
                    matcher.fuzzy_match(cmd, q).map(|s| (s, doc))
                })
                .collect();
            fuzzy.sort_unstable_by(|a, b| b.0.cmp(&a.0));
            fuzzy.truncate(15);
            results = fuzzy.into_iter().map(|(score, doc)| {
                let command = doc.get_first(fields.command)
                    .and_then(|v| v.as_str()).unwrap_or("").to_string();
                let cwd = doc.get_first(fields.cwd)
                    .and_then(|v| v.as_str()).unwrap_or("").to_string();
                let ts = doc.get_first(fields.ts)
                    .and_then(|v| v.as_u64()).map(|t| t as i64).unwrap_or(0);

                let mut r = SearchResult::new("shell", &command);
                r.source_type = SourceType::ShellCommand;
                r.subtitle    = if !cwd.is_empty() { Some(format!("in {cwd}")) } else { None };
                r.score       = (score as f32 / 300.0).min(0.95);
                r.timestamp   = DateTime::from_timestamp(ts, 0).map(|dt| dt.with_timezone(&Utc));
                r.action      = ResultAction::Run;
                r
            }).collect();
        }

        Ok(results)
    }

    async fn execute(&self, result: &SearchResult) -> Result<()> {
        let cmd = result.title.clone();

        #[cfg(target_os = "macos")]
        {
            std::process::Command::new("osascript")
                .arg("-e")
                .arg(format!(
                    r#"tell app "Terminal" to do script "{}" in front window"#,
                    cmd.replace('"', r#"\""#)
                ))
                .spawn()?;
        }
        #[cfg(target_os = "linux")]
        {
            std::process::Command::new("sh").arg("-c").arg(&cmd).spawn()?;
        }
        Ok(())
    }
}
