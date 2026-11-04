/// VS Code plugin — recently opened workspaces and files.
///
/// Reads VS Code's local state storage:
///   macOS: ~/Library/Application Support/Code/
///   Linux: ~/.config/Code/
///   Also checks Cursor, VS Code Insiders, Codium variants.
///
/// Sources:
///   storage.json → openedPathsList.workspaces3 / entries / files3
///   User/settings.json → extracts configured paths
///
/// Indexes into Tantivy for fast full-text search.
/// Cross-references with files plugin: matching paths get score boost.

use anyhow::Result;
use async_trait::async_trait;
use chrono::{DateTime, Utc};
use fuzzy_matcher::{skim::SkimMatcherV2, FuzzyMatcher};
use serde_json::Value as JsonValue;
use std::{
    path::PathBuf,
    sync::Arc,
};
use tantivy::{
    collector::TopDocs,
    doc,
    query::QueryParser,
    schema::{Field, Schema, Value, FAST, STORED, TEXT},
    Index, IndexWriter, TantivyDocument,
};
use tokio::sync::Mutex;

use crate::plugin::{Plugin, ResultAction, SearchQuery, SearchResult, SourceType};

/* ─── VS Code entry ─────────────────────────────────────── */

#[derive(Debug, Clone)]
struct VscodeEntry {
    path:        String,
    name:        String,
    kind:        String, // "workspace" | "file" | "folder"
    last_opened: i64,
}

/* ─── Tantivy fields ────────────────────────────────────── */

#[derive(Clone)]
struct VsFields {
    name:  Field,
    path:  Field,
    kind:  Field,
    ts:    Field,
}

/* ─── Plugin ────────────────────────────────────────────── */

pub struct VscodePlugin {
    index:   Index,
    writer:  Arc<Mutex<IndexWriter>>,
    fields:  VsFields,
    matcher: SkimMatcherV2,
}

impl VscodePlugin {
    pub fn new(index_dir: PathBuf) -> Result<Self> {
        std::fs::create_dir_all(&index_dir)?;

        let mut sb = Schema::builder();
        let name = sb.add_text_field("name", TEXT | STORED);
        let path = sb.add_text_field("path", TEXT | STORED);
        let kind = sb.add_text_field("kind", STORED);
        let ts   = sb.add_u64_field("ts",    FAST | STORED);
        let schema = sb.build();

        let index = if index_dir.join("meta.json").exists() {
            Index::open_in_dir(&index_dir)?
        } else {
            Index::create_in_dir(&index_dir, schema)?
        };
        let writer = index.writer(16_000_000)?;

        Ok(Self {
            index,
            writer: Arc::new(Mutex::new(writer)),
            fields: VsFields { name, path, kind, ts },
            matcher: SkimMatcherV2::default(),
        })
    }

    /* ── Storage root detection ──────────────────────────── */

    fn vscode_data_dirs() -> Vec<PathBuf> {
        let home = dirs::home_dir().unwrap_or_default();

        let candidates = vec![
            // VS Code stable
            #[cfg(target_os = "macos")]
            home.join("Library/Application Support/Code"),
            #[cfg(target_os = "linux")]
            home.join(".config/Code"),
            // VS Code Insiders
            #[cfg(target_os = "macos")]
            home.join("Library/Application Support/Code - Insiders"),
            #[cfg(target_os = "linux")]
            home.join(".config/Code - Insiders"),
            // Cursor
            #[cfg(target_os = "macos")]
            home.join("Library/Application Support/Cursor"),
            #[cfg(target_os = "linux")]
            home.join(".config/Cursor"),
            // VSCodium
            #[cfg(target_os = "macos")]
            home.join("Library/Application Support/VSCodium"),
            #[cfg(target_os = "linux")]
            home.join(".config/VSCodium"),
        ];

        candidates.into_iter().filter(|p| p.exists()).collect()
    }

    /* ── storage.json parser ─────────────────────────────── */

    fn parse_storage(storage_path: &PathBuf) -> Vec<VscodeEntry> {
        let Ok(raw) = std::fs::read_to_string(storage_path) else { return vec![] };
        let Ok(json): Result<JsonValue, _> = serde_json::from_str(&raw) else { return vec![] };

        let mut entries = Vec::new();

        // Try "openedPathsList" → workspaces3/entries/files3
        if let Some(opl) = json.get("openedPathsList") {
            // Workspaces
            if let Some(ws) = opl.get("workspaces3").and_then(|v| v.as_array()) {
                for item in ws {
                    if let Some(path) = item.as_str() {
                        let p = uri_to_path(path);
                        if !p.is_empty() {
                            let name = PathBuf::from(&p)
                                .file_name()
                                .map(|n| n.to_string_lossy().to_string())
                                .unwrap_or_else(|| p.clone());
                            entries.push(VscodeEntry {
                                path: p,
                                name,
                                kind: "workspace".into(),
                                last_opened: 0,
                            });
                        }
                    }
                }
            }

            // Generic entries (mixed workspaces+files, newer VS Code format)
            if let Some(ents) = opl.get("entries").and_then(|v| v.as_array()) {
                for item in ents {
                    let path_raw = item.get("folderUri")
                        .or_else(|| item.get("fileUri"))
                        .or_else(|| item.get("workspace").and_then(|w| w.get("configPath")))
                        .and_then(|v| v.as_str())
                        .unwrap_or("");
                    if path_raw.is_empty() { continue; }
                    let p    = uri_to_path(path_raw);
                    let kind = if item.get("fileUri").is_some() { "file" }
                               else { "workspace" };
                    let ts   = item.get("timestamp")
                        .and_then(|v| v.as_i64())
                        .map(|ms| ms / 1000)
                        .unwrap_or(0);
                    let name = PathBuf::from(&p)
                        .file_name()
                        .map(|n| n.to_string_lossy().to_string())
                        .unwrap_or_else(|| p.clone());
                    if !p.is_empty() {
                        entries.push(VscodeEntry { path: p, name, kind: kind.into(), last_opened: ts });
                    }
                }
            }

            // files3
            if let Some(files) = opl.get("files3").and_then(|v| v.as_array()) {
                for item in files {
                    if let Some(path) = item.as_str() {
                        let p = uri_to_path(path);
                        if !p.is_empty() {
                            let name = PathBuf::from(&p)
                                .file_name()
                                .map(|n| n.to_string_lossy().to_string())
                                .unwrap_or_else(|| p.clone());
                            entries.push(VscodeEntry {
                                path: p,
                                name,
                                kind: "file".into(),
                                last_opened: 0,
                            });
                        }
                    }
                }
            }
        }

        // Also try top-level "recently opened" format (some VS Code versions)
        if let Some(recent) = json.get("recentlyOpened").and_then(|v| v.as_array()) {
            for item in recent {
                let path_raw = item.get("fileUri")
                    .or_else(|| item.get("folderUri"))
                    .and_then(|v| v.as_str())
                    .unwrap_or("");
                if path_raw.is_empty() { continue; }
                let p    = uri_to_path(path_raw);
                let kind = if item.get("fileUri").is_some() { "file" } else { "workspace" };
                let ts   = item.get("timestamp")
                    .and_then(|v| v.as_i64()).map(|ms| ms / 1000).unwrap_or(0);
                let name = PathBuf::from(&p)
                    .file_name()
                    .map(|n| n.to_string_lossy().to_string())
                    .unwrap_or_else(|| p.clone());
                if !p.is_empty() {
                    entries.push(VscodeEntry { path: p, name, kind: kind.into(), last_opened: ts });
                }
            }
        }

        entries
    }
}

/* ─── URI helpers ───────────────────────────────────────── */

/// Convert `file:///home/user/project` → `/home/user/project`.
fn uri_to_path(uri: &str) -> String {
    if let Some(path) = uri.strip_prefix("file://") {
        // URL-decode basic sequences
        let decoded = percent_decode(path);
        // Normalize leading slash on macOS/Linux
        if decoded.starts_with('/') { decoded } else { format!("/{decoded}") }
    } else if uri.starts_with('/') {
        uri.to_string()
    } else {
        String::new()
    }
}

fn percent_decode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut chars = s.bytes().peekable();
    while let Some(b) = chars.next() {
        if b == b'%' {
            let h1 = chars.next().unwrap_or(b'0');
            let h2 = chars.next().unwrap_or(b'0');
            if let Ok(decoded) = u8::from_str_radix(
                std::str::from_utf8(&[h1, h2]).unwrap_or("00"), 16
            ) {
                out.push(decoded as char);
                continue;
            }
        }
        out.push(b as char);
    }
    out
}

/* ─── Plugin impl ───────────────────────────────────────── */

#[async_trait]
impl Plugin for VscodePlugin {
    fn id(&self)   -> &str { "vscode" }
    fn name(&self) -> &str { "VS Code" }
    fn icon(&self) -> &str { "⬡" }

    async fn count(&self) -> u64 {
        let reader = match self.index.reader() {
            Ok(r) => r,
            Err(_) => return 0,
        };
        reader.searcher().num_docs()
    }

    async fn sync(&self) -> Result<usize> {
        let data_dirs = Self::vscode_data_dirs();
        let mut all_entries: Vec<VscodeEntry> = Vec::new();

        for dir in &data_dirs {
            let storage = dir.join("storage.json");
            let mut entries = Self::parse_storage(&storage);
            // Mark where these came from
            let app_name = dir.file_name()
                .map(|n| n.to_string_lossy().to_string())
                .unwrap_or_default();
            for e in &mut entries {
                if e.kind == "workspace" {
                    e.kind = format!("workspace:{app_name}");
                }
            }
            all_entries.extend(entries);
        }

        // Dedup by path
        all_entries.sort_unstable_by(|a, b| b.last_opened.cmp(&a.last_opened));
        all_entries.dedup_by(|a, b| a.path == b.path);

        // Filter to paths that still exist on disk
        all_entries.retain(|e| {
            let p = PathBuf::from(&e.path);
            p.exists()
        });

        let count = all_entries.len();

        // Batch write to Tantivy
        {
            let mut writer = self.writer.lock().await;
            // Clear + reindex (small collection)
            writer.delete_all_documents()?;
            for e in &all_entries {
                let kind_base = e.kind.split(':').next().unwrap_or(&e.kind);
                let _ = writer.add_document(doc!(
                    self.fields.name => e.name.as_str(),
                    self.fields.path => e.path.as_str(),
                    self.fields.kind => kind_base,
                    self.fields.ts   => e.last_opened.max(0) as u64,
                ));
            }
            writer.commit()?;
        }

        tracing::info!("VS Code: indexed {count} recently opened items");
        Ok(count)
    }

    async fn search(&self, query: &SearchQuery) -> Result<Vec<SearchResult>> {
        let q = &query.raw;
        if q.trim().is_empty() { return Ok(vec![]); }

        let reader   = self.index.reader()?;
        let searcher = reader.searcher();
        let qp = QueryParser::for_index(&self.index, vec![
            self.fields.name,
            self.fields.path,
        ]);
        let tq = qp.parse_query_lenient(q).0;
        let top = searcher.search(&tq, &TopDocs::with_limit(15))?;

        let fields = &self.fields;
        let mut results: Vec<SearchResult> = top.iter().map(|(score, addr)| {
            let doc: TantivyDocument = searcher.doc(*addr).unwrap_or_default();
            let name = doc.get_first(fields.name).and_then(|v| v.as_str()).unwrap_or("").to_string();
            let path = doc.get_first(fields.path).and_then(|v| v.as_str()).unwrap_or("").to_string();
            let kind = doc.get_first(fields.kind).and_then(|v| v.as_str()).unwrap_or("").to_string();
            let ts   = doc.get_first(fields.ts).and_then(|v| v.as_u64()).map(|t| t as i64).unwrap_or(0);

            to_search_result(&name, &path, &kind, *score, ts)
        }).collect();

        // Fuzzy fallback
        if results.is_empty() {
            let all_top = searcher.search(&tantivy::query::AllQuery, &TopDocs::with_limit(200))?;
            let matcher = &self.matcher;
            let mut fuzzy: Vec<(i64, TantivyDocument)> = all_top.iter()
                .filter_map(|(_, addr)| searcher.doc::<TantivyDocument>(*addr).ok())
                .filter_map(|doc: TantivyDocument| {
                    let name = doc.get_first(fields.name).and_then(|v| v.as_str()).unwrap_or("");
                    let path = doc.get_first(fields.path).and_then(|v| v.as_str()).unwrap_or("");
                    let hay  = format!("{name} {path}");
                    matcher.fuzzy_match(&hay, q).map(|s| (s, doc))
                })
                .collect();
            fuzzy.sort_unstable_by(|a, b| b.0.cmp(&a.0));
            fuzzy.truncate(15);
            results = fuzzy.into_iter().map(|(score, doc)| {
                let name = doc.get_first(fields.name).and_then(|v| v.as_str()).unwrap_or("").to_string();
                let path = doc.get_first(fields.path).and_then(|v| v.as_str()).unwrap_or("").to_string();
                let kind = doc.get_first(fields.kind).and_then(|v| v.as_str()).unwrap_or("").to_string();
                let ts   = doc.get_first(fields.ts).and_then(|v| v.as_u64()).map(|t| t as i64).unwrap_or(0);
                to_search_result(&name, &path, &kind, score as f32 / 300.0, ts)
            }).collect();
        }

        Ok(results)
    }

    async fn execute(&self, result: &SearchResult) -> Result<()> {
        if let Some(path) = &result.path {
            // Open in VS Code / Cursor
            let opened = std::process::Command::new("code").arg(path).spawn().is_ok()
                || std::process::Command::new("cursor").arg(path).spawn().is_ok()
                || std::process::Command::new("codium").arg(path).spawn().is_ok();
            if !opened {
                opener::open(path)?;
            }
        }
        Ok(())
    }
}

fn to_search_result(name: &str, path: &str, kind: &str, score: f32, ts: i64) -> SearchResult {
    let icon = match kind {
        "file"      => "📄",
        "workspace" => "📁",
        _           => "⬡",
    };
    let dir = PathBuf::from(path).parent()
        .map(|p| p.to_string_lossy().to_string())
        .unwrap_or_default();

    let mut r = SearchResult::new("vscode", format!("{icon} {name}"));
    r.id          = format!("vscode:{path}");
    r.source_type = SourceType::File;
    r.subtitle    = Some(dir);
    r.path        = Some(path.to_string());
    r.score       = score.min(0.99);
    r.action      = ResultAction::Open;
    r.timestamp   = DateTime::from_timestamp(ts, 0).map(|dt| dt.with_timezone(&Utc));
    r.metadata.insert("kind".into(), kind.into());
    r
}
