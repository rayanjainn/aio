use anyhow::Result;
use async_trait::async_trait;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::{collections::HashMap, sync::Arc};

/* ─── How a result is executed ──────────────────────────── */

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum ResultAction {
    Open,
    Run,
    Copy,
    Reveal,
    Preview,
}

/// Discriminant used by `execute_result` to choose the right executor.
///
/// The actual payload (path / url / command / sha) lives in `SearchResult`
/// fields and `metadata` — `SourceType` just names the dispatch branch.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum SourceType {
    /// Local filesystem path → open with OS default app via `opener`.
    File,
    /// HTTP/S URL → open in default browser via `webbrowser`.
    Url,
    /// Shell command string → run in a visible terminal window.
    ShellCommand,
    /// Git commit SHA + optional repo path → `git show` in terminal.
    GitCommit,
    /// Clipboard snippet → write back to clipboard via `arboard`.
    ClipboardText,
    /// Catch-all; executor falls back to opener on `path`, browser on `url`.
    Unknown,
}

/* ─── A single federated search result ─────────────────── */

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SearchResult {
    pub id:          String,
    pub plugin_id:   String,
    pub source_type: SourceType,
    pub title:       String,
    pub subtitle:    Option<String>,
    pub content:     Option<String>,
    pub path:        Option<String>,
    pub url:         Option<String>,
    pub timestamp:   Option<DateTime<Utc>>,
    pub session_id:  Option<String>,
    pub score:       f32,
    pub action:      ResultAction,
    pub metadata:    HashMap<String, serde_json::Value>,
}

impl SearchResult {
    pub fn new(plugin_id: impl Into<String>, title: impl Into<String>) -> Self {
        Self {
            id:          uuid::Uuid::new_v4().to_string(),
            plugin_id:   plugin_id.into(),
            source_type: SourceType::Unknown,
            title:       title.into(),
            subtitle:    None,
            content:     None,
            path:        None,
            url:         None,
            timestamp:   None,
            session_id:  None,
            score:       0.5,
            action:      ResultAction::Open,
            metadata:    HashMap::new(),
        }
    }
}

/* ─── Query parsed from NL input ───────────────────────── */

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SearchQuery {
    pub raw:            String,
    pub terms:          Vec<String>,
    pub temporal:       Option<TemporalFilter>,
    pub source_filter:  Option<Vec<String>>,
    pub intent:         QueryIntent,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum QueryIntent {
    Retrieval,
    Execution,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TemporalFilter {
    pub after:  Option<DateTime<Utc>>,
    pub before: Option<DateTime<Utc>>,
    pub label:  String, // "last Tuesday", "2am last month"
}

/* ─── Plugin trait ──────────────────────────────────────── */

#[async_trait]
pub trait Plugin: Send + Sync {
    fn id(&self)   -> &str;
    fn name(&self) -> &str;
    fn icon(&self) -> &str;

    /// Pull new data from the source into local index.
    async fn sync(&self) -> Result<usize>;

    /// Total items currently in this plugin's index.
    /// Used by `get_daemon_status` — should be fast (no heavy I/O).
    async fn count(&self) -> u64 { 0 }

    /// Return ranked results for the given query.
    async fn search(&self, query: &SearchQuery) -> Result<Vec<SearchResult>>;

    /// Execute an action on a result (open file, run command, copy, etc.)
    async fn execute(&self, result: &SearchResult) -> Result<()>;
}

/* ─── Plugin registry ───────────────────────────────────── */

pub struct PluginRegistry {
    plugins: Vec<Arc<dyn Plugin>>,
}

impl PluginRegistry {
    pub fn new() -> Self {
        Self { plugins: Vec::new() }
    }

    /// Register a plugin. Pass `Arc::new(plugin)` so the caller can keep
    /// a typed clone for background tasks (watcher, WS server, etc.).
    pub fn register(&mut self, plugin: Arc<dyn Plugin>) {
        self.plugins.push(plugin);
    }

    pub fn get(&self, id: &str) -> Option<&dyn Plugin> {
        self.plugins.iter().find(|p| p.id() == id).map(|p| p.as_ref())
    }

    pub fn all(&self) -> &[Arc<dyn Plugin>] {
        &self.plugins
    }

    /// Fan-out search across all plugins, collecting results in parallel.
    pub async fn search_all(&self, query: &SearchQuery) -> Vec<SearchResult> {
        use futures::future::join_all;

        // Honor source_filter: when set (and non-empty), only the named plugins
        // run. Lets a scoped "browse" (empty query + one source) hit just that
        // plugin instead of fanning out to all.
        let filter = query.source_filter.as_ref().filter(|f| !f.is_empty());
        let futs: Vec<_> = self.plugins
            .iter()
            .filter(|p| filter.map_or(true, |f| f.iter().any(|s| s == p.id())))
            .map(|p| p.search(query))
            .collect();

        let results = join_all(futs).await;
        results.into_iter()
            .filter_map(|r| r.ok())
            .flatten()
            .collect()
    }

    /// Read live item counts from every plugin — fast, no sync triggered.
    pub async fn count_all(&self) -> HashMap<String, u64> {
        use futures::future::join_all;

        let futs: Vec<_> = self.plugins
            .iter()
            .map(|p| async move { (p.id().to_string(), p.count().await) })
            .collect();

        join_all(futs).await.into_iter().collect()
    }

    pub async fn sync_all(&self) -> HashMap<String, usize> {
        use futures::future::join_all;

        let futs: Vec<_> = self.plugins
            .iter()
            .map(|p| async move { (p.id().to_string(), p.sync().await) })
            .collect();

        join_all(futs)
            .await
            .into_iter()
            .map(|(id, r)| (id, r.unwrap_or(0)))
            .collect()
    }
}
