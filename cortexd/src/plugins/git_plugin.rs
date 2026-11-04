/// Git plugin — full Tantivy-indexed commit history across all discovered repos.
///
/// Index: ~/.cortex/indices/git/
/// Schema: sha(STORED), message(TEXT|STORED), author(TEXT|STORED),
///         repo(TEXT|STORED), repo_path(STORED), files_changed(TEXT|STORED),
///         timestamp_secs(FAST|STORED)
///
/// Incremental: per-repo last-indexed timestamp stored in SQLite
///   ~/.cortex/git/state.db → (repo_path TEXT PK, last_ts INTEGER)
/// Revwalk is limited to commits newer than last_ts on incremental runs.

use anyhow::Result;
use async_trait::async_trait;
use chrono::{DateTime, Utc};
use dirs::home_dir;
use fuzzy_matcher::{skim::SkimMatcherV2, FuzzyMatcher};
use rusqlite::{params, Connection};
use std::{
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
use tokio::sync::Mutex;

use crate::plugin::{Plugin, ResultAction, SearchQuery, SearchResult, SourceType};

/* ─── Tantivy fields ────────────────────────────────────── */

#[derive(Clone)]
struct GitFields {
    sha:       Field,
    message:   Field,
    author:    Field,
    repo:      Field,
    repo_path: Field,
    files:     Field,
    ts:        Field,
}

/* ─── Plugin ────────────────────────────────────────────── */

pub struct GitPlugin {
    index:    Index,
    writer:   Arc<Mutex<IndexWriter>>,
    fields:   GitFields,
    state_db: PathBuf,
    roots:    Vec<PathBuf>,
    matcher:  SkimMatcherV2,
}

impl GitPlugin {
    pub fn new(data_dir: PathBuf, extra_roots: Vec<PathBuf>) -> Result<Self> {
        std::fs::create_dir_all(&data_dir)?;

        let index_dir = data_dir.join("index");
        std::fs::create_dir_all(&index_dir)?;

        let mut sb = Schema::builder();
        let sha       = sb.add_text_field("sha",       TEXT | STORED);
        let message   = sb.add_text_field("message",   TEXT | STORED);
        let author    = sb.add_text_field("author",    TEXT | STORED);
        let repo      = sb.add_text_field("repo",      TEXT | STORED);
        let repo_path = sb.add_text_field("repo_path", STORED);
        let files     = sb.add_text_field("files",     TEXT | STORED);
        let ts        = sb.add_u64_field("ts",         FAST | STORED);
        let schema    = sb.build();

        let index = if index_dir.join("meta.json").exists() {
            Index::open_in_dir(&index_dir)?
        } else {
            Index::create_in_dir(&index_dir, schema)?
        };
        let writer = index.writer(50_000_000)?;

        let state_db = data_dir.join("state.db");
        init_state_db(&state_db)?;

        let home = home_dir().unwrap_or_default();
        let mut roots = vec![
            home.join("code"),
            home.join("projects"),
            home.join("Projects"),
            home.join("repos"),
            home.join("dev"),
            home.join("workspace"),
            home.join("src"),
        ];
        roots.extend(extra_roots);
        roots.retain(|p| p.exists());

        Ok(Self {
            index,
            writer: Arc::new(Mutex::new(writer)),
            fields: GitFields { sha, message, author, repo, repo_path, files, ts },
            state_db,
            roots,
            matcher: SkimMatcherV2::default(),
        })
    }

    fn find_git_repos(root: &PathBuf) -> Vec<PathBuf> {
        let mut repos = Vec::new();
        let walker = walkdir::WalkDir::new(root)
            .max_depth(4)
            .into_iter()
            .filter_entry(|e| {
                !matches!(e.file_name().to_str().unwrap_or(""),
                    "node_modules" | "target" | ".cache" | "dist" | "build" | "vendor")
            });
        for entry in walker.filter_map(|e| e.ok()) {
            if entry.file_type().is_dir() && entry.file_name() == ".git" {
                if let Some(parent) = entry.path().parent() {
                    repos.push(parent.to_path_buf());
                }
            }
        }
        repos
    }

    /// Extract commits from `repo` newer than `since_ts` (0 = all).
    /// Returns (Vec<CommitDoc>, latest_ts).
    fn extract_commits(
        repo_path: &PathBuf,
        since_ts: i64,
        limit: usize,
    ) -> (Vec<CommitDoc>, i64) {
        let Ok(repo) = git2::Repository::open(repo_path) else { return (vec![], since_ts) };
        let Ok(mut walk) = repo.revwalk() else { return (vec![], since_ts) };

        // Push all local branches
        if let Ok(branches) = repo.branches(Some(git2::BranchType::Local)) {
            for b in branches.filter_map(|b| b.ok()) {
                if let Ok(target) = b.0.get().peel_to_commit() {
                    let _ = walk.push(target.id());
                }
            }
        }
        // Fallback to HEAD if no branches pushed
        let _ = walk.push_head();
        let _ = walk.set_sorting(git2::Sort::TIME | git2::Sort::TOPOLOGICAL);

        let repo_name = repo_path.file_name().unwrap_or_default()
            .to_string_lossy().to_string();
        let repo_path_str = repo_path.to_string_lossy().to_string();

        let mut commits = Vec::new();
        let mut latest_ts = since_ts;

        for (i, oid) in walk.enumerate() {
            if i >= limit { break; }
            let Ok(oid) = oid else { continue };
            let Ok(commit) = repo.find_commit(oid) else { continue };

            let commit_ts = commit.time().seconds();
            if since_ts > 0 && commit_ts <= since_ts { break; }

            if commit_ts > latest_ts { latest_ts = commit_ts; }

            // Get changed file list from diff
            let files: Vec<String> = if let Some(parent) = commit.parent(0).ok() {
                let old_tree = parent.tree().ok();
                let new_tree = commit.tree().ok();
                match (old_tree, new_tree) {
                    (Some(ot), Some(nt)) => {
                        repo.diff_tree_to_tree(Some(&ot), Some(&nt), None)
                            .ok()
                            .map(|diff| {
                                let mut fs = Vec::new();
                                let _ = diff.foreach(&mut |d, _| {
                                    if let Some(p) = d.new_file().path() {
                                        fs.push(p.to_string_lossy().to_string());
                                    }
                                    true
                                }, None, None, None);
                                fs
                            })
                            .unwrap_or_default()
                    }
                    _ => vec![],
                }
            } else {
                // Initial commit — list all files from tree
                commit.tree().ok()
                    .map(|t| {
                        let mut fs = Vec::new();
                        t.walk(git2::TreeWalkMode::PreOrder, |_, e| {
                            if e.kind() == Some(git2::ObjectType::Blob) {
                                fs.push(e.name().unwrap_or("").to_string());
                            }
                            git2::TreeWalkResult::Ok
                        }).ok();
                        fs.truncate(50); // cap on large initial commits
                        fs
                    })
                    .unwrap_or_default()
            };

            commits.push(CommitDoc {
                sha:       oid.to_string(),
                sha_short: oid.to_string()[..8].to_string(),
                message:   commit.summary().unwrap_or("").to_string(),
                author:    commit.author().name().unwrap_or("").to_string(),
                repo:      repo_name.clone(),
                repo_path: repo_path_str.clone(),
                files:     files.join(" "),
                ts:        commit_ts as u64,
                date:      DateTime::from_timestamp(commit_ts, 0)
                    .map(|dt| dt.with_timezone(&Utc)),
            });
        }
        (commits, latest_ts)
    }

    fn last_ts(db: &Connection, repo_path: &str) -> i64 {
        db.query_row(
            "SELECT last_ts FROM repo_state WHERE repo_path = ?",
            params![repo_path],
            |r| r.get(0),
        ).unwrap_or(0)
    }

    fn save_ts(db: &Connection, repo_path: &str, ts: i64) {
        let _ = db.execute(
            "INSERT OR REPLACE INTO repo_state (repo_path, last_ts) VALUES (?, ?)",
            params![repo_path, ts],
        );
    }
}

/* ─── Commit document ───────────────────────────────────── */

struct CommitDoc {
    sha:       String,
    sha_short: String,
    message:   String,
    author:    String,
    repo:      String,
    repo_path: String,
    files:     String,
    ts:        u64,
    date:      Option<DateTime<Utc>>,
}

/* ─── State DB helpers ──────────────────────────────────── */

fn init_state_db(path: &PathBuf) -> Result<()> {
    let conn = Connection::open(path)?;
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS repo_state (
            repo_path TEXT PRIMARY KEY,
            last_ts   INTEGER NOT NULL DEFAULT 0
         );"
    )?;
    Ok(())
}

/* ─── Plugin impl ───────────────────────────────────────── */

#[async_trait]
impl Plugin for GitPlugin {
    fn id(&self)   -> &str { "git" }
    fn name(&self) -> &str { "Git" }
    fn icon(&self) -> &str { "⎇" }

    async fn count(&self) -> u64 {
        let reader = match self.index.reader() {
            Ok(r) => r,
            Err(_) => return 0,
        };
        reader.searcher().num_docs()
    }

    async fn sync(&self) -> Result<usize> {
        let roots       = self.roots.clone();
        let state_db    = self.state_db.clone();
        let writer      = self.writer.clone();
        let fields      = self.fields.clone();

        let total = tokio::task::spawn_blocking(move || -> usize {
            let db = match Connection::open(&state_db) {
                Ok(c) => c,
                Err(e) => { tracing::warn!("git state db: {e}"); return 0; }
            };

            let mut all_repos: Vec<PathBuf> = vec![];
            for root in &roots {
                all_repos.extend(GitPlugin::find_git_repos(root));
            }

            let mut total_new = 0usize;

            for repo_path in &all_repos {
                let path_str = repo_path.to_string_lossy().to_string();
                let since = GitPlugin::last_ts(&db, &path_str);

                let (commits, latest_ts) = GitPlugin::extract_commits(
                    repo_path,
                    since,
                    if since == 0 { 500 } else { 200 }, // bigger limit on first run
                );

                if commits.is_empty() { continue; }

                // Write to Tantivy
                let mut writer_guard = futures::executor::block_on(writer.lock());

                // Delete existing docs for this repo path before re-inserting
                // (only on full sync, not incremental)
                if since == 0 {
                    let term = Term::from_field_text(fields.repo_path, &path_str);
                    writer_guard.delete_term(term);
                }

                for c in &commits {
                    let _ = writer_guard.add_document(doc!(
                        fields.sha       => c.sha.as_str(),
                        fields.message   => c.message.as_str(),
                        fields.author    => c.author.as_str(),
                        fields.repo      => c.repo.as_str(),
                        fields.repo_path => c.repo_path.as_str(),
                        fields.files     => c.files.as_str(),
                        fields.ts        => c.ts,
                    ));
                }
                let _ = writer_guard.commit();
                drop(writer_guard);

                GitPlugin::save_ts(&db, &path_str, latest_ts);
                total_new += commits.len();
                tracing::info!("git: {path_str} — {} new commits", commits.len());
            }

            tracing::info!("git sync complete: {total_new} commits across {} repos", all_repos.len());
            total_new
        }).await.unwrap_or(0);

        Ok(total)
    }

    async fn search(&self, query: &SearchQuery) -> Result<Vec<SearchResult>> {
        let q = &query.raw;
        // Empty query = browse: list the most recent commits across all repos.
        if q.trim().is_empty() {
            let reader = self.index.reader()?;
            let searcher = reader.searcher();
            let fields = &self.fields;
            let all = searcher.search(&tantivy::query::AllQuery, &TopDocs::with_limit(800))?;
            let mut recent: Vec<(i64, TantivyDocument)> = all.iter()
                .filter_map(|(_, addr)| searcher.doc::<TantivyDocument>(*addr).ok())
                .map(|doc: TantivyDocument| {
                    let ts = doc.get_first(fields.ts).and_then(|v| v.as_u64()).map(|t| t as i64).unwrap_or(0);
                    (ts, doc)
                }).collect();
            recent.sort_unstable_by(|a, b| b.0.cmp(&a.0));
            recent.truncate(40);
            let results = recent.into_iter().enumerate().map(|(i, (ts, doc))| {
                let get = |f: Field| doc.get_first(f).and_then(|v| v.as_str()).unwrap_or("").to_string();
                let sha       = get(fields.sha);
                let sha_short = sha.chars().take(8).collect::<String>();
                let message   = get(fields.message);
                let author    = get(fields.author);
                let repo      = get(fields.repo);
                let repo_path = get(fields.repo_path);
                let date = DateTime::from_timestamp(ts, 0).map(|dt| dt.with_timezone(&Utc));
                let mut r = SearchResult::new("git", format!("{sha_short} — {message}"));
                r.source_type = SourceType::GitCommit;
                r.subtitle    = Some(format!("{repo} · {author}"));
                r.score       = (0.95 - i as f32 * 0.01).max(0.3);
                r.timestamp   = date;
                r.action      = ResultAction::Open;
                r.metadata.insert("sha".into(),       sha.as_str().into());
                r.metadata.insert("sha_short".into(), sha_short.as_str().into());
                r.metadata.insert("repo".into(),      repo.as_str().into());
                r.metadata.insert("repo_path".into(), repo_path.as_str().into());
                r
            }).collect();
            return Ok(results);
        }

        let reader = self.index.reader()?;
        let searcher = reader.searcher();
        let qp = QueryParser::for_index(&self.index, vec![
            self.fields.message,
            self.fields.author,
            self.fields.repo,
            self.fields.files,
        ]);

        // Lenient parse — don't error on special chars
        let tantivy_q = qp.parse_query_lenient(q).0;
        let top = searcher.search(&tantivy_q, &TopDocs::with_limit(20))?;

        let fields = &self.fields;
        let mut results: Vec<SearchResult> = top.iter().map(|(score, addr)| {
            let doc: TantivyDocument = searcher.doc(*addr).unwrap_or_default();
            let get = |f: Field| doc.get_first(f)
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();

            let sha       = get(fields.sha);
            let sha_short = sha.chars().take(8).collect::<String>();
            let message   = get(fields.message);
            let author    = get(fields.author);
            let repo      = get(fields.repo);
            let repo_path = get(fields.repo_path);
            let ts = doc.get_first(fields.ts)
                .and_then(|v| v.as_u64())
                .map(|t| t as i64)
                .unwrap_or(0);
            let date = DateTime::from_timestamp(ts, 0).map(|dt| dt.with_timezone(&Utc));

            let mut r = SearchResult::new("git", format!("{sha_short} — {message}"));
            r.source_type = SourceType::GitCommit;
            r.subtitle    = Some(format!("{repo} · {author}"));
            r.score       = (*score).min(0.99);
            r.timestamp   = date;
            r.action      = ResultAction::Open;
            r.metadata.insert("sha".into(),       sha.as_str().into());
            r.metadata.insert("sha_short".into(), sha_short.as_str().into());
            r.metadata.insert("repo".into(),      repo.as_str().into());
            r.metadata.insert("repo_path".into(), repo_path.as_str().into());
            r
        }).collect();

        // Fuzzy fallback — boost by recency
        if results.is_empty() {
            let reader2 = self.index.reader()?;
            let searcher2 = reader2.searcher();
            let all_top = searcher2.search(
                &tantivy::query::AllQuery,
                &TopDocs::with_limit(500),
            )?;
            let matcher = &self.matcher;
            let mut fuzzy: Vec<(i64, TantivyDocument)> = all_top.iter()
                .filter_map(|(_, addr)| searcher2.doc::<TantivyDocument>(*addr).ok())
                .filter_map(|doc: TantivyDocument| {
                    let msg = doc.get_first(fields.message)
                        .and_then(|v| v.as_str()).unwrap_or("");
                    let score = matcher.fuzzy_match(msg, q)?;
                    Some((score, doc))
                })
                .collect();
            fuzzy.sort_unstable_by(|a, b| b.0.cmp(&a.0));
            fuzzy.truncate(12);
            results = fuzzy.into_iter().map(|(score, doc)| {
                let get = |f: Field| doc.get_first(f)
                    .and_then(|v| v.as_str()).unwrap_or("").to_string();
                let sha       = get(fields.sha);
                let sha_short = sha.chars().take(8).collect::<String>();
                let message   = get(fields.message);
                let author    = get(fields.author);
                let repo      = get(fields.repo);
                let repo_path = get(fields.repo_path);
                let ts = doc.get_first(fields.ts)
                    .and_then(|v| v.as_u64()).map(|t| t as i64).unwrap_or(0);
                let date = DateTime::from_timestamp(ts, 0).map(|dt| dt.with_timezone(&Utc));

                let mut r = SearchResult::new("git", format!("{sha_short} — {message}"));
                r.source_type = SourceType::GitCommit;
                r.subtitle    = Some(format!("{repo} · {author}"));
                r.score       = (score as f32 / 300.0).min(0.95);
                r.timestamp   = date;
                r.action      = ResultAction::Open;
                r.metadata.insert("sha".into(),       sha.as_str().into());
                r.metadata.insert("sha_short".into(), sha_short.as_str().into());
                r.metadata.insert("repo".into(),      repo.as_str().into());
                r.metadata.insert("repo_path".into(), repo_path.as_str().into());
                r
            }).collect();
        }

        Ok(results)
    }

    async fn execute(&self, result: &SearchResult) -> Result<()> {
        let sha = result.metadata.get("sha")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        if !sha.is_empty() {
            let mut cb = arboard::Clipboard::new()?;
            cb.set_text(sha)?;
        }
        Ok(())
    }
}
