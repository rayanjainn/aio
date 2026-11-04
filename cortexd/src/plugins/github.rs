/// GitHub plugin — issues, pull requests, notifications via REST API.
///
/// Auth: GITHUB_TOKEN env var or ~/.cortex/config.env
/// SQLite: ~/.cortex/github/items.db
/// Qdrant: cortex_github (title + body embedding)
/// Sync: startup + every 30 minutes (periodic task in lib.rs)

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

use crate::{
    embed::VectorStore,
    plugin::{Plugin, ResultAction, SearchQuery, SearchResult, SourceType},
};

const GH_API: &str = "https://api.github.com";

/* ─── Data types ────────────────────────────────────────── */

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GithubItem {
    pub item_id:      String,
    pub kind:         String, // "issue" | "pr" | "notification"
    pub title:        String,
    pub body:         String,
    pub url:          String,
    pub repo:         String,
    pub state:        String,
    pub updated_unix: i64,
    pub labels:       Vec<String>,
    pub number:       Option<u64>,
}

/* ─── Plugin ────────────────────────────────────────────── */

pub struct GithubPlugin {
    db_path: PathBuf,
    cache:   RwLock<Vec<GithubItem>>,
    matcher: SkimMatcherV2,
    token:   Option<String>,
    vs:      VectorStore,
    http:    reqwest::Client,
}

impl GithubPlugin {
    pub fn new(data_dir: PathBuf) -> Result<Self> {
        std::fs::create_dir_all(&data_dir)?;
        let db_path = data_dir.join("items.db");
        Self::init_db(&db_path)?;
        load_cortex_env();
        let token = crate::auth::github_token();
        if token.is_some() { tracing::info!(target: "aio_cortex_lib", "github: token loaded"); }
        Ok(Self {
            db_path,
            cache:   RwLock::new(vec![]),
            matcher: SkimMatcherV2::default(),
            token,
            vs:      VectorStore::new(),
            http:    reqwest::Client::builder()
                .user_agent("cortex-aio/0.1")
                .timeout(Duration::from_secs(30))
                .build()?,
        })
    }

    fn init_db(path: &PathBuf) -> Result<()> {
        let conn = Connection::open(path)?;
        conn.execute_batch("
            CREATE TABLE IF NOT EXISTS items (
                item_id      TEXT PRIMARY KEY,
                kind         TEXT NOT NULL,
                title        TEXT NOT NULL,
                body         TEXT NOT NULL DEFAULT '',
                url          TEXT NOT NULL DEFAULT '',
                repo         TEXT NOT NULL DEFAULT '',
                state        TEXT NOT NULL DEFAULT '',
                updated_unix INTEGER NOT NULL DEFAULT 0,
                labels_json  TEXT NOT NULL DEFAULT '[]',
                number       INTEGER
            );
            CREATE INDEX IF NOT EXISTS items_updated ON items(updated_unix DESC);
            CREATE INDEX IF NOT EXISTS items_kind    ON items(kind);
        ")?;
        Ok(())
    }

    fn db(&self) -> Result<Connection> {
        Connection::open(&self.db_path).context("github db")
    }

    fn load_cache(&self) -> Result<()> {
        let conn = self.db()?;
        let mut stmt = conn.prepare(
            "SELECT item_id, kind, title, body, url, repo, state, updated_unix, labels_json, number \
             FROM items ORDER BY updated_unix DESC LIMIT 2000"
        )?;
        let items: Vec<GithubItem> = stmt.query_map([], |row| {
            let labels: Vec<String> = row.get::<_, String>(8)
                .ok()
                .and_then(|s| serde_json::from_str(&s).ok())
                .unwrap_or_default();
            Ok(GithubItem {
                item_id:      row.get(0)?,
                kind:         row.get(1)?,
                title:        row.get(2)?,
                body:         row.get(3)?,
                url:          row.get(4)?,
                repo:         row.get(5)?,
                state:        row.get(6)?,
                updated_unix: row.get(7)?,
                labels,
                number:       row.get(9)?,
            })
        })?.filter_map(|r| r.ok()).collect();

        *self.cache.write().unwrap() = items;
        Ok(())
    }

    fn auth_header(&self) -> Option<String> {
        self.token.as_ref().map(|t| format!("Bearer {t}"))
    }

    /* ── Issues ──────────────────────────────────────────── */

    async fn sync_issues(&self) -> Result<usize> {
        let auth = match self.auth_header() {
            Some(a) => a,
            None => return Ok(0),
        };

        #[derive(Deserialize)]
        struct Issue {
            id:         u64,
            number:     u64,
            title:      String,
            body:       Option<String>,
            html_url:   String,
            state:      String,
            updated_at: String,
            labels:     Vec<Label>,
            repository: Option<Repo>,
            pull_request: Option<serde_json::Value>, // present on PRs in issues list
        }
        #[derive(Deserialize)]
        struct Label { name: String }
        #[derive(Deserialize)]
        struct Repo { full_name: String }

        let mut page = 1u32;
        let mut new_count = 0usize;
        let conn = self.db()?;

        loop {
            let resp: Vec<Issue> = self.http
                .get(format!("{GH_API}/issues"))
                .header("Authorization", &auth)
                .header("Accept", "application/vnd.github+json")
                .query(&[
                    ("state", "all"),
                    ("filter", "assigned"),
                    ("per_page", "100"),
                    ("page", &page.to_string()),
                ])
                .send().await?
                .json().await?;

            if resp.is_empty() { break; }

            for issue in &resp {
                // Skip PRs (they appear in issues endpoint too)
                if issue.pull_request.is_some() { continue; }

                let item_id = format!("issue:{}", issue.id);
                let repo    = issue.repository.as_ref()
                    .map(|r| r.full_name.clone())
                    .unwrap_or_default();
                let body    = issue.body.clone().unwrap_or_default()
                    .chars().take(500).collect::<String>();
                let labels: Vec<String> = issue.labels.iter().map(|l| l.name.clone()).collect();
                let labels_json = serde_json::to_string(&labels)?;
                let updated_unix = chrono::DateTime::parse_from_rfc3339(&issue.updated_at)
                    .map(|dt| dt.timestamp()).unwrap_or(0);

                conn.execute(
                    "INSERT OR REPLACE INTO items \
                     (item_id, kind, title, body, url, repo, state, updated_unix, labels_json, number) \
                     VALUES (?1, 'issue', ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
                    params![item_id, issue.title, body, issue.html_url, repo,
                            issue.state, updated_unix, labels_json, issue.number as i64],
                )?;

                let embed_text = format!("{} {body}", issue.title);
                let mid = item_id.clone();
                let vs = self.vs.clone();
                let payload = serde_json::json!({ "id": mid, "kind": "issue" });
                tokio::spawn(async move {
                    vs.index("cortex_github", &mid, &embed_text, payload).await;
                });
                new_count += 1;
            }

            if resp.len() < 100 { break; }
            page += 1;
        }

        tracing::info!("GitHub issues: {new_count} synced");
        Ok(new_count)
    }

    /* ── Pull requests ───────────────────────────────────── */

    async fn sync_prs(&self) -> Result<usize> {
        let auth = match self.auth_header() {
            Some(a) => a,
            None => return Ok(0),
        };

        #[derive(Deserialize)]
        struct PR {
            id:         u64,
            number:     u64,
            title:      String,
            body:       Option<String>,
            html_url:   String,
            state:      String,
            updated_at: String,
            labels:     Vec<GhLabel>,
            base:       PrBase,
        }
        #[derive(Deserialize)]
        struct PrBase { repo: PrRepo }
        #[derive(Deserialize)]
        struct PrRepo { full_name: String }
        #[derive(Deserialize)]
        struct GhLabel { name: String }

        // Search for PRs involving the authenticated user
        #[derive(Deserialize)]
        struct SearchResp {
            items: Vec<PR>,
        }

        let resp: SearchResp = self.http
            .get(format!("{GH_API}/search/issues"))
            .header("Authorization", &auth)
            .header("Accept", "application/vnd.github+json")
            .query(&[
                ("q", "is:pr involves:@me"),
                ("per_page", "100"),
                ("sort", "updated"),
            ])
            .send().await?
            .json().await?;

        let conn = self.db()?;
        let mut new_count = 0usize;

        for pr in &resp.items {
            let item_id = format!("pr:{}", pr.id);
            let repo    = pr.base.repo.full_name.clone();
            let body    = pr.body.clone().unwrap_or_default()
                .chars().take(500).collect::<String>();
            let labels: Vec<String> = pr.labels.iter().map(|l| l.name.clone()).collect();
            let labels_json = serde_json::to_string(&labels)?;
            let updated_unix = chrono::DateTime::parse_from_rfc3339(&pr.updated_at)
                .map(|dt| dt.timestamp()).unwrap_or(0);

            conn.execute(
                "INSERT OR REPLACE INTO items \
                 (item_id, kind, title, body, url, repo, state, updated_unix, labels_json, number) \
                 VALUES (?1, 'pr', ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
                params![item_id, pr.title, body, pr.html_url, repo,
                        pr.state, updated_unix, labels_json, pr.number as i64],
            )?;

            let embed_text = format!("{} {body}", pr.title);
            let mid = item_id.clone();
            let vs = self.vs.clone();
            let payload = serde_json::json!({ "id": mid, "kind": "pr" });
            tokio::spawn(async move {
                vs.index("cortex_github", &mid, &embed_text, payload).await;
            });
            new_count += 1;
        }

        tracing::info!("GitHub PRs: {new_count} synced");
        Ok(new_count)
    }

    /* ── Notifications ───────────────────────────────────── */

    async fn sync_notifications(&self) -> Result<usize> {
        let auth = match self.auth_header() {
            Some(a) => a,
            None => return Ok(0),
        };

        #[derive(Deserialize)]
        struct Notif {
            id:         String,
            subject:    NotifSubject,
            repository: NotifRepo,
            updated_at: String,
            reason:     String,
        }
        #[derive(Deserialize)]
        struct NotifSubject { title: String, url: Option<String>, #[serde(rename="type")] typ: String }
        #[derive(Deserialize)]
        struct NotifRepo { full_name: String }

        let resp: Vec<Notif> = self.http
            .get(format!("{GH_API}/notifications"))
            .header("Authorization", &auth)
            .header("Accept", "application/vnd.github+json")
            .query(&[("all", "true"), ("per_page", "50")])
            .send().await?
            .json().await?;

        let conn = self.db()?;
        let mut new_count = 0usize;

        for notif in &resp {
            let item_id = format!("notif:{}", notif.id);
            let url = notif.subject.url.clone()
                .unwrap_or_default()
                .replace("api.github.com/repos", "github.com")
                .replace("/pulls/", "/pull/")
                .replace("/issues/", "/issues/");
            let updated_unix = chrono::DateTime::parse_from_rfc3339(&notif.updated_at)
                .map(|dt| dt.timestamp()).unwrap_or(0);

            let body = format!("{} · {}", notif.reason, notif.subject.typ);

            conn.execute(
                "INSERT OR REPLACE INTO items \
                 (item_id, kind, title, body, url, repo, state, updated_unix) \
                 VALUES (?1, 'notification', ?2, ?3, ?4, ?5, 'unread', ?6)",
                params![item_id, notif.subject.title, body, url,
                        notif.repository.full_name, updated_unix],
            )?;

            let embed_text = notif.subject.title.clone();
            let mid = item_id.clone();
            let vs = self.vs.clone();
            let payload = serde_json::json!({ "id": mid, "kind": "notification" });
            tokio::spawn(async move {
                vs.index("cortex_github", &mid, &embed_text, payload).await;
            });
            new_count += 1;
        }

        tracing::info!("GitHub notifications: {new_count} synced");
        Ok(new_count)
    }

    /* ── Repositories (your "projects") ──────────────────── */

    async fn sync_repos(&self) -> Result<usize> {
        let auth = match self.auth_header() { Some(a) => a, None => return Ok(0) };

        #[derive(Deserialize)]
        struct RepoItem {
            id: u64, name: String, full_name: String, html_url: String,
            description: Option<String>, updated_at: String,
            language: Option<String>, stargazers_count: Option<u64>, private: bool,
            fork: bool,
        }

        let mut page = 1u32; let mut new_count = 0usize;
        let conn = self.db()?;
        loop {
            let resp: Vec<RepoItem> = self.http
                .get(format!("{GH_API}/user/repos"))
                .header("Authorization", &auth)
                .header("Accept", "application/vnd.github+json")
                .query(&[("per_page", "100"), ("sort", "updated"),
                         ("affiliation", "owner,collaborator,organization_member"),
                         ("page", &page.to_string())])
                .send().await?
                .json().await?;
            if resp.is_empty() { break; }

            for r in &resp {
                let item_id = format!("repo:{}", r.id);
                let body = r.description.clone().unwrap_or_default();
                let mut tags = vec![];
                if let Some(l) = &r.language { tags.push(l.clone()); }
                if r.private { tags.push("private".into()); }
                if r.fork { tags.push("fork".into()); }
                let labels_json = serde_json::to_string(&tags)?;
                let updated_unix = chrono::DateTime::parse_from_rfc3339(&r.updated_at).map(|d| d.timestamp()).unwrap_or(0);
                let state = format!("★{}", r.stargazers_count.unwrap_or(0));

                conn.execute(
                    "INSERT OR REPLACE INTO items (item_id, kind, title, body, url, repo, state, updated_unix, labels_json, number) \
                     VALUES (?1, 'repo', ?2, ?3, ?4, ?5, ?6, ?7, ?8, NULL)",
                    params![item_id, r.name, body, r.html_url, r.full_name, state, updated_unix, labels_json],
                )?;

                let embed_text = format!("{} {} {body}", r.name, r.full_name);
                let mid = item_id.clone(); let vs = self.vs.clone();
                let payload = serde_json::json!({ "id": mid, "kind": "repo" });
                tokio::spawn(async move { vs.index("cortex_github", &mid, &embed_text, payload).await; });
                new_count += 1;
            }
            if resp.len() < 100 { break; }
            page += 1;
        }
        tracing::info!(target: "aio_cortex_lib", "GitHub repos: {new_count} synced");
        Ok(new_count)
    }

    /* ── Recent commits across your active repos ─────────── */

    async fn sync_commits(&self) -> Result<usize> {
        let auth = match self.auth_header() { Some(a) => a, None => return Ok(0) };

        // Who am I? (filter commits to the user's own).
        #[derive(Deserialize)] struct Me { login: String }
        let login = self.http.get(format!("{GH_API}/user"))
            .header("Authorization", &auth).header("Accept", "application/vnd.github+json")
            .send().await?.json::<Me>().await.map(|m| m.login).unwrap_or_default();

        // Most-recently-pushed repos.
        #[derive(Deserialize)] struct R { full_name: String }
        let repos: Vec<R> = self.http.get(format!("{GH_API}/user/repos"))
            .header("Authorization", &auth).header("Accept", "application/vnd.github+json")
            .query(&[("per_page", "10"), ("sort", "pushed"), ("affiliation", "owner,collaborator")])
            .send().await?.json().await.unwrap_or_default();

        #[derive(Deserialize)] struct Commit { sha: String, html_url: String, commit: CommitData }
        #[derive(Deserialize)] struct CommitData { message: String, author: Option<CommitAuthor> }
        #[derive(Deserialize)] struct CommitAuthor { date: String }

        let conn = self.db()?;
        let mut n = 0usize;
        for repo in repos.iter().take(10) {
            let url = format!("{GH_API}/repos/{}/commits", repo.full_name);
            let mut req = self.http.get(&url)
                .header("Authorization", &auth).header("Accept", "application/vnd.github+json")
                .query(&[("per_page", "8")]);
            if !login.is_empty() { req = req.query(&[("author", login.as_str())]); }
            let commits: Vec<Commit> = match req.send().await { Ok(r) => r.json().await.unwrap_or_default(), Err(_) => continue };

            for c in commits {
                let item_id = format!("commit:{}", c.sha);
                let title: String = c.commit.message.lines().next().unwrap_or("").chars().take(120).collect();
                let updated_unix = c.commit.author.as_ref()
                    .and_then(|a| chrono::DateTime::parse_from_rfc3339(&a.date).ok())
                    .map(|d| d.timestamp()).unwrap_or(0);
                conn.execute(
                    "INSERT OR REPLACE INTO items (item_id, kind, title, body, url, repo, state, updated_unix, labels_json, number) \
                     VALUES (?1, 'commit', ?2, ?3, ?4, ?5, ?6, ?7, '[]', NULL)",
                    params![item_id, title, c.commit.message, c.html_url, repo.full_name, &c.sha[..c.sha.len().min(7)], updated_unix],
                )?;
                let mid = item_id.clone(); let vs = self.vs.clone();
                let etext = format!("{title} {}", repo.full_name);
                let payload = serde_json::json!({ "id": mid, "kind": "commit" });
                tokio::spawn(async move { vs.index("cortex_github", &mid, &etext, payload).await; });
                n += 1;
            }
        }
        tracing::info!(target: "aio_cortex_lib", "GitHub commits: {n} synced (user {login})");
        Ok(n)
    }
}

/* ─── Plugin impl ───────────────────────────────────────── */

#[async_trait]
impl Plugin for GithubPlugin {
    fn id(&self)   -> &str { "github" }
    fn name(&self) -> &str { "GitHub" }
    fn icon(&self) -> &str { "⬡" }

    async fn count(&self) -> u64 {
        let db = self.db_path.clone();
        tokio::task::spawn_blocking(move || {
            Connection::open(&db).ok()
                .and_then(|c| c.query_row("SELECT COUNT(*) FROM items", [], |r| r.get::<_, i64>(0)).ok())
                .unwrap_or(0) as u64
        }).await.unwrap_or(0)
    }

    async fn sync(&self) -> Result<usize> {
        if self.token.is_none() {
            tracing::warn!(target: "aio_cortex_lib", "GitHub: no token (set [github] token in ~/.cortex/config.toml), skip");
            return Ok(0);
        }

        let repos = self.sync_repos().await.unwrap_or_else(|e| {
            tracing::warn!("github repos: {e}"); 0
        });
        let issues = self.sync_issues().await.unwrap_or_else(|e| {
            tracing::warn!("github issues: {e}"); 0
        });
        let prs = self.sync_prs().await.unwrap_or_else(|e| {
            tracing::warn!("github prs: {e}"); 0
        });
        let notifs = self.sync_notifications().await.unwrap_or_else(|e| {
            tracing::warn!("github notifs: {e}"); 0
        });
        let commits = self.sync_commits().await.unwrap_or_else(|e| {
            tracing::warn!("github commits: {e}"); 0
        });

        let _ = self.load_cache();
        Ok(repos + issues + prs + notifs + commits)
    }

    async fn search(&self, query: &SearchQuery) -> Result<Vec<SearchResult>> {
        let q = &query.raw;
        let ql = q.to_lowercase();

        // Empty query = browse: list everything (repos, commits, issues, PRs)
        // by recency. Cache is already ordered updated_unix DESC.
        if q.trim().is_empty() {
            let cache = self.cache.read().unwrap();
            let results = cache.iter().take(40).enumerate()
                .map(|(i, item)| item_to_result(item, (0.95 - i as f32 * 0.01).max(0.3)))
                .collect();
            return Ok(results);
        }

        // Generic intent ("my projects / repos / github") → list repos by recency
        // even without a fuzzy match, so search + the AI both surface them.
        let list_repos = ["repo", "repos", "project", "projects", "github"]
            .iter().any(|k| ql.contains(k));
        let list_commits = ["commit", "commits", "committed", "pushed", "worked"]
            .iter().any(|k| ql.contains(k));

        let semantic_ids: Vec<String> = self.vs
            .search("cortex_github", q, 15)
            .await
            .into_iter()
            .map(|(id, _)| id)
            .collect();

        let cache = self.cache.read().unwrap();
        let mut results: Vec<SearchResult> = cache.iter()
            .filter_map(|item| {
                let haystack = format!("{} {} {}", item.title, item.repo, item.labels.join(" "));
                let fuzzy = self.matcher.fuzzy_match(&haystack, q)
                    .map(|s| s as f32 / 300.0)
                    .unwrap_or(0.0);
                let boost = if semantic_ids.contains(&item.item_id) { 0.2 } else { 0.0 };
                // Recency-ranked fallback for generic project/commit queries.
                let repo_base = if list_repos && item.kind == "repo" { 0.45 } else { 0.0 };
                let commit_base = if list_commits && item.kind == "commit" { 0.5 } else { 0.0 };
                let score = (fuzzy + boost + repo_base + commit_base).min(0.99);
                if score > 0.0 { Some(item_to_result(item, score)) } else { None }
            })
            .collect();

        results.sort_by(|a, b| b.score.partial_cmp(&a.score).unwrap_or(std::cmp::Ordering::Equal));
        results.truncate(25);
        Ok(results)
    }

    async fn execute(&self, result: &SearchResult) -> Result<()> {
        if let Some(url) = &result.url {
            opener::open_browser(url)?;
        }
        Ok(())
    }
}

fn item_to_result(item: &GithubItem, score: f32) -> SearchResult {
    let subtitle = if item.kind == "commit" {
        format!("{} · commit {}", item.repo, item.state)    // owner/name · commit a1b2c3d
    } else if item.kind == "repo" {
        let tags = if item.labels.is_empty() { String::new() } else { format!(" · {}", item.labels.join(", ")) };
        format!("{} · {}{}", item.repo, item.state, tags)   // owner/name · ★N · Rust
    } else {
        let state_marker = if item.state == "open" { "open" } else { "closed" };
        format!("{} · {} · {}", item.repo, item.kind, state_marker)
    };

    let mut r = SearchResult::new("github", &item.title);
    r.id          = format!("github:{}", item.item_id);
    r.source_type = SourceType::Url;
    r.subtitle    = Some(subtitle);
    r.url         = Some(item.url.clone());
    r.score       = score;
    r.action      = ResultAction::Open;
    r.timestamp   = chrono::DateTime::<Utc>::from_timestamp(item.updated_unix, 0);
    r.metadata.insert("kind".into(),  item.kind.as_str().into());
    r.metadata.insert("repo".into(),  item.repo.as_str().into());
    r.metadata.insert("state".into(), item.state.as_str().into());
    if let Some(n) = item.number {
        r.metadata.insert("number".into(), n.into());
    }
    r
}

fn load_cortex_env() {
    let path = dirs::home_dir().unwrap_or_default().join(".cortex/config.env");
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

/// Spawn a background task that re-syncs every 30 minutes.
pub async fn periodic_sync(plugin: std::sync::Arc<GithubPlugin>) {
    loop {
        tokio::time::sleep(std::time::Duration::from_secs(1800)).await;
        if let Err(e) = plugin.sync().await {
            tracing::warn!("github periodic sync: {e}");
        }
    }
}
