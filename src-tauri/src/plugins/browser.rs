/// Browser plugin — history from Chrome/Firefox/Safari SQLite + live tabs via
/// WebSocket.
///
/// History:  copied to a temp file (browser keeps DB locked), parsed with
///           rusqlite, deduplicated by URL, stored in an in-memory cache.
///           Full sync on startup; the global 5-min loop calls sync() again.
///
/// Live tabs: the Chrome extension sends tab lifecycle events to a
///            tokio-tungstenite WebSocket server on :27182.  The server calls
///            `handle_tab_event()` on this plugin.  Live tabs are included in
///            search results with a score bonus (they're probably relevant right now).

use anyhow::Result;
use async_trait::async_trait;
use chrono::{DateTime, Utc};
use dirs::home_dir;
use fuzzy_matcher::{skim::SkimMatcherV2, FuzzyMatcher};
use serde::Deserialize;
use std::{collections::HashMap, path::PathBuf, sync::Arc};
use tokio::sync::RwLock;

use crate::plugin::{Plugin, ResultAction, SearchQuery, SearchResult, SourceType};

/* ─── History entry ─────────────────────────────────────── */

#[derive(Debug, Clone)]
struct HistoryEntry {
    url:         String,
    title:       String,
    visit_time:  Option<DateTime<Utc>>,
    visit_count: i32,
}

/* ─── Live tab ──────────────────────────────────────────── */

#[derive(Debug, Clone)]
pub struct LiveTab {
    pub tab_id:  u64,
    pub url:     String,
    pub title:   String,
    pub favicon: Option<String>,
}

/// Tab lifecycle event received from the Chrome extension over WebSocket.
#[derive(Debug, Deserialize)]
pub struct TabEvent {
    pub event:       String,        // "created" | "updated" | "activated" | "removed"
    pub tab_id:      u64,
    pub url:         Option<String>,
    pub title:       Option<String>,
    pub favicon_url: Option<String>,
}

/* ─── Plugin ─────────────────────────────────────────────── */

pub struct BrowserPlugin {
    cache:     RwLock<Vec<HistoryEntry>>,
    live_tabs: Arc<RwLock<HashMap<u64, LiveTab>>>,
    matcher:   SkimMatcherV2,
}

impl BrowserPlugin {
    pub fn new() -> Self {
        Self {
            cache:     RwLock::new(Vec::new()),
            live_tabs: Arc::new(RwLock::new(HashMap::new())),
            matcher:   SkimMatcherV2::default(),
        }
    }

    /// Clone of the live-tabs map — pass to the WS server task.
    pub fn live_tabs_handle(&self) -> Arc<RwLock<HashMap<u64, LiveTab>>> {
        self.live_tabs.clone()
    }

    /// Called by the WebSocket server when a tab event arrives.
    pub async fn handle_tab_event(&self, event: TabEvent) {
        match event.event.as_str() {
            "created" | "updated" | "activated" => {
                if let Some(url) = event.url {
                    if url.starts_with("chrome://") || url.starts_with("about:") {
                        return; // skip internal browser pages
                    }
                    self.live_tabs.write().await.insert(event.tab_id, LiveTab {
                        tab_id:  event.tab_id,
                        url,
                        title:   event.title.unwrap_or_default(),
                        favicon: event.favicon_url,
                    });
                }
            }
            "removed" => {
                self.live_tabs.write().await.remove(&event.tab_id);
            }
            _ => {}
        }
    }

    /* ── Browser path detection ──────────────────────────── */

    fn chrome_history_paths() -> Vec<PathBuf> {
        let home = home_dir().unwrap_or_default();
        let mut paths = Vec::new();
        #[cfg(target_os = "macos")]
        {
            let base = home.join("Library/Application Support");
            for browser in &[
                "Google/Chrome",
                "Chromium",
                "Microsoft Edge",
                "BraveSoftware/Brave-Browser",
                "Arc/User Data",
            ] {
                for profile in &["Default", "Profile 1", "Profile 2", "Profile 3"] {
                    let p = base.join(browser).join(profile).join("History");
                    if p.exists() { paths.push(p); }
                }
            }
        }
        #[cfg(target_os = "linux")]
        {
            let base = home.join(".config");
            for browser in &["google-chrome", "chromium", "microsoft-edge", "BraveSoftware/Brave-Browser"] {
                for profile in &["Default", "Profile 1"] {
                    let p = base.join(browser).join(profile).join("History");
                    if p.exists() { paths.push(p); }
                }
            }
        }
        paths
    }

    fn firefox_history_paths() -> Vec<PathBuf> {
        let home = home_dir().unwrap_or_default();
        #[cfg(target_os = "macos")]
        let profiles_dir = home.join("Library/Application Support/Firefox/Profiles");
        #[cfg(target_os = "linux")]
        let profiles_dir = home.join(".mozilla/firefox");
        #[cfg(not(any(target_os = "macos", target_os = "linux")))]
        let profiles_dir = home.join(".mozilla/firefox");

        std::fs::read_dir(&profiles_dir)
            .into_iter()
            .flatten()
            .filter_map(|e| e.ok())
            .map(|e| e.path().join("places.sqlite"))
            .filter(|p| p.exists())
            .collect()
    }

    fn safari_history_path() -> Option<PathBuf> {
        #[cfg(target_os = "macos")]
        {
            let p = home_dir()?.join("Library/Safari/History.db");
            return p.exists().then_some(p);
        }
        #[allow(unreachable_code)]
        None
    }

    /* ── SQLite readers ──────────────────────────────────── */

    fn read_chrome(path: &PathBuf) -> Vec<HistoryEntry> {
        // Chrome locks its DB; copy to temp first
        let tmp = std::env::temp_dir().join("cortex_chrome_hist.db");
        if std::fs::copy(path, &tmp).is_err() { return vec![]; }
        Self::query_sqlite(&tmp, |conn| {
            let mut stmt = conn.prepare(
                "SELECT u.url, u.title, v.visit_time, u.visit_count
                 FROM urls u JOIN visits v ON u.id = v.url
                 ORDER BY v.visit_time DESC LIMIT 10000",
            )?;
            let rows = stmt.query_map([], |row| {
                // Chrome epoch: microseconds since 1601-01-01; convert to Unix µs
                let chrome_ts: i64 = row.get(2).unwrap_or(0);
                let unix_us = chrome_ts.saturating_sub(11_644_473_600_000_000i64);
                let ts = DateTime::from_timestamp(unix_us / 1_000_000, 0)
                    .map(|dt| dt.with_timezone(&Utc));
                Ok(HistoryEntry {
                    url:         row.get(0)?,
                    title:       row.get::<_, Option<String>>(1)?.unwrap_or_default(),
                    visit_time:  ts,
                    visit_count: row.get(3)?,
                })
            })?;
            Ok(rows.filter_map(|r| r.ok()).collect())
        })
    }

    fn read_firefox(path: &PathBuf) -> Vec<HistoryEntry> {
        let tmp = std::env::temp_dir().join("cortex_ff_hist.db");
        if std::fs::copy(path, &tmp).is_err() { return vec![]; }
        Self::query_sqlite(&tmp, |conn| {
            let mut stmt = conn.prepare(
                "SELECT p.url, p.title, h.visit_date, p.visit_count
                 FROM moz_places p JOIN moz_historyvisits h ON p.id = h.place_id
                 ORDER BY h.visit_date DESC LIMIT 10000",
            )?;
            let rows = stmt.query_map([], |row| {
                let ts_us: i64 = row.get(2).unwrap_or(0);
                let ts = DateTime::from_timestamp(ts_us / 1_000_000, 0)
                    .map(|dt| dt.with_timezone(&Utc));
                Ok(HistoryEntry {
                    url:         row.get(0)?,
                    title:       row.get::<_, Option<String>>(1)?.unwrap_or_default(),
                    visit_time:  ts,
                    visit_count: row.get(3)?,
                })
            })?;
            Ok(rows.filter_map(|r| r.ok()).collect())
        })
    }

    fn read_safari(path: &PathBuf) -> Vec<HistoryEntry> {
        let tmp = std::env::temp_dir().join("cortex_safari_hist.db");
        if std::fs::copy(path, &tmp).is_err() { return vec![]; }
        Self::query_sqlite(&tmp, |conn| {
            let mut stmt = conn.prepare(
                "SELECT i.url, v.title, v.visit_time, (SELECT COUNT(*) FROM history_visits WHERE history_item = i.id) as cnt
                 FROM history_items i JOIN history_visits v ON i.id = v.history_item
                 ORDER BY v.visit_time DESC LIMIT 10000",
            )?;
            let rows = stmt.query_map([], |row| {
                // Safari: seconds since 2001-01-01 (Apple epoch)
                let apple_ts: f64 = row.get(2).unwrap_or(0.0);
                let unix_ts = (apple_ts as i64) + 978_307_200; // offset to Unix epoch
                let ts = DateTime::from_timestamp(unix_ts, 0).map(|dt| dt.with_timezone(&Utc));
                Ok(HistoryEntry {
                    url:         row.get(0)?,
                    title:       row.get::<_, Option<String>>(1)?.unwrap_or_default(),
                    visit_time:  ts,
                    visit_count: row.get::<_, i64>(3)? as i32,
                })
            })?;
            Ok(rows.filter_map(|r| r.ok()).collect())
        })
    }

    fn query_sqlite<T>(
        path: &PathBuf,
        f: impl FnOnce(&rusqlite::Connection) -> rusqlite::Result<T>,
    ) -> T
    where
        T: Default,
    {
        let Ok(conn) = rusqlite::Connection::open_with_flags(
            path,
            rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX,
        ) else {
            return T::default();
        };
        f(&conn).unwrap_or_default()
    }
}

/* ─── Plugin impl ───────────────────────────────────────── */

#[async_trait]
impl Plugin for BrowserPlugin {
    fn id(&self)   -> &str { "browser" }
    fn name(&self) -> &str { "Browser" }
    fn icon(&self) -> &str { "🌐" }

    async fn count(&self) -> u64 {
        (self.cache.read().await.len() + self.live_tabs.read().await.len()) as u64
    }

    async fn sync(&self) -> Result<usize> {
        // Run all SQLite reads on blocking thread (file IO + rusqlite)
        let chrome_paths  = Self::chrome_history_paths();
        let firefox_paths = Self::firefox_history_paths();
        let safari_path   = Self::safari_history_path();

        let mut all: Vec<HistoryEntry> = tokio::task::spawn_blocking(move || {
            let mut v = Vec::new();
            for p in &chrome_paths  { v.extend(Self::read_chrome(p));  }
            for p in &firefox_paths { v.extend(Self::read_firefox(p)); }
            if let Some(p) = &safari_path { v.extend(Self::read_safari(p)); }
            v
        }).await?;

        // Dedup by URL; keep most-recently-visited entry
        all.sort_unstable_by(|a, b| b.visit_time.cmp(&a.visit_time));
        all.dedup_by(|a, b| a.url == b.url);

        let count = all.len();
        *self.cache.write().await = all;
        tracing::info!("browser sync: {count} history entries");
        Ok(count)
    }

    async fn search(&self, query: &SearchQuery) -> Result<Vec<SearchResult>> {
        let cache = self.cache.read().await;
        let tabs  = self.live_tabs.read().await;
        let q     = &query.raw;

        // ── Live tabs (boosted +200 score offset) ─────────
        let mut results: Vec<SearchResult> = tabs.values()
            .filter_map(|tab| {
                let title_s = self.matcher.fuzzy_match(&tab.title, q).unwrap_or(0);
                let url_s   = self.matcher.fuzzy_match(&tab.url,   q).unwrap_or(0);
                let best    = title_s.max(url_s);
                if best < 15 { return None; }
                let mut r = SearchResult::new("browser", &tab.title);
                r.source_type = SourceType::Url;
                r.subtitle    = Some(tab.url.clone());
                r.url         = Some(tab.url.clone());
                r.score       = ((best + 200) as f32 / 400.0).min(0.99); // boost
                r.action      = ResultAction::Open;
                r.metadata.insert("live_tab".into(), true.into());
                r.metadata.insert("tab_id".into(), (tab.tab_id as i64).into());
                Some(r)
            })
            .collect();

        // ── History — recency-weighted ───────────────────
        // Many pages match a broad term ("youtube") equally on URL, so pure
        // fuzzy order is arbitrary. Blend in recency so "what did I watch
        // recently" surfaces the MOST RECENT matches, not random old ones.
        let now = chrono::Utc::now();
        // Empty query = browse mode: list the most recent history by recency.
        let browse = q.trim().is_empty();
        let mut scored: Vec<(f32, &HistoryEntry)> = cache.iter()
            .filter_map(|e| {
                let recency = e.visit_time.map(|t| {
                    let h = (now - t).num_hours().max(0);
                    if h <= 24 { 0.45 } else if h <= 24 * 7 { 0.2 } else if h <= 24 * 30 { 0.08 } else { 0.0 }
                }).unwrap_or(0.0);
                if browse {
                    // Rank purely by recency; newest first.
                    let age = e.visit_time.map(|t| (now - t).num_seconds().max(0)).unwrap_or(i64::MAX);
                    return Some((1.0 - (age as f32 / 1e10).min(0.9), e));
                }
                let ts = self.matcher.fuzzy_match(&e.title, q).unwrap_or(0);
                let us = self.matcher.fuzzy_match(&e.url,   q).unwrap_or(0);
                let best = ts.max(us);
                if best <= 20 { return None; }
                let fuzzy = (best as f32 / 300.0).min(0.7);
                Some((fuzzy + recency, e))
            })
            .collect();

        scored.sort_by(|a, b| b.0.partial_cmp(&a.0).unwrap_or(std::cmp::Ordering::Equal));
        scored.truncate(20);

        results.extend(scored.into_iter().map(|(score, e)| {
            let mut r = SearchResult::new("browser", &e.title);
            r.source_type = SourceType::Url;
            r.subtitle    = Some(e.url.clone());
            r.url         = Some(e.url.clone());
            r.score       = score.min(0.98);
            r.timestamp   = e.visit_time;
            r.action      = ResultAction::Open;
            r.metadata.insert("visits".into(), e.visit_count.into());
            r
        }));

        // Dedup by URL (live tab might duplicate a history entry)
        results.sort_unstable_by(|a, b| b.score.partial_cmp(&a.score).unwrap());
        results.dedup_by(|a, b| a.url == b.url);
        results.truncate(20);
        Ok(results)
    }

    async fn execute(&self, result: &SearchResult) -> Result<()> {
        if let Some(url) = &result.url { webbrowser::open(url)?; }
        Ok(())
    }
}
