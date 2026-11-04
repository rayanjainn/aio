/// Files plugin — Tantivy full-text index of local filesystem.
///
/// Sync:    uses `ignore` crate (respects .gitignore) to walk configured roots.
///          All FS I/O runs in `spawn_blocking`; writes are batched behind an
///          `Arc<Mutex<IndexWriter>>` so the incremental watcher can share it.
///
/// Watcher: `WatcherContext` is a cheap handle extracted before the plugin is
///          moved into the registry.  `start_file_watcher` spawns a tokio task
///          that uses `notify` + 500 ms debouncing to upsert/delete docs
///          incrementally without a full re-sync.

use anyhow::Result;
use async_trait::async_trait;
use chrono::{DateTime, Utc};
use fuzzy_matcher::{skim::SkimMatcherV2, FuzzyMatcher};
use ignore::WalkBuilder;
use notify::{EventKind, RecommendedWatcher, RecursiveMode, Watcher};
use std::{
    collections::HashSet,
    path::{Path, PathBuf},
    sync::Arc,
    time::{Duration, UNIX_EPOCH},
};
use tantivy::{
    collector::TopDocs,
    doc,
    query::QueryParser,
    schema::{Field, Schema, Value, FAST, STORED, TEXT},
    Index, IndexWriter, TantivyDocument, Term,
};
use tokio::sync::{mpsc, Mutex};

use crate::plugin::{Plugin, ResultAction, SearchQuery, SearchResult, SourceType};

/* ─── Constants ─────────────────────────────────────────── */

const MAX_FILE_BYTES: u64 = 2 * 1024 * 1024; // 2 MB (body read cap)
const WATCHER_DEBOUNCE: Duration = Duration::from_millis(500);
const WATCHER_CHAN_CAP: usize = 8_192;

/// Directory names pruned from the walk entirely — never descended into.
/// These dominate file counts and are noise for search.
const IGNORED_DIRS: &[&str] = &[
    "node_modules", ".git", ".next", ".nuxt", ".svelte-kit", ".turbo",
    "dist", "build", "out", "target", "bin", "obj", "coverage",
    ".cache", ".parcel-cache", ".venv", "venv", "env", "__pycache__",
    "vendor", "Pods", "DerivedData", ".gradle", ".terraform",
    ".idea", ".vscode", ".pytest_cache", ".mypy_cache", "bower_components",
    ".cargo", ".rustup", "Library", ".npm", ".pnpm-store", ".yarn",
];

/// True if this directory entry is an ignored build/dep dir → prune it.
fn is_pruned_dir(entry: &ignore::DirEntry) -> bool {
    if entry.file_type().map(|t| t.is_dir()).unwrap_or(false) {
        if let Some(name) = entry.file_name().to_str() {
            return IGNORED_DIRS.contains(&name);
        }
    }
    false
}

/* ─── Shared writer handle ──────────────────────────────── */

/// Cloneable context extracted from `FilesPlugin` before it moves into the
/// registry.  Holds the shared writer + field descriptors needed to upsert /
/// delete individual documents without touching the plugin instance.
pub struct WatcherContext {
    pub writer:      Arc<Mutex<IndexWriter>>,
    pub field_title: Field,
    pub field_path:  Field,
    pub field_body:  Field,
    pub field_mtime: Field,
    pub roots:       Vec<PathBuf>,
}

/* ─── Plugin struct ─────────────────────────────────────── */

pub struct FilesPlugin {
    index:       Index,
    writer:      Arc<Mutex<IndexWriter>>,
    field_title: Field,
    field_path:  Field,
    field_body:  Field,
    field_mtime: Field,
    roots:       Vec<PathBuf>,
    matcher:     SkimMatcherV2,
}

impl FilesPlugin {
    pub fn new(index_dir: PathBuf, roots: Vec<PathBuf>) -> Result<Self> {
        let mut sb = Schema::builder();
        let field_title = sb.add_text_field("title", TEXT | STORED);
        let field_path  = sb.add_text_field("path",  TEXT | STORED);
        let field_body  = sb.add_text_field("body",  TEXT);
        let field_mtime = sb.add_u64_field("mtime",  FAST | STORED);
        let schema      = sb.build();

        std::fs::create_dir_all(&index_dir)?;
        let index = if index_dir.join("meta.json").exists() {
            Index::open_in_dir(&index_dir)?
        } else {
            Index::create_in_dir(&index_dir, schema)?
        };
        let writer = index.writer(50_000_000)?; // 50 MB write buffer

        Ok(Self {
            index,
            writer: Arc::new(Mutex::new(writer)),
            field_title,
            field_path,
            field_body,
            field_mtime,
            roots,
            matcher: SkimMatcherV2::default(),
        })
    }

    /// Cheap handle for the background watcher task.
    /// Call this BEFORE moving `FilesPlugin` into the registry.
    pub fn watcher_context(&self) -> WatcherContext {
        WatcherContext {
            writer:      self.writer.clone(),
            field_title: self.field_title,
            field_path:  self.field_path,
            field_body:  self.field_body,
            field_mtime: self.field_mtime,
            roots:       self.roots.clone(),
        }
    }

    /* ── Helpers ─────────────────────────────────────────── */

    /// Whether to read the file body into the index (text/code only).
    /// Non-text files are still indexed by name + path (just no body).
    #[allow(dead_code)] // kept for an opt-in content-search toggle
    fn is_text_file(path: &Path) -> bool {
        matches!(
            path.extension().and_then(|e| e.to_str()).unwrap_or("").to_lowercase().as_str(),
            "rs" | "ts" | "tsx" | "js" | "jsx" | "py" | "go" | "java" | "c"
                | "cpp" | "h" | "hpp" | "md" | "mdx" | "txt" | "toml" | "yaml" | "yml" | "json"
                | "sh" | "bash" | "zsh" | "fish" | "env" | "conf" | "config"
                | "ini" | "sql" | "graphql" | "proto" | "css" | "scss" | "html"
                | "xml" | "svg" | "vue" | "svelte" | "rb" | "kt" | "swift"
                | "dart" | "lua" | "r" | "ex" | "exs" | "clj" | "tf" | "hcl"
                | "nix" | "vim" | "el" | "hs" | "ml" | "cs" | "makefile"
                | "dockerfile" | "lock" | "csv" | "log" | "rst" | "tex"
        )
    }

    /// Read a capped prefix of text-file bodies for the index. Capping keeps the
    /// Tantivy index small (was storing whole 2 MB files → hundreds of MB total);
    /// the first ~32 KB carries imports/headers/keywords that matter for search,
    /// and whole-file name search is covered by Spotlight anyway.
    #[allow(dead_code)] // content indexing disabled — see body=String::new() above
    fn read_body(path: &Path, size: u64) -> String {
        const BODY_CAP: usize = 32 * 1024; // 32 KB indexed per file
        if Self::is_text_file(path) && size <= MAX_FILE_BYTES {
            match std::fs::read(path) {
                Ok(bytes) => {
                    let end = bytes.len().min(BODY_CAP);
                    String::from_utf8_lossy(&bytes[..end]).into_owned()
                }
                Err(_) => String::new(),
            }
        } else {
            String::new()
        }
    }

    /// Upsert a single file into the shared index writer.
    /// Deletes any existing doc for `path` first (by term), then adds the new one.
    pub async fn upsert_file(ctx: &WatcherContext, path: &Path) -> Result<bool> {
        if !path.is_file() { return Ok(false); }
        // Skip files living inside any pruned dir.
        if path.components().any(|c| c.as_os_str().to_str().map(|n| IGNORED_DIRS.contains(&n)).unwrap_or(false)) {
            return Ok(false);
        }

        let meta = match path.metadata() {
            Ok(m) => m,
            Err(_) => return Ok(false),
        };

        let mtime = meta.modified()
            .ok()
            .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
            .map(|d| d.as_secs())
            .unwrap_or(0);
        let title    = path.file_name().unwrap_or_default().to_string_lossy().to_string();
        let path_str = path.to_string_lossy().to_string();
        // Content indexing disabled: indexing file bodies across all of $HOME
        // bloated ~/.cortex to 12GB. The UI searches files by name/path via
        // spotlight_search/list_dir, so filename+path is all we need here.
        let body     = String::new();

        let mut w = ctx.writer.lock().await;
        w.delete_term(Term::from_field_text(ctx.field_path, &path_str));
        w.add_document(doc!(
            ctx.field_title => title,
            ctx.field_path  => path_str,
            ctx.field_body  => body,
            ctx.field_mtime => mtime,
        ))?;
        w.commit()?;
        Ok(true)
    }

    /// Delete a document by path term.
    pub async fn remove_file(ctx: &WatcherContext, path_str: &str) -> Result<()> {
        let mut w = ctx.writer.lock().await;
        w.delete_term(Term::from_field_text(ctx.field_path, path_str));
        w.commit()?;
        Ok(())
    }
}

/* ─── Plugin impl ───────────────────────────────────────── */

#[async_trait]
impl Plugin for FilesPlugin {
    fn id(&self)   -> &str { "files" }
    fn name(&self) -> &str { "Files" }
    fn icon(&self) -> &str { "📄" }

    async fn count(&self) -> u64 {
        self.index
            .reader()
            .ok()
            .map(|r| r.searcher().num_docs())
            .unwrap_or(0)
    }

    async fn sync(&self) -> Result<usize> {
        let roots = self.roots.clone();

        // Collect all indexable files on the blocking thread pool.
        type Doc = (String, String, String, u64); // (title, path, body, mtime)
        let docs: Vec<Doc> = tokio::task::spawn_blocking(move || {
            let mut out = Vec::new();
            for root in &roots {
                tracing::debug!(target: "aio_cortex_lib", "files: walking {}", root.display());
                for entry in WalkBuilder::new(root)
                    .hidden(true)       // skip dotfiles
                    .git_ignore(true)   // respect .gitignore
                    .git_global(true)   // respect global gitignore
                    .git_exclude(true)  // respect .git/info/exclude
                    .follow_links(false)
                    .filter_entry(|e| !is_pruned_dir(e)) // prune node_modules/.git/etc
                    .build()
                    .filter_map(|e| e.ok())
                    .filter(|e| e.file_type().map(|ft| ft.is_file()).unwrap_or(false))
                {
                    let path = entry.path();
                    let Ok(meta) = path.metadata() else { continue };

                    let mtime = meta.modified()
                        .ok()
                        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
                        .map(|d| d.as_secs())
                        .unwrap_or(0);
                    let title    = path.file_name().unwrap_or_default().to_string_lossy().to_string();
                    let path_str = path.to_string_lossy().to_string();
                    // Filename+path only — content indexing disabled (kept the
                    // index from ballooning ~/.cortex to 12GB).
                    let body     = String::new();
                    out.push((title, path_str, body, mtime));
                }
            }
            out
        }).await?;

        let count = docs.len();
        tracing::info!(target: "aio_cortex_lib", "files: indexing {count} files from {} root(s)", self.roots.len());
        let mut w = self.writer.lock().await;
        for (title, path_str, body, mtime) in docs {
            w.delete_term(Term::from_field_text(self.field_path, &path_str));
            w.add_document(doc!(
                self.field_title => title,
                self.field_path  => path_str,
                self.field_body  => body,
                self.field_mtime => mtime,
            ))?;
        }
        w.commit()?;
        Ok(count)
    }

    async fn search(&self, query: &SearchQuery) -> Result<Vec<SearchResult>> {
        let reader   = self.index.reader()?;
        let searcher = reader.searcher();

        let qp = QueryParser::for_index(
            &self.index,
            vec![self.field_title, self.field_body, self.field_path],
        );

        let terms = query.terms.join(" ");
        if terms.is_empty() { return Ok(vec![]); }

        // parse_query_lenient never returns an error; falls back gracefully
        let (tantivy_q, _) = qp.parse_query_lenient(&terms);
        let top_docs        = searcher.search(&tantivy_q, &TopDocs::with_limit(50))?;

        let mut results = Vec::with_capacity(top_docs.len());
        for (score, addr) in top_docs {
            let doc: TantivyDocument = searcher.doc(addr)?;

            let get_str = |f: Field| -> String {
                doc.get_first(f).and_then(|v| v.as_str()).unwrap_or("").to_string()
            };
            let get_u64 = |f: Field| -> u64 {
                doc.get_first(f).and_then(|v| v.as_u64()).unwrap_or(0)
            };

            let title    = get_str(self.field_title);
            let path_str = get_str(self.field_path);
            let mtime    = get_u64(self.field_mtime);
            let ts       = (mtime > 0)
                .then(|| DateTime::from_timestamp(mtime as i64, 0))
                .flatten()
                .map(|dt| dt.with_timezone(&Utc));

            let mut r = SearchResult::new("files", &title);
            r.source_type = SourceType::File;
            r.subtitle    = Some(path_str.clone());
            r.path        = Some(path_str);
            r.score       = (score / 10.0).min(1.0);
            r.timestamp   = ts;
            r.action      = ResultAction::Open;
            results.push(r);
        }

        // Supplement with fuzzy filename match when BM25 results are thin
        if results.len() < 10 {
            let q = query.raw.as_str();
            for root in &self.roots {
                for entry in WalkBuilder::new(root)
                    .hidden(true).git_ignore(true).max_depth(Some(8))
                    .filter_entry(|e| !is_pruned_dir(e))
                    .build()
                    .filter_map(|e| e.ok())
                    .filter(|e| e.file_type().map(|ft| ft.is_file()).unwrap_or(false))
                    .take(20_000)
                {
                    let name = entry.file_name().to_string_lossy();
                    if let Some(s) = self.matcher.fuzzy_match(&name, q) {
                        if s > 40 {
                            let ps = entry.path().to_string_lossy().to_string();
                            let mut r = SearchResult::new("files", name.to_string());
                            r.source_type = SourceType::File;
                            r.subtitle    = Some(ps.clone());
                            r.path        = Some(ps);
                            r.score       = (s as f32 / 200.0).min(0.85);
                            r.action      = ResultAction::Open;
                            results.push(r);
                        }
                    }
                }
            }
        }

        results.sort_unstable_by(|a, b| b.score.partial_cmp(&a.score).unwrap_or(std::cmp::Ordering::Equal));
        results.dedup_by(|a, b| a.path == b.path);
        results.truncate(20);
        tracing::debug!(target: "aio_cortex_lib", "files: '{}' → {} results", query.raw, results.len());
        Ok(results)
    }

    async fn execute(&self, result: &SearchResult) -> Result<()> {
        if let Some(path) = &result.path { opener::open(path)?; }
        Ok(())
    }
}

/* ─── Background file watcher ───────────────────────────── */

/// Spawn a `notify` watcher that watches all roots recursively.
/// Events are debounced for `WATCHER_DEBOUNCE` (500 ms); each batch then
/// upserts modified files and removes deleted ones from the Tantivy index.
pub async fn start_file_watcher(ctx: WatcherContext) {
    let (tx, mut rx) = mpsc::channel::<notify::Event>(WATCHER_CHAN_CAP);

    let mut watcher: RecommendedWatcher = match notify::recommended_watcher(
        move |res: notify::Result<notify::Event>| {
            if let Ok(ev) = res {
                let _ = tx.blocking_send(ev);
            }
        },
    ) {
        Ok(w) => w,
        Err(e) => {
            tracing::error!("file watcher init: {e}");
            return;
        }
    };

    for root in &ctx.roots {
        if root.exists() {
            if let Err(e) = watcher.watch(root, RecursiveMode::Recursive) {
                tracing::warn!("watch {}: {e}", root.display());
            }
        }
    }
    tracing::info!(
        "file watcher started on {} root(s)",
        ctx.roots.len()
    );

    let mut pending_upsert: HashSet<PathBuf> = HashSet::new();
    let mut pending_remove: HashSet<PathBuf> = HashSet::new();

    loop {
        match tokio::time::timeout(WATCHER_DEBOUNCE, rx.recv()).await {
            Ok(Some(ev)) => {
                // Accumulate until the debounce window is idle
                match ev.kind {
                    EventKind::Create(_) | EventKind::Modify(_) => {
                        for p in ev.paths {
                            pending_remove.remove(&p); // cancel any pending remove
                            pending_upsert.insert(p);
                        }
                    }
                    EventKind::Remove(_) => {
                        for p in ev.paths {
                            pending_upsert.remove(&p);
                            pending_remove.insert(p);
                        }
                    }
                    _ => {}
                }
                continue; // go back and wait for more
            }
            Ok(None) => break, // channel closed — daemon is shutting down
            Err(_) => {
                // Debounce timeout expired → flush the batch
            }
        }

        if pending_upsert.is_empty() && pending_remove.is_empty() {
            continue;
        }

        let (nu, nr) = (pending_upsert.len(), pending_remove.len());
        tracing::debug!("watcher flush: {nu} upsert, {nr} remove");

        for path in pending_upsert.drain() {
            if let Err(e) = FilesPlugin::upsert_file(&ctx, &path).await {
                tracing::warn!("upsert {}: {e}", path.display());
            }
        }
        for path in pending_remove.drain() {
            let s = path.to_string_lossy().to_string();
            if let Err(e) = FilesPlugin::remove_file(&ctx, &s).await {
                tracing::warn!("remove {}: {e}", path.display());
            }
        }
    }

    tracing::info!("file watcher stopped");
    // `watcher` drop here unregisters all watches
}
