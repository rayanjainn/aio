/// Pure regex-based natural-language time parser. Zero LLM dependency.
///
/// Call `parse_time_expression(input)` → `Option<TimeRange>`.
/// Returns `None` if no recognised time pattern appears in the input string.
/// Use `in_range(ts, range)` to test whether a unix timestamp falls inside
/// a returned `TimeRange`.

use chrono::{DateTime, Datelike, Duration, TimeZone, Utc, Weekday};
use regex::Regex;
use std::sync::OnceLock;

/* ─── Output type ────────────────────────────────────────── */

#[derive(Debug, Clone)]
pub struct TimeRange {
    pub start_unix: i64,
    pub end_unix:   i64,
    /// Hour-of-day start (inclusive), set for sub-day patterns like "3pm".
    pub hour_start: Option<u32>,
    /// Hour-of-day end (exclusive), set for sub-day patterns.
    pub hour_end:   Option<u32>,
    pub label:      String,
}

impl TimeRange {
    /// `[now - n_days, now)` convenience constructor.
    pub fn last_n_days(n: i64, label: impl Into<String>) -> Self {
        let now = Utc::now();
        let start = now - Duration::days(n);
        Self {
            start_unix: start.timestamp(),
            end_unix:   now.timestamp(),
            hour_start: None,
            hour_end:   None,
            label:      label.into(),
        }
    }
}

/* ─── Compiled patterns ──────────────────────────────────── */

static PATTERNS: OnceLock<Vec<(Regex, &'static str)>> = OnceLock::new();

fn patterns() -> &'static Vec<(Regex, &'static str)> {
    PATTERNS.get_or_init(|| {
        vec![
            // Order matters: more-specific patterns first.
            (Regex::new(r"(?i)\bthis morning\b").unwrap(),     "this_morning"),
            (Regex::new(r"(?i)\bthis afternoon\b").unwrap(),   "this_afternoon"),
            (Regex::new(r"(?i)\bthis evening\b").unwrap(),     "this_evening"),
            (Regex::new(r"(?i)\blast (monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b").unwrap(), "last_weekday"),
            (Regex::new(r"(?i)\blast (\d+) weeks?\b").unwrap(), "last_n_weeks"),
            (Regex::new(r"(?i)\blast week\b").unwrap(),        "last_week"),
            (Regex::new(r"(?i)\blast month\b").unwrap(),       "last_month"),
            (Regex::new(r"(?i)\b(\d+) days? ago\b").unwrap(), "n_days_ago"),
            (Regex::new(r"(?i)\byesterday\b").unwrap(),        "yesterday"),
            (Regex::new(r"(?i)\btoday\b").unwrap(),            "today"),
            (Regex::new(r"(?i)\b(\d{1,2})(am|pm)\b").unwrap(), "hour"),
        ]
    })
}

/* ─── Public entry point ─────────────────────────────────── */

/// Parse a natural-language time expression embedded anywhere in `input`.
/// Returns the first (most-specific) match found.
pub fn parse_time_expression(input: &str) -> Option<TimeRange> {
    let now = Utc::now();

    for (re, kind) in patterns() {
        if let Some(caps) = re.captures(input) {
            return match *kind {
                "yesterday" => Some(day_range(now - Duration::days(1), "yesterday")),

                "today" => Some(day_range(now, "today")),

                "last_week" => Some(last_week_range(now)),

                "last_month" => Some(last_month_range(now)),

                "last_weekday" => {
                    let day_name = caps.get(1)?.as_str();
                    Some(last_weekday_range(now, day_name))
                }

                "hour" => {
                    let h: u32 = caps.get(1)?.as_str().parse().ok()?;
                    let ampm = caps.get(2)?.as_str();
                    let hour_24 = to_hour_24(h, ampm);
                    Some(hour_range(now, hour_24, &format!("{h}{ampm}")))
                }

                "n_days_ago" => {
                    let n: i64 = caps.get(1)?.as_str().parse().ok()?;
                    Some(day_range(
                        now - Duration::days(n),
                        &format!("{n} days ago"),
                    ))
                }

                "last_n_weeks" => {
                    let n: i64 = caps.get(1)?.as_str().parse().ok()?;
                    Some(TimeRange::last_n_days(n * 7, format!("last {n} weeks")))
                }

                "this_morning" => Some(TimeRange {
                    start_unix: today_at(now, 6),
                    end_unix:   today_at(now, 12),
                    hour_start: Some(6),
                    hour_end:   Some(12),
                    label:      "this morning".into(),
                }),

                "this_afternoon" => Some(TimeRange {
                    start_unix: today_at(now, 12),
                    end_unix:   today_at(now, 18),
                    hour_start: Some(12),
                    hour_end:   Some(18),
                    label:      "this afternoon".into(),
                }),

                "this_evening" => Some(TimeRange {
                    start_unix: today_at(now, 18),
                    // today_at handles hour == 24 → end of day
                    end_unix:   today_at(now, 24),
                    hour_start: Some(18),
                    hour_end:   Some(24),
                    label:      "this evening".into(),
                }),

                _ => None,
            };
        }
    }
    None
}

/* ─── Convenience predicate ──────────────────────────────── */

/// Returns `true` if `ts` falls within `[range.start_unix, range.end_unix)`.
pub fn in_range(ts: i64, range: &TimeRange) -> bool {
    ts >= range.start_unix && ts < range.end_unix
}

/* ─── Internal helpers ───────────────────────────────────── */

/// Full-day range for a given UTC instant.
fn day_range(dt: DateTime<Utc>, label: &str) -> TimeRange {
    let start = Utc
        .with_ymd_and_hms(dt.year(), dt.month(), dt.day(), 0, 0, 0)
        .single()
        .unwrap_or(dt);
    let end = start + Duration::days(1);
    TimeRange {
        start_unix: start.timestamp(),
        end_unix:   end.timestamp(),
        hour_start: None,
        hour_end:   None,
        label:      label.to_string(),
    }
}

/// Unix timestamp for `hour:00:00` on the same calendar day as `now`.
/// Passing `hour == 24` returns the timestamp for 23:00 + 3600 s (midnight).
fn today_at(now: DateTime<Utc>, hour: u32) -> i64 {
    if hour == 24 {
        let h23 = Utc
            .with_ymd_and_hms(now.year(), now.month(), now.day(), 23, 0, 0)
            .single()
            .unwrap_or(now);
        return h23.timestamp() + 3600;
    }
    Utc.with_ymd_and_hms(now.year(), now.month(), now.day(), hour, 0, 0)
        .single()
        .unwrap_or(now)
        .timestamp()
}

/// Monday-to-Sunday range of the calendar week *before* `now`'s week.
fn last_week_range(now: DateTime<Utc>) -> TimeRange {
    // ISO weekday: Mon=1 … Sun=7
    let dow = now.weekday().number_from_monday() as i64;
    // Last Monday = (today - dow - 7) days from Sunday midnight
    let last_monday = now - Duration::days(dow - 1 + 7);
    let start = Utc
        .with_ymd_and_hms(last_monday.year(), last_monday.month(), last_monday.day(), 0, 0, 0)
        .single()
        .unwrap_or(now);
    let end = start + Duration::days(7);
    TimeRange {
        start_unix: start.timestamp(),
        end_unix:   end.timestamp(),
        hour_start: None,
        hour_end:   None,
        label:      "last week".into(),
    }
}

/// First-to-last day of the month before `now`'s month.
fn last_month_range(now: DateTime<Utc>) -> TimeRange {
    let (year, month) = if now.month() == 1 {
        (now.year() - 1, 12u32)
    } else {
        (now.year(), now.month() - 1)
    };

    let start = Utc
        .with_ymd_and_hms(year, month, 1, 0, 0, 0)
        .single()
        .unwrap_or(now);

    // First day of current month = end boundary
    let end = Utc
        .with_ymd_and_hms(now.year(), now.month(), 1, 0, 0, 0)
        .single()
        .unwrap_or(now);

    TimeRange {
        start_unix: start.timestamp(),
        end_unix:   end.timestamp(),
        hour_start: None,
        hour_end:   None,
        label:      "last month".into(),
    }
}

/// Most recent occurrence of `weekday_name` strictly before today.
fn last_weekday_range(now: DateTime<Utc>, weekday_name: &str) -> TimeRange {
    let target = name_to_weekday(weekday_name);
    let today_dow = now.weekday().number_from_monday(); // Mon=1
    let target_dow = target.number_from_monday();

    // Days to go back: at least 1, at most 7.
    let days_back = if today_dow > target_dow {
        (today_dow - target_dow) as i64
    } else {
        (today_dow + 7 - target_dow) as i64
    };

    let target_day = now - Duration::days(days_back);
    let label = format!("last {weekday_name}");
    day_range(target_day, &label)
}

/// One-hour window: `[hour_24:00, hour_24:59:59]` expressed as unix range.
fn hour_range(now: DateTime<Utc>, hour_24: u32, label: &str) -> TimeRange {
    let start_ts = today_at(now, hour_24);
    let end_ts = start_ts + 3600;
    TimeRange {
        start_unix: start_ts,
        end_unix:   end_ts,
        hour_start: Some(hour_24),
        hour_end:   Some(hour_24 + 1),
        label:      label.to_string(),
    }
}

/// Convert "3pm" → 15, "12am" → 0, "12pm" → 12.
fn to_hour_24(h: u32, ampm: &str) -> u32 {
    match ampm.to_ascii_lowercase().as_str() {
        "am" => {
            if h == 12 { 0 } else { h }
        }
        _ => {
            // pm
            if h == 12 { 12 } else { h + 12 }
        }
    }
}

/// Map weekday name (case-insensitive) to chrono `Weekday`.
fn name_to_weekday(name: &str) -> Weekday {
    match name.to_ascii_lowercase().as_str() {
        "monday"    => Weekday::Mon,
        "tuesday"   => Weekday::Tue,
        "wednesday" => Weekday::Wed,
        "thursday"  => Weekday::Thu,
        "friday"    => Weekday::Fri,
        "saturday"  => Weekday::Sat,
        _           => Weekday::Sun,
    }
}

/* ─── Tests ──────────────────────────────────────────────── */

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_yesterday() {
        let r = parse_time_expression("stuff I did yesterday").unwrap();
        assert_eq!(r.label, "yesterday");
        // end - start == 86400 s
        assert_eq!(r.end_unix - r.start_unix, 86400);
    }

    #[test]
    fn parses_today() {
        let r = parse_time_expression("today's meetings").unwrap();
        assert_eq!(r.label, "today");
    }

    #[test]
    fn parses_n_days_ago() {
        let r = parse_time_expression("the file I opened 5 days ago").unwrap();
        assert_eq!(r.label, "5 days ago");
        assert_eq!(r.end_unix - r.start_unix, 86400);
    }

    #[test]
    fn parses_hour_pm() {
        let r = parse_time_expression("the build that ran at 3pm").unwrap();
        assert_eq!(r.hour_start, Some(15));
        assert_eq!(r.hour_end, Some(16));
        assert_eq!(r.end_unix - r.start_unix, 3600);
    }

    #[test]
    fn parses_hour_am_noon() {
        // 12am → midnight (hour 0)
        let r = parse_time_expression("at 12am").unwrap();
        assert_eq!(r.hour_start, Some(0));
    }

    #[test]
    fn parses_this_morning() {
        let r = parse_time_expression("this morning's standup").unwrap();
        assert_eq!(r.hour_start, Some(6));
        assert_eq!(r.hour_end, Some(12));
    }

    #[test]
    fn parses_this_afternoon() {
        let r = parse_time_expression("this afternoon").unwrap();
        assert_eq!(r.hour_start, Some(12));
        assert_eq!(r.hour_end, Some(18));
    }

    #[test]
    fn parses_this_evening() {
        let r = parse_time_expression("this evening").unwrap();
        assert_eq!(r.hour_start, Some(18));
        assert_eq!(r.hour_end, Some(24));
    }

    #[test]
    fn parses_last_week() {
        let r = parse_time_expression("last week's sprint").unwrap();
        assert_eq!(r.label, "last week");
        assert_eq!(r.end_unix - r.start_unix, 7 * 86400);
    }

    #[test]
    fn parses_last_n_weeks() {
        let r = parse_time_expression("last 3 weeks").unwrap();
        assert_eq!(r.label, "last 3 weeks");
    }

    #[test]
    fn parses_last_month() {
        let r = parse_time_expression("invoices from last month").unwrap();
        assert_eq!(r.label, "last month");
        assert!(r.end_unix > r.start_unix);
    }

    #[test]
    fn parses_last_weekday() {
        let r = parse_time_expression("notes from last Tuesday").unwrap();
        assert!(r.label.to_lowercase().contains("tuesday"));
        assert_eq!(r.end_unix - r.start_unix, 86400);
    }

    #[test]
    fn no_match_returns_none() {
        assert!(parse_time_expression("show me my files").is_none());
    }

    #[test]
    fn in_range_works() {
        let r = TimeRange::last_n_days(7, "last 7 days");
        let now = Utc::now().timestamp();
        assert!(in_range(now - 100, &r));
        assert!(!in_range(now + 100, &r));
        assert!(!in_range(r.start_unix - 1, &r));
    }
}
