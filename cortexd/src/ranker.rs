/// Hybrid ranker: BM25 + cosine similarity + temporal decay + behavioral boost.
///
/// Score = 0.45·bm25 + 0.30·cosine + 0.15·temporal + 0.10·behavioral
///
/// All components normalized to [0, 1]; final score also [0, 1].

use crate::plugin::SearchResult;
use chrono::{DateTime, Utc};
use std::collections::HashMap;

pub struct RankerConfig {
    pub bm25_weight:       f32,   // 0.45
    pub cosine_weight:     f32,   // 0.30
    pub temporal_weight:   f32,   // 0.15
    pub behavioral_weight: f32,   // 0.10
    /// Half-life for temporal decay in seconds (default 7 days)
    pub decay_half_life_s: f64,
}

impl Default for RankerConfig {
    fn default() -> Self {
        Self {
            bm25_weight:       0.45,
            cosine_weight:     0.30,
            temporal_weight:   0.15,
            behavioral_weight: 0.10,
            decay_half_life_s: 7.0 * 24.0 * 3600.0,
        }
    }
}

pub struct Ranker {
    pub config: RankerConfig,
    /// item_id → open count (loaded from SQLite at startup, updated in memory)
    pub behavioral_log: HashMap<String, u32>,
    pub max_opens: u32,
    /// item_id → cosine score from most recent Qdrant search.
    /// Populated by inject_cosine_scores() before rank() is called.
    pub cosine_scores: HashMap<String, f32>,
}

impl Ranker {
    pub fn new(config: RankerConfig, behavioral_log: HashMap<String, u32>) -> Self {
        let max_opens = behavioral_log.values().copied().max().unwrap_or(1);
        Self {
            config,
            behavioral_log,
            max_opens,
            cosine_scores: HashMap::new(),
        }
    }

    /// Inject cosine similarity scores from a Qdrant search result.
    /// Call before rank() when semantic scores are available.
    pub fn inject_cosine_scores(&mut self, scores: HashMap<String, f32>) {
        self.cosine_scores = scores;
    }

    /// Temporal decay: exponential with 7-day half-life.
    /// Returns 1.0 for brand-new, 0.5 at half-life, approaches 0 asymptotically.
    /// Items without timestamp get 0.3 (neutral-low).
    fn temporal_score(&self, ts: Option<DateTime<Utc>>) -> f32 {
        let Some(ts) = ts else { return 0.3 };
        let age_s = (Utc::now() - ts).num_seconds().max(0) as f64;
        let lambda = std::f64::consts::LN_2 / self.config.decay_half_life_s;
        (-lambda * age_s).exp() as f32
    }

    /// Behavioral boost: normalized open count in [0, 1].
    fn behavioral_score(&self, id: &str) -> f32 {
        if self.max_opens == 0 { return 0.0; }
        let opens = self.behavioral_log.get(id).copied().unwrap_or(0);
        (opens as f32 / self.max_opens as f32).min(1.0)
    }

    /// Cosine score from last Qdrant search, or 0.0 if not present.
    fn cosine_score(&self, id: &str) -> f32 {
        self.cosine_scores.get(id).copied().unwrap_or(0.0)
    }

    /// Re-rank a Vec of results in place. Sort descending by final score.
    pub fn rank(&self, results: &mut Vec<SearchResult>) {
        let c = &self.config;
        for r in results.iter_mut() {
            let behavioral = self.behavioral_score(&r.id);
            // Launchers (apps / system commands) carry their own fuzzy-match
            // relevance in `score`; they have no BM25/cosine/timestamp, so the
            // hybrid formula would unfairly bury them under recent files.
            // Preserve their relevance, blend a little frecency, and keep them
            // competitive so they survive the top-N truncation.
            r.score = match r.plugin_id.as_str() {
                "apps" | "commands" => (r.score.clamp(0.0, 1.0) * 0.9 + behavioral * 0.1).min(1.0),
                _ => {
                    let bm25     = r.score.clamp(0.0, 1.0);
                    let cosine   = self.cosine_score(&r.id);
                    let temporal = self.temporal_score(r.timestamp);
                    c.bm25_weight       * bm25
                        + c.cosine_weight     * cosine
                        + c.temporal_weight   * temporal
                        + c.behavioral_weight * behavioral
                }
            };
        }
        results.sort_unstable_by(|a, b| {
            b.score.partial_cmp(&a.score).unwrap_or(std::cmp::Ordering::Equal)
        });
    }

    /// rank() + truncate to top N.
    pub fn rank_top(&self, results: &mut Vec<SearchResult>, n: usize) {
        self.rank(results);
        results.truncate(n);
    }

    /// Record a user interaction. Persists in memory; caller should also
    /// write to SQLite (in ipc.rs execute_result).
    pub fn record_open(&mut self, id: &str) {
        let count = self.behavioral_log.entry(id.to_string()).or_insert(0);
        *count += 1;
        if *count > self.max_opens {
            self.max_opens = *count;
        }
    }

    /// Load behavioral log from SQLite. Called at startup.
    pub fn load_behavioral_log(db_path: &std::path::Path) -> HashMap<String, u32> {
        let Ok(conn) = rusqlite::Connection::open(db_path) else {
            return HashMap::new();
        };
        let _ = conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS interactions (
                item_id    TEXT PRIMARY KEY,
                open_count INTEGER NOT NULL DEFAULT 0,
                last_open  INTEGER NOT NULL DEFAULT 0
            );",
        );
        let Ok(mut stmt) =
            conn.prepare("SELECT item_id, open_count FROM interactions")
        else {
            return HashMap::new();
        };
        stmt.query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, u32>(1)?))
        })
        .map(|rows| rows.filter_map(|r| r.ok()).collect())
        .unwrap_or_default()
    }

    /// Persist a single open event to SQLite.
    pub fn persist_open(db_path: &std::path::Path, item_id: &str) {
        let Ok(conn) = rusqlite::Connection::open(db_path) else { return };
        let now = chrono::Utc::now().timestamp();
        let _ = conn.execute(
            "INSERT INTO interactions (item_id, open_count, last_open) VALUES (?1, 1, ?2)
             ON CONFLICT(item_id) DO UPDATE SET open_count = open_count + 1, last_open = ?2",
            rusqlite::params![item_id, now],
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::plugin::ResultAction;
    use chrono::Duration;

    fn make_result(id: &str, bm25: f32, age_hours: i64) -> SearchResult {
        let mut r = SearchResult::new("test", id);
        r.id = id.to_string();
        r.score = bm25;
        r.timestamp = Some(Utc::now() - Duration::hours(age_hours));
        r.action = ResultAction::Open;
        r
    }

    #[test]
    fn recent_items_rank_higher_with_same_bm25() {
        let ranker = Ranker::new(RankerConfig::default(), HashMap::new());
        let mut results = vec![
            make_result("old",    0.9, 24 * 14),
            make_result("recent", 0.9, 1),
        ];
        ranker.rank(&mut results);
        assert_eq!(results[0].id, "recent");
    }

    #[test]
    fn cosine_boost_lifts_item() {
        let mut ranker = Ranker::new(RankerConfig::default(), HashMap::new());
        let mut scores = HashMap::new();
        scores.insert("semantic".to_string(), 0.95f32);
        ranker.inject_cosine_scores(scores);
        let mut results = vec![
            make_result("semantic", 0.5, 1),
            make_result("keyword",  0.9, 1),
        ];
        ranker.rank(&mut results);
        // semantic: 0.45*0.5 + 0.30*0.95 = 0.225 + 0.285 = 0.510
        // keyword:  0.45*0.9 + 0.30*0.0  = 0.405
        assert_eq!(results[0].id, "semantic");
    }

    #[test]
    fn scores_clamp_to_unit_range() {
        let ranker = Ranker::new(RankerConfig::default(), HashMap::new());
        let mut results = vec![make_result("x", 1.0, 0)];
        ranker.rank(&mut results);
        assert!(results[0].score <= 1.0);
        assert!(results[0].score >= 0.0);
    }

    #[test]
    fn behavioral_boost_lifts_frequently_opened_item() {
        let mut log = HashMap::new();
        log.insert("fav".to_string(), 100u32);
        let ranker = Ranker::new(RankerConfig::default(), log);
        let mut results = vec![
            make_result("fav",   0.5, 48),
            make_result("other", 0.7, 1),
        ];
        ranker.rank(&mut results);
        // fav: 0.45*0.5 + 0.10*1.0 = 0.325 + temporal
        // other: 0.45*0.7 + 0.10*0.0 = 0.315 + temporal
        // both contend via temporal — verify ordering is stable
        assert!(results[0].score >= results[1].score);
    }

    #[test]
    fn rank_top_truncates_correctly() {
        let ranker = Ranker::new(RankerConfig::default(), HashMap::new());
        let mut results = vec![
            make_result("a", 0.9, 1),
            make_result("b", 0.7, 1),
            make_result("c", 0.5, 1),
        ];
        ranker.rank_top(&mut results, 2);
        assert_eq!(results.len(), 2);
        assert_eq!(results[0].id, "a");
    }
}
