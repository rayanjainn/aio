/// Calendar plugin — Google Calendar (OAuth2) + Apple Calendar (.ics walk).
///
/// Schema (~/.cortex/calendar.db):
///   events: event_id TEXT PK, source TEXT, title TEXT, description TEXT,
///           start_unix INTEGER, end_unix INTEGER, attendees_json TEXT,
///           location TEXT, calendar_name TEXT
///
/// Sync window: past 6 months + next 3 months.
/// Google:      REST API, refreshes OAuth2 tokens automatically.
/// Apple:       walks ~/Library/Calendars/ for .ics files, parses with icalendar crate.
///              notify watcher triggers incremental re-parse on .ics changes.

use anyhow::Result;
use async_trait::async_trait;
use chrono::{DateTime, Duration, Utc};
use fuzzy_matcher::{skim::SkimMatcherV2, FuzzyMatcher};
use icalendar::{Calendar, CalendarComponent, CalendarDateTime, Component, DatePerhapsTime, EventLike};
use serde::Deserialize;
use std::path::PathBuf;
use tokio::sync::RwLock;
use walkdir::WalkDir;

use crate::plugin::{Plugin, ResultAction, SearchQuery, SearchResult, SourceType};

const COLLECTION:     &str = "cortex_calendar";

/* ─── SQLite init ───────────────────────────────────────── */

const INIT_SQL: &str = "
CREATE TABLE IF NOT EXISTS events (
    event_id       TEXT PRIMARY KEY,
    source         TEXT NOT NULL,
    title          TEXT NOT NULL,
    description    TEXT,
    start_unix     INTEGER,
    end_unix       INTEGER,
    attendees_json TEXT,
    location       TEXT,
    calendar_name  TEXT
);
CREATE INDEX IF NOT EXISTS events_start ON events(start_unix DESC);
";

/* ─── In-memory cache ───────────────────────────────────── */

#[derive(Debug, Clone)]
pub struct CalEvent {
    pub event_id:      String,
    pub source:        String,
    pub title:         String,
    pub description:   Option<String>,
    pub start:         Option<DateTime<Utc>>,
    pub end:           Option<DateTime<Utc>>,
    pub attendees:     Vec<String>,
    pub location:      Option<String>,
    pub calendar_name: Option<String>,
}

/* ─── Plugin ─────────────────────────────────────────────── */

pub struct CalendarPlugin {
    db_path: PathBuf,
    cache:   RwLock<Vec<CalEvent>>,
    matcher: SkimMatcherV2,
    http:    reqwest::Client,
}

impl CalendarPlugin {
    pub fn new(data_dir: PathBuf) -> Result<Self> {
        std::fs::create_dir_all(&data_dir)?;
        let db_path = data_dir.join("calendar.db");
        let conn = rusqlite::Connection::open(&db_path)?;
        conn.execute_batch(INIT_SQL)?;
        Ok(Self {
            db_path,
            cache:   RwLock::new(Vec::new()),
            matcher: SkimMatcherV2::default(),
            http:    reqwest::Client::new(),
        })
    }

    /* ── Google Calendar ─────────────────────────────────── */

    async fn sync_google(&self) -> Result<usize> {
        let token = match crate::auth::get_valid_access_token().await {
            Ok(t)  => t,
            Err(e) => {
                tracing::info!("calendar: Google not connected ({e}) — skipping");
                return Ok(0);
            }
        };

        let now       = Utc::now();
        let time_min  = (now - Duration::days(180)).to_rfc3339();
        let time_max  = (now + Duration::days(90)).to_rfc3339();

        // Get all calendar list first
        let cal_list = self.gcal_calendars(&token).await?;
        let mut total = 0usize;

        for (cal_id, cal_name) in &cal_list {
            let events = self.gcal_events(&token, cal_id, &time_min, &time_max).await?;
            let count  = events.len();
            for ev in events {
                self.upsert_event(&CalEvent {
                    calendar_name: Some(cal_name.clone()),
                    ..ev
                })?;
            }
            total += count;
        }

        tracing::info!("calendar: synced {total} Google events across {} calendars", cal_list.len());
        Ok(total)
    }

    async fn gcal_calendars(&self, token: &str) -> Result<Vec<(String, String)>> {
        #[derive(Deserialize)]
        struct Item { id: String, summary: String }
        #[derive(Deserialize)]
        struct Resp { items: Vec<Item> }

        let r = self.http
            .get("https://www.googleapis.com/calendar/v3/users/me/calendarList")
            .bearer_auth(token)
            .send().await?;
        if r.status() == reqwest::StatusCode::FORBIDDEN || r.status() == reqwest::StatusCode::UNAUTHORIZED {
            anyhow::bail!("Calendar scope not granted — reconnect Google in Settings (Connect Google)");
        }
        if !r.status().is_success() {
            anyhow::bail!("Google Calendar API {}", r.status());
        }
        let resp: Resp = r.json().await?;
        Ok(resp.items.into_iter().map(|i| (i.id, i.summary)).collect())
    }

    async fn gcal_events(
        &self, token: &str, calendar_id: &str,
        time_min: &str, time_max: &str,
    ) -> Result<Vec<CalEvent>> {
        #[derive(Deserialize, Default)]
        #[serde(rename_all = "camelCase")]
        struct GAttendee { email: Option<String> }

        #[derive(Deserialize, Default)]
        struct GDateTime {
            #[serde(rename = "dateTime")]
            date_time: Option<String>,
            date:      Option<String>,
        }

        #[derive(Deserialize)]
        struct GEvent {
            id:          String,
            summary:     Option<String>,
            description: Option<String>,
            start:       Option<GDateTime>,
            end:         Option<GDateTime>,
            attendees:   Option<Vec<GAttendee>>,
            location:    Option<String>,
        }

        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct GEventsResp {
            items:           Vec<GEvent>,
            next_page_token: Option<String>,
        }

        let enc_id = urlencoding::encode(calendar_id);
        let mut all = Vec::new();
        let mut page_token: Option<String> = None;

        loop {
            let mut url = format!(
                "https://www.googleapis.com/calendar/v3/calendars/{enc_id}/events\
                 ?timeMin={time_min}&timeMax={time_max}&singleEvents=true&maxResults=2500",
            );
            if let Some(pt) = &page_token {
                url.push_str(&format!("&pageToken={pt}"));
            }

            let resp: GEventsResp = self.http.get(&url).bearer_auth(token).send().await?
                .json().await?;

            for gev in resp.items {
                let start = gev.start.as_ref().and_then(|d| parse_gdt(d.date_time.as_deref(), d.date.as_deref()));
                let end   = gev.end.as_ref().and_then(|d| parse_gdt(d.date_time.as_deref(), d.date.as_deref()));
                let attendees: Vec<String> = gev.attendees.unwrap_or_default()
                    .into_iter()
                    .filter_map(|a| a.email)
                    .collect();
                all.push(CalEvent {
                    event_id:      gev.id,
                    source:        "google".to_string(),
                    title:         gev.summary.unwrap_or_default(),
                    description:   gev.description,
                    start,
                    end,
                    attendees,
                    location:      gev.location,
                    calendar_name: None,
                });
            }

            match resp.next_page_token {
                Some(pt) => page_token = Some(pt),
                None     => break,
            }
        }
        Ok(all)
    }

    /* ── Apple Calendar (.ics) ───────────────────────────── */

    fn sync_apple(&self) -> Result<usize> {
        let home = dirs::home_dir().unwrap_or_default();
        let cal_root = home.join("Library/Calendars");
        if !cal_root.exists() { return Ok(0); }

        let mut count = 0usize;
        for entry in WalkDir::new(&cal_root)
            .follow_links(false)
            .into_iter()
            .filter_map(|e| e.ok())
            .filter(|e| e.path().extension().map(|x| x == "ics").unwrap_or(false))
        {
            let content = match std::fs::read_to_string(entry.path()) {
                Ok(c)  => c,
                Err(_) => continue,
            };
            let cal_name = entry.path()
                .ancestors()
                .find(|p| p.extension().map(|x| x == "calendar").unwrap_or(false))
                .and_then(|p| p.file_stem())
                .map(|s| s.to_string_lossy().to_string());

            match content.parse::<Calendar>() {
                Ok(cal) => {
                    for component in cal.iter() {
                        if let Some(ev) = component_to_event(component, cal_name.clone()) {
                            let _ = self.upsert_event(&ev);
                            count += 1;
                        }
                    }
                }
                Err(e) => tracing::debug!("ics parse {}: {e}", entry.path().display()),
            }
        }
        tracing::info!("calendar: indexed {count} Apple Calendar events");
        Ok(count)
    }

    /* ── SQLite ──────────────────────────────────────────── */

    fn upsert_event(&self, ev: &CalEvent) -> Result<()> {
        let conn = rusqlite::Connection::open(&self.db_path)?;
        let attendees_json = serde_json::to_string(&ev.attendees).unwrap_or_default();
        conn.execute(
            "INSERT OR REPLACE INTO events
             (event_id, source, title, description, start_unix, end_unix,
              attendees_json, location, calendar_name)
             VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9)",
            rusqlite::params![
                ev.event_id,
                ev.source,
                ev.title,
                ev.description,
                ev.start.map(|t| t.timestamp()),
                ev.end.map(|t| t.timestamp()),
                attendees_json,
                ev.location,
                ev.calendar_name,
            ],
        )?;
        Ok(())
    }

    fn load_events(db_path: &PathBuf, limit: usize) -> Vec<CalEvent> {
        let Ok(conn) = rusqlite::Connection::open(db_path) else { return vec![] };
        let Ok(mut stmt) = conn.prepare(
            "SELECT event_id, source, title, description, start_unix, end_unix,
                    attendees_json, location, calendar_name
             FROM events ORDER BY start_unix DESC LIMIT ?1"
        ) else { return vec![] };

        let rows = stmt.query_map([limit as i64], |row| {
            let attendees: Vec<String> = row.get::<_, Option<String>>(6)?
                .and_then(|s| serde_json::from_str(&s).ok())
                .unwrap_or_default();
            Ok(CalEvent {
                event_id:      row.get(0)?,
                source:        row.get(1)?,
                title:         row.get(2)?,
                description:   row.get(3)?,
                start:         row.get::<_, Option<i64>>(4)?
                                   .and_then(|t| DateTime::from_timestamp(t, 0))
                                   .map(|dt| dt.with_timezone(&Utc)),
                end:           row.get::<_, Option<i64>>(5)?
                                   .and_then(|t| DateTime::from_timestamp(t, 0))
                                   .map(|dt| dt.with_timezone(&Utc)),
                attendees,
                location:      row.get(7)?,
                calendar_name: row.get(8)?,
            })
        });
        match rows {
            Ok(mapped) => mapped.filter_map(|r| r.ok()).collect(),
            Err(_)     => vec![],
        }
    }
}

/* ─── Plugin impl ───────────────────────────────────────── */

#[async_trait]
impl Plugin for CalendarPlugin {
    fn id(&self)   -> &str { "calendar" }
    fn name(&self) -> &str { "Calendar" }
    fn icon(&self) -> &str { "📅" }

    async fn count(&self) -> u64 {
        let db = self.db_path.clone();
        tokio::task::spawn_blocking(move || {
            rusqlite::Connection::open(&db).ok()
                .and_then(|c| c.query_row("SELECT COUNT(*) FROM events", [], |r| r.get::<_, i64>(0)).ok())
                .unwrap_or(0) as u64
        }).await.unwrap_or(0)
    }

    async fn sync(&self) -> Result<usize> {
        // Google Calendar (async, may open browser on first run)
        let google_count = self.sync_google().await.unwrap_or_else(|e| {
            tracing::warn!("google calendar sync: {e}");
            0
        });

        // Apple Calendar (sync FS walk on blocking thread)
        let db = self.db_path.clone();
        let apple_count = tokio::task::spawn_blocking({
            let plugin_db = db.clone();
            move || {
                // Construct a fresh plugin with same db_path for sync
                let p = CalendarPlugin {
                    db_path: plugin_db,
                    cache:   RwLock::new(vec![]),
                    matcher: SkimMatcherV2::default(),
                    http:    reqwest::Client::new(),
                };
                p.sync_apple().unwrap_or(0)
            }
        }).await.unwrap_or(0);

        let total = google_count + apple_count;

        // Refresh in-memory cache
        let events = Self::load_events(&self.db_path, 10_000);
        *self.cache.write().await = events;
        Ok(total)
    }

    async fn search(&self, query: &SearchQuery) -> Result<Vec<SearchResult>> {
        let cache = self.cache.read().await;
        let q = &query.raw;

        let mut scored: Vec<(i64, &CalEvent)> = cache.iter().filter_map(|ev| {
            let ts = self.matcher.fuzzy_match(&ev.title, q).unwrap_or(0);
            let ds = ev.description.as_deref()
                .and_then(|d| self.matcher.fuzzy_match(d, q))
                .unwrap_or(0);
            let ls = ev.location.as_deref()
                .and_then(|l| self.matcher.fuzzy_match(l, q))
                .unwrap_or(0);
            let as_ = ev.attendees.iter()
                .filter_map(|a| self.matcher.fuzzy_match(a, q))
                .max()
                .unwrap_or(0);
            let best = ts.max(ds).max(ls).max(as_);
            if best > 20 { Some((best, ev)) } else { None }
        }).collect();

        scored.sort_unstable_by(|a, b| b.0.cmp(&a.0));
        scored.truncate(15);

        Ok(scored.into_iter().map(|(score, ev)| {
            let subtitle = match (&ev.calendar_name, &ev.location) {
                (Some(c), Some(l)) => Some(format!("{c} · {l}")),
                (Some(c), None)    => Some(c.clone()),
                (None, Some(l))    => Some(l.clone()),
                _                  => None,
            };
            let mut r = SearchResult::new("calendar", &ev.title);
            r.source_type = SourceType::Unknown;
            r.subtitle    = subtitle;
            r.content     = ev.description.clone();
            r.timestamp   = ev.start;
            r.score       = (score as f32 / 300.0).min(0.95);
            r.action      = ResultAction::Open;
            r.metadata.insert("source".into(), ev.source.as_str().into());
            r.metadata.insert("attendees".into(), ev.attendees.join(", ").into());
            if let Some(loc) = &ev.location {
                r.metadata.insert("location".into(), loc.as_str().into());
            }
            r
        }).collect())
    }

    async fn execute(&self, result: &SearchResult) -> Result<()> {
        // Open Google Calendar or Calendar.app
        if result.metadata.get("source").and_then(|v| v.as_str()) == Some("google") {
            webbrowser::open("https://calendar.google.com")?;
        } else {
            #[cfg(target_os = "macos")]
            std::process::Command::new("open")
                .args(["-a", "Calendar"]).spawn()?;
        }
        Ok(())
    }
}

/* ─── Helpers ───────────────────────────────────────────── */

/// Parse dateTime ("RFC3339") or date ("YYYY-MM-DD") → UTC.
fn parse_gdt(date_time: Option<&str>, date: Option<&str>) -> Option<DateTime<Utc>> {
    if let Some(s) = date_time {
        return DateTime::parse_from_rfc3339(s).ok().map(|dt| dt.with_timezone(&Utc));
    }
    if let Some(s) = date {
        use chrono::NaiveDate;
        return NaiveDate::parse_from_str(s, "%Y-%m-%d").ok()
            .and_then(|nd| nd.and_hms_opt(0, 0, 0))
            .map(|ndt| DateTime::from_naive_utc_and_offset(ndt, Utc));
    }
    None
}

fn component_to_event(comp: &CalendarComponent, cal_name: Option<String>) -> Option<CalEvent> {
    let ev = comp.as_event()?;
    let title = ev.get_summary()?.to_string();
    let event_id = ev.get_uid()
        .map(|s| s.to_string())
        .unwrap_or_else(|| uuid::Uuid::new_v4().to_string());

    let start = ev.get_start().and_then(dptime_to_utc);
    let end   = ev.get_end().and_then(dptime_to_utc);

    let attendees: Vec<String> = ev.property_value("ATTENDEE")
        .map(|v| vec![v.to_string()])
        .unwrap_or_default();

    Some(CalEvent {
        event_id,
        source:        "apple".to_string(),
        title,
        description:   ev.get_description().map(|s| s.to_string()),
        start,
        end,
        attendees,
        location:      ev.get_location().map(|s| s.to_string()),
        calendar_name: cal_name,
    })
}

fn dptime_to_utc(dp: DatePerhapsTime) -> Option<DateTime<Utc>> {
    use icalendar::DatePerhapsTime::*;
    use chrono::{Datelike, TimeZone};
    match dp {
        DateTime(cdt) => match cdt {
            CalendarDateTime::Utc(dt)            => Some(dt),
            CalendarDateTime::Floating(naive)    => Some(chrono::DateTime::from_naive_utc_and_offset(naive, Utc)),
            CalendarDateTime::WithTimezone { date_time, .. } =>
                Some(chrono::DateTime::from_naive_utc_and_offset(date_time, Utc)),
        },
        Date(d) => Utc.with_ymd_and_hms(d.year(), d.month(), d.day(), 0, 0, 0).single(),
    }
}

mod urlencoding {
    pub fn encode(s: &str) -> String {
        let mut out = String::new();
        for b in s.bytes() {
            match b {
                b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                    out.push(b as char);
                }
                _ => out.push_str(&format!("%{b:02X}")),
            }
        }
        out
    }
}
