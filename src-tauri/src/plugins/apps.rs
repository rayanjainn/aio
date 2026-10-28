//! Apps plugin — Raycast-style application launcher with frecency.
//!
//! Scans OS application directories, fuzzy-matches the query, and launches the
//! selected app via `opener`. Empty query → suggestions ordered by *frecency*
//! (recent + frequent launches), read from the shared `interactions.db` that
//! `Ranker::persist_open` writes to. Result IDs are stable (`apps:<path>`) so
//! launch counts accumulate across sessions.

use anyhow::Result;
use async_trait::async_trait;
use fuzzy_matcher::{skim::SkimMatcherV2, FuzzyMatcher};
use std::{collections::HashMap, path::PathBuf, sync::Arc};
use tokio::sync::RwLock;

use crate::plugin::{Plugin, ResultAction, SearchQuery, SearchResult, SourceType};

#[derive(Clone, Debug)]
pub struct AppEntry {
    pub name: String,
    pub path: String,
}

pub struct AppsPlugin {
    apps:      Arc<RwLock<Vec<AppEntry>>>,
    /// app path → (open_count, last_open_unix)
    frecency:  Arc<RwLock<HashMap<String, (u32, i64)>>>,
    db_path:   PathBuf,
    matcher:   SkimMatcherV2,
}

impl AppsPlugin {
    pub fn new(data_dir: PathBuf) -> Self {
        Self {
            apps:     Arc::new(RwLock::new(Vec::new())),
            frecency: Arc::new(RwLock::new(HashMap::new())),
            db_path:  data_dir.join("interactions.db"),
            matcher:  SkimMatcherV2::default(),
        }
    }

    fn roots() -> Vec<PathBuf> {
        let home = dirs::home_dir().unwrap_or_default();
        #[cfg(target_os = "macos")]
        { vec![
            PathBuf::from("/Applications"),
            PathBuf::from("/Applications/Utilities"),
            PathBuf::from("/System/Applications"),
            PathBuf::from("/System/Applications/Utilities"),
            home.join("Applications"),
        ] }
        #[cfg(target_os = "linux")]
        { vec![
            PathBuf::from("/usr/share/applications"),
            PathBuf::from("/usr/local/share/applications"),
            home.join(".local/share/applications"),
        ] }
        #[cfg(target_os = "windows")]
        { let _ = home; vec![PathBuf::from(r"C:\ProgramData\Microsoft\Windows\Start Menu\Programs")] }
    }

    #[cfg(target_os = "macos")]
    fn scan() -> Vec<AppEntry> {
        let mut out = Vec::new();
        for root in Self::roots() {
            let Ok(rd) = std::fs::read_dir(&root) else { continue };
            for entry in rd.flatten() {
                let path = entry.path();
                if path.extension().and_then(|e| e.to_str()) == Some("app") {
                    if let Some(name) = path.file_stem().and_then(|s| s.to_str()) {
                        out.push(AppEntry { name: name.to_string(), path: path.to_string_lossy().to_string() });
                    }
                }
            }
        }
        out
    }

    #[cfg(target_os = "linux")]
    fn scan() -> Vec<AppEntry> {
        let mut out = Vec::new();
        for root in Self::roots() {
            let Ok(rd) = std::fs::read_dir(&root) else { continue };
            for entry in rd.flatten() {
                let path = entry.path();
                if path.extension().and_then(|e| e.to_str()) == Some("desktop") {
                    let content = std::fs::read_to_string(&path).unwrap_or_default();
                    let name = content.lines().find_map(|l| l.strip_prefix("Name="))
                        .map(|s| s.to_string())
                        .or_else(|| path.file_stem().map(|s| s.to_string_lossy().to_string()))
                        .unwrap_or_default();
                    if !name.is_empty() {
                        out.push(AppEntry { name, path: path.to_string_lossy().to_string() });
                    }
                }
            }
        }
        out
    }

    #[cfg(target_os = "windows")]
    fn scan() -> Vec<AppEntry> { Vec::new() }

    /// Read launch counts for `apps:*` rows from interactions.db.
    fn load_frecency(db_path: &std::path::Path) -> HashMap<String, (u32, i64)> {
        let mut map = HashMap::new();
        let Ok(conn) = rusqlite::Connection::open(db_path) else { return map };
        let _ = conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS interactions (
                item_id TEXT PRIMARY KEY, open_count INTEGER, last_open INTEGER)",
        );
        if let Ok(mut stmt) = conn.prepare(
            "SELECT item_id, open_count, last_open FROM interactions WHERE item_id LIKE 'apps:%'",
        ) {
            let rows = stmt.query_map([], |r| {
                Ok((r.get::<_, String>(0)?, r.get::<_, u32>(1)?, r.get::<_, i64>(2)?))
            });
            if let Ok(rows) = rows {
                for row in rows.flatten() {
                    let path = row.0.trim_start_matches("apps:").to_string();
                    map.insert(path, (row.1, row.2));
                }
            }
        }
        map
    }

    /// Frecency score 0..1: blends frequency with recency decay (~14-day half-life).
    fn frecency_score(&self, fr: &HashMap<String, (u32, i64)>, path: &str) -> f32 {
        let Some((count, last)) = fr.get(path) else { return 0.0 };
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs() as i64).unwrap_or(0);
        let age_days = ((now - last).max(0) as f32) / 86_400.0;
        let recency = 0.5_f32.powf(age_days / 14.0);          // half-life 14d
        let freq    = (*count as f32 / 10.0).min(1.0);        // saturate at 10 opens
        (0.6 * freq + 0.4 * recency).clamp(0.0, 1.0)
    }
}

#[async_trait]
impl Plugin for AppsPlugin {
    fn id(&self)   -> &str { "apps" }
    fn name(&self) -> &str { "Applications" }
    fn icon(&self) -> &str { "apps" }

    async fn count(&self) -> u64 { self.apps.read().await.len() as u64 }

    async fn sync(&self) -> Result<usize> {
        let apps = tokio::task::spawn_blocking(Self::scan).await?;
        let n = apps.len();
        let db = self.db_path.clone();
        let fr = tokio::task::spawn_blocking(move || Self::load_frecency(&db)).await.unwrap_or_default();
        tracing::info!(target: "aio_cortex_lib", "apps: {n} apps, {} with launch history", fr.len());
        *self.apps.write().await = apps;
        *self.frecency.write().await = fr;
        Ok(n)
    }

    async fn search(&self, query: &SearchQuery) -> Result<Vec<SearchResult>> {
        let apps = self.apps.read().await;
        let fr   = self.frecency.read().await;
        let q = query.raw.trim();

        let mut results: Vec<SearchResult> = if q.is_empty() {
            // Empty → frecency-ranked suggestions (recents float to top).
            let mut scored: Vec<(f32, &AppEntry)> = apps.iter()
                .map(|a| (self.frecency_score(&fr, &a.path), a))
                .collect();
            scored.sort_by(|a, b| {
                b.0.partial_cmp(&a.0).unwrap_or(std::cmp::Ordering::Equal)
                    .then_with(|| a.1.name.to_lowercase().cmp(&b.1.name.to_lowercase()))
            });
            scored.into_iter().take(8)
                .map(|(fs, a)| make_result(a, 0.55 + 0.4 * fs))
                .collect()
        } else {
            let mut scored: Vec<(i64, f32, &AppEntry)> = apps.iter()
                .filter_map(|a| self.matcher.fuzzy_match(&a.name, q)
                    .map(|s| (s, self.frecency_score(&fr, &a.path), a)))
                .collect();
            // Fuzzy score primary, frecency as tiebreak boost.
            scored.sort_by(|a, b| {
                let sa = a.0 as f32 + a.1 * 40.0;
                let sb = b.0 as f32 + b.1 * 40.0;
                sb.partial_cmp(&sa).unwrap_or(std::cmp::Ordering::Equal)
            });
            scored.into_iter().take(8)
                .map(|(s, fs, a)| make_result(a, ((s as f32 / 100.0) + 0.15 * fs).clamp(0.5, 0.99)))
                .collect()
        };

        // Apps out-rank generic file hits for short queries.
        for r in &mut results { r.score = (r.score + 0.12).min(1.0); }
        tracing::debug!(target: "aio_cortex_lib", "apps: '{q}' → {} matches", results.len());
        Ok(results)
    }

    async fn execute(&self, result: &SearchResult) -> Result<()> {
        if let Some(path) = &result.path {
            tracing::info!(target: "aio_cortex_lib", "apps: launching {path}");
            opener::open(path)?;
        }
        Ok(())
    }
}

fn make_result(app: &AppEntry, score: f32) -> SearchResult {
    let mut r = SearchResult::new("apps", &app.name);
    // Stable id so launch counts accumulate in interactions.db.
    r.id          = format!("apps:{}", app.path);
    r.source_type = SourceType::File;
    r.subtitle    = Some("Application".to_string());
    r.path        = Some(app.path.clone());
    r.score       = score;
    r.action      = ResultAction::Open;
    r
}
