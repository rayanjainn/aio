/// Session graph — groups all source events by time window into named sessions.
/// A session = contiguous block of activity (gap > 5 min = new session).

#[allow(unused_imports)]
use anyhow::Result;
use chrono::{DateTime, Utc};
use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};
use std::{path::PathBuf, sync::Mutex};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionRecord {
    pub id:          String,
    pub start_time:  DateTime<Utc>,
    pub end_time:    Option<DateTime<Utc>>,
    pub primary_app: String,
    pub bundle_id:   String,
    pub label:       String,
    pub frame_count: i64,
    pub apps:        Vec<String>,
    pub urls:        Vec<String>,
    pub files:       Vec<String>,
    pub commands:    Vec<String>,
}

/// A single captured moment — what was on screen, where, and when.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FrameHit {
    pub timestamp:    i64,
    pub app_name:     String,
    pub window_title: String,
    pub url:          Option<String>,
    pub snippet:      String,
}

/// Extract ~200 chars of OCR text centered on the first match of `query`.
fn snippet_around(text: &str, query: &str) -> String {
    let lower = text.to_lowercase();
    let q = query.to_lowercase();
    let start = lower.find(&q).map(|i| i.saturating_sub(80)).unwrap_or(0);
    let slice: String = text.chars().skip(start).take(200).collect();
    slice.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// `Mutex<Connection>` makes SessionGraph Send + Sync.
pub struct SessionGraph {
    conn: Mutex<Connection>,
}

impl SessionGraph {
    pub fn new(data_dir: PathBuf) -> Result<Self> {
        std::fs::create_dir_all(&data_dir)?;
        let conn = Connection::open(data_dir.join("sessions.db"))?;
        conn.execute_batch("
            PRAGMA journal_mode=WAL;
            PRAGMA synchronous=NORMAL;

            CREATE TABLE IF NOT EXISTS sessions (
                id            TEXT PRIMARY KEY,
                start_unix    INTEGER NOT NULL,
                end_unix      INTEGER,
                primary_app   TEXT NOT NULL DEFAULT '',
                bundle_id     TEXT NOT NULL DEFAULT '',
                urls_json     TEXT NOT NULL DEFAULT '[]',
                frame_count   INTEGER NOT NULL DEFAULT 0,
                label         TEXT NOT NULL DEFAULT '',

                -- Legacy columns kept for backward compat with old code paths
                start_time    INTEGER,
                end_time      INTEGER
            );

            CREATE TABLE IF NOT EXISTS session_events (
                id         TEXT PRIMARY KEY,
                session_id TEXT NOT NULL,
                kind       TEXT NOT NULL,
                value      TEXT NOT NULL,
                ts         INTEGER NOT NULL,
                FOREIGN KEY (session_id) REFERENCES sessions(id)
            );

            CREATE TABLE IF NOT EXISTS frames (
                id           INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id   TEXT NOT NULL,
                timestamp    INTEGER NOT NULL,
                ocr_text     TEXT NOT NULL DEFAULT '',
                app_name     TEXT NOT NULL DEFAULT '',
                window_title TEXT NOT NULL DEFAULT '',
                url          TEXT,
                FOREIGN KEY (session_id) REFERENCES sessions(id)
            );

            CREATE INDEX IF NOT EXISTS ev_session  ON session_events(session_id);
            CREATE INDEX IF NOT EXISTS ev_ts       ON session_events(ts);
            CREATE INDEX IF NOT EXISTS ses_start   ON sessions(start_unix);
            CREATE INDEX IF NOT EXISTS frames_session ON frames(session_id);
            CREATE INDEX IF NOT EXISTS frames_ts      ON frames(timestamp);
            CREATE INDEX IF NOT EXISTS frames_text    ON frames(ocr_text);
        ")?;

        // Migrate older databases that predate these columns (CREATE IF NOT
        // EXISTS won't add them). Errors mean the column already exists → ignore.
        for stmt in [
            "ALTER TABLE sessions ADD COLUMN start_time INTEGER",
            "ALTER TABLE sessions ADD COLUMN end_time INTEGER",
            "ALTER TABLE sessions ADD COLUMN urls_json TEXT NOT NULL DEFAULT '[]'",
            "ALTER TABLE sessions ADD COLUMN frame_count INTEGER NOT NULL DEFAULT 0",
        ] {
            let _ = conn.execute(stmt, []);
        }
        Ok(Self { conn: Mutex::new(conn) })
    }

    // -------------------------------------------------------------------------
    // Legacy methods — kept fully intact
    // -------------------------------------------------------------------------

    pub fn open_session(&self) -> Result<String> {
        let id  = uuid::Uuid::new_v4().to_string();
        let now = Utc::now().timestamp();
        self.conn.lock().unwrap().execute(
            "INSERT INTO sessions (id, start_unix, start_time) VALUES (?1, ?2, ?2)",
            params![id, now],
        )?;
        Ok(id)
    }

    pub fn close_session(&self, id: &str) -> Result<()> {
        let now = Utc::now().timestamp();
        let conn = self.conn.lock().unwrap();
        let label: String = conn.query_row(
            "SELECT value FROM session_events
             WHERE session_id = ?1 AND kind = 'app'
             GROUP BY value ORDER BY COUNT(*) DESC LIMIT 1",
            params![id],
            |row| row.get(0),
        ).unwrap_or_else(|_| "session".to_string());

        conn.execute(
            "UPDATE sessions SET end_unix = ?1, end_time = ?1, label = ?2 WHERE id = ?3",
            params![now, label, id],
        )?;
        Ok(())
    }

    pub fn record_event(&self, session_id: &str, kind: &str, value: &str) -> Result<()> {
        let id  = uuid::Uuid::new_v4().to_string();
        let now = Utc::now().timestamp();
        self.conn.lock().unwrap().execute(
            "INSERT OR IGNORE INTO session_events (id, session_id, kind, value, ts)
             VALUES (?1, ?2, ?3, ?4, ?5)",
            params![id, session_id, kind, value, now],
        )?;
        Ok(())
    }

    pub fn sessions_in_range(
        &self,
        after:  DateTime<Utc>,
        before: DateTime<Utc>,
    ) -> Result<Vec<SessionRecord>> {
        self.get_sessions_in_range(after.timestamp(), before.timestamp())
    }

    pub fn recent_sessions(&self, n: usize) -> Result<Vec<SessionRecord>> {
        let after  = DateTime::from_timestamp(0, 0).unwrap().with_timezone(&Utc);
        let before = Utc::now();
        let mut all = self.sessions_in_range(after, before)?;
        all.truncate(n);
        Ok(all)
    }

    // -------------------------------------------------------------------------
    // New methods
    // -------------------------------------------------------------------------

    /// Insert a captured frame into the frames table.
    pub fn insert_frame(
        &self,
        session_id:   &str,
        timestamp:    i64,
        ocr_text:     &str,
        app_name:     &str,
        window_title: &str,
        url:          Option<&str>,
    ) -> Result<i64> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "INSERT INTO frames (session_id, timestamp, ocr_text, app_name, window_title, url)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![session_id, timestamp, ocr_text, app_name, window_title, url],
        )?;
        let rowid = conn.last_insert_rowid();

        // Bump frame_count on the parent session.
        conn.execute(
            "UPDATE sessions SET frame_count = frame_count + 1 WHERE id = ?1",
            params![session_id],
        )?;

        Ok(rowid)
    }

    /// Session boundary detection: create a new session if the last frame was
    /// >5 min ago or the active app changed.  Returns (session_id, is_new).
    pub fn get_or_create_session(
        &self,
        app_name:  &str,
        bundle_id: &str,
    ) -> Result<(String, bool)> {
        let conn = self.conn.lock().unwrap();
        let five_min_ago = Utc::now().timestamp() - 300;

        // Look for an open session (no end_unix) that was active in the last 5 min
        // and is for the same primary app.
        let row: Option<(String, String)> = conn
            .query_row(
                "SELECT id, primary_app FROM sessions
                 WHERE end_unix IS NULL
                   AND primary_app = ?1
                   AND start_unix >= ?2
                 ORDER BY start_unix DESC
                 LIMIT 1",
                params![app_name, five_min_ago],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .ok();

        // Also check: there's an open session recently updated via frames.
        // We reuse the start_unix check above; if no row found, create new.
        if let Some((id, _)) = row {
            return Ok((id, false));
        }

        // Close any open sessions for this bundle first (app switched).
        let now = Utc::now().timestamp();
        conn.execute(
            "UPDATE sessions SET end_unix = ?1, end_time = ?1 WHERE end_unix IS NULL",
            params![now],
        )?;

        // Open a new session.
        let id = uuid::Uuid::new_v4().to_string();
        conn.execute(
            "INSERT INTO sessions (id, start_unix, start_time, primary_app, bundle_id, label)
             VALUES (?1, ?2, ?2, ?3, ?4, ?3)",
            params![id, now, app_name, bundle_id],
        )?;

        Ok((id, true))
    }

    /// Get sessions whose time range overlaps [start_unix, end_unix].
    pub fn get_sessions_in_range(
        &self,
        start_unix: i64,
        end_unix:   i64,
    ) -> Result<Vec<SessionRecord>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(
            "SELECT s.id, s.start_unix, s.end_unix, s.primary_app, s.bundle_id,
                    s.label, s.frame_count, s.urls_json
             FROM sessions s
             WHERE s.start_unix <= ?2 AND (s.end_unix IS NULL OR s.end_unix >= ?1)
             ORDER BY s.start_unix DESC
             LIMIT 200",
        )?;

        let rows: Vec<(String, i64, Option<i64>, String, String, String, i64, String)> = stmt
            .query_map(params![start_unix, end_unix], |row| {
                Ok((
                    row.get(0)?,
                    row.get(1)?,
                    row.get(2)?,
                    row.get(3)?,
                    row.get(4)?,
                    row.get(5)?,
                    row.get(6)?,
                    row.get(7)?,
                ))
            })?
            .filter_map(|r| r.ok())
            .collect();
        drop(stmt);

        let mut records = Vec::new();
        for (id, start, end, primary_app, bundle_id, label, frame_count, urls_json) in rows {
            let events = self.load_events_locked(&conn, &id)?;
            let urls: Vec<String> = serde_json::from_str(&urls_json).unwrap_or_default();
            records.push(SessionRecord {
                id,
                start_time:  DateTime::from_timestamp(start, 0)
                    .unwrap_or_default()
                    .with_timezone(&Utc),
                end_time:    end
                    .and_then(|e| DateTime::from_timestamp(e, 0))
                    .map(|dt| dt.with_timezone(&Utc)),
                primary_app,
                bundle_id,
                label,
                frame_count,
                apps:     events.iter().filter(|(k, _)| k == "app").map(|(_, v)| v.clone()).collect(),
                urls,
                files:    events.iter().filter(|(k, _)| k == "file").map(|(_, v)| v.clone()).collect(),
                commands: events.iter().filter(|(k, _)| k == "command").map(|(_, v)| v.clone()).collect(),
            });
        }
        Ok(records)
    }

    /// Full-text search over frames.ocr_text; returns sessions that contain
    /// at least one matching frame.
    pub fn search_sessions_by_text(&self, query: &str) -> Result<Vec<SessionRecord>> {
        let conn = self.conn.lock().unwrap();

        // SQLite LIKE search — good enough without FTS5 extension.
        let pattern = format!("%{}%", query.replace('%', "\\%").replace('_', "\\_"));

        let mut stmt = conn.prepare(
            "SELECT DISTINCT s.id, s.start_unix, s.end_unix, s.primary_app, s.bundle_id,
                    s.label, s.frame_count, s.urls_json
             FROM sessions s
             JOIN frames f ON f.session_id = s.id
             WHERE f.ocr_text LIKE ?1 ESCAPE '\\'
             ORDER BY s.start_unix DESC
             LIMIT 50",
        )?;

        let rows: Vec<(String, i64, Option<i64>, String, String, String, i64, String)> = stmt
            .query_map(params![pattern], |row| {
                Ok((
                    row.get(0)?,
                    row.get(1)?,
                    row.get(2)?,
                    row.get(3)?,
                    row.get(4)?,
                    row.get(5)?,
                    row.get(6)?,
                    row.get(7)?,
                ))
            })?
            .filter_map(|r| r.ok())
            .collect();
        drop(stmt);

        let mut records = Vec::new();
        for (id, start, end, primary_app, bundle_id, label, frame_count, urls_json) in rows {
            let events = self.load_events_locked(&conn, &id)?;
            let urls: Vec<String> = serde_json::from_str(&urls_json).unwrap_or_default();
            records.push(SessionRecord {
                id,
                start_time:  DateTime::from_timestamp(start, 0)
                    .unwrap_or_default()
                    .with_timezone(&Utc),
                end_time:    end
                    .and_then(|e| DateTime::from_timestamp(e, 0))
                    .map(|dt| dt.with_timezone(&Utc)),
                primary_app,
                bundle_id,
                label,
                frame_count,
                apps:     events.iter().filter(|(k, _)| k == "app").map(|(_, v)| v.clone()).collect(),
                urls,
                files:    events.iter().filter(|(k, _)| k == "file").map(|(_, v)| v.clone()).collect(),
                commands: events.iter().filter(|(k, _)| k == "command").map(|(_, v)| v.clone()).collect(),
            });
        }
        Ok(records)
    }

    /// Frame-level full-text search — returns individual captured moments
    /// (app, window, url, OCR snippet, time) matching `query`, newest first.
    pub fn search_frames(&self, query: &str, limit: usize) -> Result<Vec<FrameHit>> {
        let conn = self.conn.lock().unwrap();
        let pattern = format!("%{}%", query.replace('%', "\\%").replace('_', "\\_"));
        let mut stmt = conn.prepare(
            "SELECT timestamp, app_name, window_title, url, ocr_text
             FROM frames WHERE ocr_text LIKE ?1 ESCAPE '\\' OR window_title LIKE ?1 ESCAPE '\\'
             ORDER BY timestamp DESC LIMIT ?2",
        )?;
        let hits = stmt.query_map(params![pattern, limit as i64], |r| {
            Ok(FrameHit {
                timestamp:    r.get(0)?,
                app_name:     r.get(1)?,
                window_title: r.get(2)?,
                url:          r.get(3)?,
                snippet:      snippet_around(&r.get::<_, String>(4)?, query),
            })
        })?.filter_map(|r| r.ok()).collect();
        Ok(hits)
    }

    /// All frames within a unix-time range (for the Rewind timeline), newest first.
    pub fn frames_in_range(&self, start: i64, end: i64, limit: usize) -> Result<Vec<FrameHit>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(
            "SELECT timestamp, app_name, window_title, url, ocr_text
             FROM frames WHERE timestamp BETWEEN ?1 AND ?2
             ORDER BY timestamp DESC LIMIT ?3",
        )?;
        let hits = stmt.query_map(params![start, end, limit as i64], |r| {
            Ok(FrameHit {
                timestamp:    r.get(0)?,
                app_name:     r.get(1)?,
                window_title: r.get(2)?,
                url:          r.get(3)?,
                snippet:      r.get::<_, String>(4)?.chars().take(180).collect(),
            })
        })?.filter_map(|r| r.ok()).collect();
        Ok(hits)
    }

    /// Update a session's end_unix, frame_count, and merge any new URL into urls_json.
    pub fn touch_session(
        &self,
        session_id: &str,
        app_name:   &str,
        bundle_id:  &str,
        url:        Option<&str>,
    ) -> Result<()> {
        let conn = self.conn.lock().unwrap();
        let now  = Utc::now().timestamp();

        // Merge url into urls_json if supplied.
        if let Some(u) = url {
            // Read existing json array, push new url if not already present.
            let existing_json: String = conn
                .query_row(
                    "SELECT urls_json FROM sessions WHERE id = ?1",
                    params![session_id],
                    |row| row.get(0),
                )
                .unwrap_or_else(|_| "[]".to_string());

            let mut urls: Vec<String> =
                serde_json::from_str(&existing_json).unwrap_or_default();
            if !urls.contains(&u.to_string()) {
                urls.push(u.to_string());
            }
            let new_json = serde_json::to_string(&urls).unwrap_or_else(|_| "[]".to_string());

            conn.execute(
                "UPDATE sessions
                 SET end_unix = ?1, end_time = ?1,
                     primary_app = ?2, bundle_id = ?3, urls_json = ?4
                 WHERE id = ?5",
                params![now, app_name, bundle_id, new_json, session_id],
            )?;
        } else {
            conn.execute(
                "UPDATE sessions
                 SET end_unix = ?1, end_time = ?1,
                     primary_app = ?2, bundle_id = ?3
                 WHERE id = ?4",
                params![now, app_name, bundle_id, session_id],
            )?;
        }

        Ok(())
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    fn load_events_locked(
        &self,
        conn:       &Connection,
        session_id: &str,
    ) -> Result<Vec<(String, String)>> {
        let mut stmt = conn.prepare(
            "SELECT kind, value FROM session_events WHERE session_id = ?1 ORDER BY ts",
        )?;
        let events = stmt
            .query_map(params![session_id], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })?
            .filter_map(|r| r.ok())
            .collect();
        Ok(events)
    }
}
