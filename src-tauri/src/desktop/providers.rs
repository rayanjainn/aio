//! Live data for desktop widgets and the dock: system stats, battery, now
//! playing, weather, agenda, git, Docker, GitHub activity, photos, apps.
//! Every command degrades to an empty/"unavailable" value instead of erroring,
//! so a widget never shows a stack trace.

use serde::Serialize;
use std::{
    collections::HashMap,
    sync::{Mutex, OnceLock},
    time::{Duration, Instant},
};

/* ─── System stats ──────────────────────────────────────── */

#[derive(Debug, Clone, Serialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct Battery {
    pub percent:      f32,
    pub charging:     bool,
    /// None while calculating / on AC.
    pub minutes_left: Option<u32>,
}

#[derive(Debug, Clone, Serialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct SysStats {
    pub cpu:        f32,
    pub cores:      Vec<f32>,
    pub mem_used:   u64,
    pub mem_total:  u64,
    pub disk_used:  u64,
    pub disk_total: u64,
    /// Bytes/second since the previous sample.
    pub net_rx:     u64,
    pub net_tx:     u64,
    pub battery:    Option<Battery>,
    pub uptime:     u64,
    pub load:       [f64; 3],
}

struct Sampler {
    sys:      sysinfo::System,
    nets:     sysinfo::Networks,
    last_net: Instant,
    battery:  (Instant, Option<Battery>),
}

fn sampler() -> &'static Mutex<Sampler> {
    static S: OnceLock<Mutex<Sampler>> = OnceLock::new();
    S.get_or_init(|| {
        let mut sys = sysinfo::System::new();
        sys.refresh_cpu_usage();
        sys.refresh_memory();
        Mutex::new(Sampler {
            sys,
            nets: sysinfo::Networks::new_with_refreshed_list(),
            last_net: Instant::now(),
            battery: (Instant::now() - Duration::from_secs(3600), None),
        })
    })
}

#[tauri::command]
pub async fn sys_stats() -> SysStats {
    tokio::task::spawn_blocking(|| {
        let Ok(mut s) = sampler().lock() else { return SysStats::default() };
        s.sys.refresh_cpu_usage();
        s.sys.refresh_memory();
        s.nets.refresh(true);
        let secs = s.last_net.elapsed().as_secs_f64().max(0.25);
        s.last_net = Instant::now();
        let (rx, tx) = s.nets.iter()
            .filter(|(name, _)| !name.starts_with("lo"))
            .fold((0u64, 0u64), |(r, t), (_, d)| (r + d.received(), t + d.transmitted()));

        // Root volume only — summing every mount double-counts APFS volumes.
        let disks = sysinfo::Disks::new_with_refreshed_list();
        let root = disks.list().iter()
            .find(|d| d.mount_point() == std::path::Path::new("/System/Volumes/Data"))
            .or_else(|| disks.list().iter().find(|d| d.mount_point() == std::path::Path::new("/")));
        let (disk_total, disk_used) = root
            .map(|d| (d.total_space(), d.total_space().saturating_sub(d.available_space())))
            .unwrap_or((0, 0));

        // pmset is ~10ms; battery changes slowly — sample at most every 30s.
        if s.battery.0.elapsed() > Duration::from_secs(30) {
            s.battery = (Instant::now(), read_battery());
        }
        let load = sysinfo::System::load_average();
        // macOS reports "Data" volume used incl. purgeable; good enough for a gauge.
        SysStats {
            cpu: s.sys.global_cpu_usage(),
            cores: s.sys.cpus().iter().map(|c| c.cpu_usage()).collect(),
            mem_used: s.sys.used_memory(),
            mem_total: s.sys.total_memory(),
            disk_used,
            disk_total,
            net_rx: (rx as f64 / secs) as u64,
            net_tx: (tx as f64 / secs) as u64,
            battery: s.battery.1.clone(),
            uptime: sysinfo::System::uptime(),
            load: [load.one, load.five, load.fifteen],
        }
    })
    .await
    .unwrap_or_default()
}

fn read_battery() -> Option<Battery> {
    #[cfg(target_os = "macos")]
    {
        let out = std::process::Command::new("pmset").args(["-g", "batt"]).output().ok()?;
        return parse_pmset(&String::from_utf8_lossy(&out.stdout));
    }
    #[cfg(target_os = "linux")]
    {
        let dir = std::fs::read_dir("/sys/class/power_supply").ok()?
            .flatten()
            .find(|e| e.file_name().to_string_lossy().starts_with("BAT"))?
            .path();
        let pct: f32 = std::fs::read_to_string(dir.join("capacity")).ok()?.trim().parse().ok()?;
        let status = std::fs::read_to_string(dir.join("status")).unwrap_or_default();
        return Some(Battery { percent: pct, charging: status.trim() == "Charging", minutes_left: None });
    }
    #[allow(unreachable_code)]
    None
}

/// Parse `pmset -g batt`, e.g.
/// ` -InternalBattery-0 (id=123)\t82%; discharging; 5:12 remaining present: true`
pub fn parse_pmset(s: &str) -> Option<Battery> {
    let line = s.lines().find(|l| l.contains("InternalBattery"))?;
    let pct_end = line.find('%')?;
    let pct_start = line[..pct_end].rfind(|c: char| !c.is_ascii_digit())? + 1;
    let percent: f32 = line[pct_start..pct_end].parse().ok()?;
    let rest = &line[pct_end..];
    let charging = rest.contains("; charging") || rest.contains("; charged") || rest.contains("AC attached");
    let minutes_left = rest.split_whitespace()
        .find(|t| t.contains(':') && t.chars().next().is_some_and(|c| c.is_ascii_digit()))
        .and_then(|t| {
            let (h, m) = t.split_once(':')?;
            Some(h.parse::<u32>().ok()? * 60 + m.parse::<u32>().ok()?)
        })
        .filter(|_| !rest.contains("(no estimate)"));
    Some(Battery { percent, charging, minutes_left })
}

/* ─── Now playing ───────────────────────────────────────── */

#[derive(Debug, Clone, Serialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct NowPlaying {
    /// "Spotify" | "Music" | "" (nothing playing / unsupported).
    pub app:      String,
    /// "playing" | "paused" | "stopped"
    pub state:    String,
    pub title:    String,
    pub artist:   String,
    pub album:    String,
    pub position: f64,
    pub duration: f64,
    pub artwork:  Option<String>,
}

#[cfg(target_os = "macos")]
const NOW_PLAYING_SCRIPT: &str = r#"
set sep to (ASCII character 31)
on fmt(appName, st, t, a, al, pos, dur, art)
  set sep to (ASCII character 31)
  return appName & sep & st & sep & t & sep & a & sep & al & sep & (pos as string) & sep & (dur as string) & sep & art
end fmt
if application "Spotify" is running then
  tell application "Spotify"
    if player state is playing or player state is paused then
      set t to current track
      return my fmt("Spotify", (player state as string), name of t, artist of t, album of t, player position, (duration of t) / 1000, artwork url of t)
    end if
  end tell
end if
if application "Music" is running then
  tell application "Music"
    if player state is playing or player state is paused then
      set t to current track
      return my fmt("Music", (player state as string), name of t, artist of t, album of t, player position, duration of t, "")
    end if
  end tell
end if
return ""
"#;

/// Split the unit-separator-delimited AppleScript reply.
pub fn parse_now_playing(raw: &str) -> NowPlaying {
    let f: Vec<&str> = raw.trim_end_matches(['\n', '\r']).split('\u{1f}').collect();
    if f.len() < 8 { return NowPlaying { state: "stopped".into(), ..Default::default() }; }
    // AppleScript may localise decimals with a comma.
    let num = |s: &str| s.trim().replace(',', ".").parse::<f64>().unwrap_or(0.0);
    NowPlaying {
        app: f[0].into(),
        state: f[1].trim().into(),
        title: f[2].into(),
        artist: f[3].into(),
        album: f[4].into(),
        position: num(f[5]),
        duration: num(f[6]),
        artwork: Some(f[7].trim().to_string()).filter(|s| s.starts_with("http")),
    }
}

#[tauri::command]
pub async fn now_playing() -> NowPlaying {
    #[cfg(target_os = "macos")]
    {
        return tokio::task::spawn_blocking(|| {
            std::process::Command::new("osascript").args(["-e", NOW_PLAYING_SCRIPT]).output()
                .map(|o| parse_now_playing(&String::from_utf8_lossy(&o.stdout)))
                .unwrap_or_default()
        }).await.unwrap_or_default();
    }
    #[allow(unreachable_code)]
    NowPlaying { state: "stopped".into(), ..Default::default() }
}

#[tauri::command]
pub async fn media_control(action: String, app: String) -> Result<(), String> {
    let verb = match action.as_str() {
        "playpause" => "playpause",
        "next"      => "next track",
        "previous"  => "previous track",
        _ => return Err(format!("unknown media action {action}")),
    };
    let target = match app.as_str() { "Spotify" => "Spotify", _ => "Music" };
    #[cfg(target_os = "macos")]
    {
        let script = format!("tell application \"{target}\" to {verb}");
        return tokio::task::spawn_blocking(move || {
            std::process::Command::new("osascript").args(["-e", &script]).status()
                .map(|_| ()).map_err(|e| e.to_string())
        }).await.map_err(|e| e.to_string())?;
    }
    #[allow(unreachable_code)]
    { let _ = (verb, target); Err("media control is macOS-only".into()) }
}

/* ─── Weather (Open-Meteo, no key; only when a weather widget exists) ── */

#[derive(Debug, Clone, Serialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct HourPoint { pub t: i64, pub temp_c: f64, pub code: i64 }

#[derive(Debug, Clone, Serialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct DayPoint { pub t: i64, pub high: f64, pub low: f64, pub code: i64 }

#[derive(Debug, Clone, Serialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct Weather {
    pub location: String,
    pub temp_c:   f64,
    pub feels_c:  f64,
    pub code:     i64,
    pub is_day:   bool,
    pub humidity: f64,
    pub wind_kph: f64,
    pub high:     f64,
    pub low:      f64,
    pub hourly:   Vec<HourPoint>,
    pub daily:    Vec<DayPoint>,
}

fn weather_cache() -> &'static Mutex<HashMap<String, (Instant, Weather)>> {
    static C: OnceLock<Mutex<HashMap<String, (Instant, Weather)>>> = OnceLock::new();
    C.get_or_init(Default::default)
}

fn http() -> reqwest::Client {
    reqwest::Client::builder().timeout(Duration::from_secs(8)).build().unwrap_or_default()
}

#[tauri::command]
pub async fn weather_get(city: String) -> Result<Weather, String> {
    let city = city.trim().to_string();
    if city.is_empty() { return Err("Set a city in the widget settings".into()); }
    let key = city.to_lowercase();
    if let Some((at, w)) = weather_cache().lock().ok().and_then(|c| c.get(&key).cloned()) {
        if at.elapsed() < Duration::from_secs(600) { return Ok(w); }
    }
    let client = http();
    let geo: serde_json::Value = client
        .get("https://geocoding-api.open-meteo.com/v1/search")
        .query(&[("name", city.as_str()), ("count", "1"), ("format", "json")])
        .send().await.map_err(|e| format!("weather offline: {e}"))?
        .json().await.map_err(|e| e.to_string())?;
    let place = geo["results"].get(0).ok_or_else(|| format!("Unknown city “{city}”"))?;
    let (lat, lon) = (place["latitude"].as_f64().unwrap_or(0.0), place["longitude"].as_f64().unwrap_or(0.0));
    let name = place["name"].as_str().unwrap_or(&city).to_string();

    let v: serde_json::Value = client
        .get("https://api.open-meteo.com/v1/forecast")
        .query(&[
            ("latitude", lat.to_string()), ("longitude", lon.to_string()),
            ("current", "temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m,is_day".into()),
            ("hourly", "temperature_2m,weather_code".into()),
            ("daily", "weather_code,temperature_2m_max,temperature_2m_min".into()),
            ("timezone", "auto".into()), ("forecast_days", "6".into()), ("timeformat", "unixtime".into()),
        ])
        .send().await.map_err(|e| format!("weather offline: {e}"))?
        .json().await.map_err(|e| e.to_string())?;
    let w = parse_weather(&v, name);
    if let Ok(mut c) = weather_cache().lock() { c.insert(key, (Instant::now(), w.clone())); }
    Ok(w)
}

pub fn parse_weather(v: &serde_json::Value, location: String) -> Weather {
    let cur = &v["current"];
    let f = |x: &serde_json::Value| x.as_f64().unwrap_or(0.0);
    let arr = |x: &serde_json::Value| x.as_array().cloned().unwrap_or_default();
    let now = cur["time"].as_i64().unwrap_or_else(|| chrono::Utc::now().timestamp());
    let (ht, htemp, hcode) = (arr(&v["hourly"]["time"]), arr(&v["hourly"]["temperature_2m"]), arr(&v["hourly"]["weather_code"]));
    let hourly: Vec<HourPoint> = ht.iter().enumerate()
        .filter_map(|(i, t)| Some(HourPoint { t: t.as_i64()?, temp_c: f(htemp.get(i)?), code: hcode.get(i)?.as_i64().unwrap_or(0) }))
        .filter(|p| p.t >= now - 3600)
        .take(12)
        .collect();
    let (dt, dmax, dmin, dcode) = (arr(&v["daily"]["time"]), arr(&v["daily"]["temperature_2m_max"]), arr(&v["daily"]["temperature_2m_min"]), arr(&v["daily"]["weather_code"]));
    let daily: Vec<DayPoint> = dt.iter().enumerate()
        .filter_map(|(i, t)| Some(DayPoint { t: t.as_i64()?, high: f(dmax.get(i)?), low: f(dmin.get(i)?), code: dcode.get(i)?.as_i64().unwrap_or(0) }))
        .collect();
    Weather {
        location,
        temp_c: f(&cur["temperature_2m"]),
        feels_c: f(&cur["apparent_temperature"]),
        code: cur["weather_code"].as_i64().unwrap_or(0),
        is_day: cur["is_day"].as_i64().unwrap_or(1) == 1,
        humidity: f(&cur["relative_humidity_2m"]),
        wind_kph: f(&cur["wind_speed_10m"]),
        high: daily.first().map(|d| d.high).unwrap_or(0.0),
        low: daily.first().map(|d| d.low).unwrap_or(0.0),
        hourly,
        daily,
    }
}

/* ─── Agenda (from the calendar plugin's index) ─────────── */

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AgendaItem {
    pub title:    String,
    pub start:    i64,
    pub end:      Option<i64>,
    pub location: Option<String>,
    pub calendar: Option<String>,
}

#[tauri::command]
pub async fn calendar_upcoming(limit: Option<usize>) -> Vec<AgendaItem> {
    let limit = limit.unwrap_or(6).min(50) as i64;
    tokio::task::spawn_blocking(move || {
        let Some(db) = dirs::home_dir().map(|h| h.join(".cortex/calendar/calendar.db")) else { return vec![] };
        let Ok(conn) = rusqlite::Connection::open_with_flags(&db, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY) else { return vec![] };
        let now = chrono::Utc::now().timestamp();
        let Ok(mut stmt) = conn.prepare(
            "SELECT title, start_unix, end_unix, location, calendar_name FROM events
             WHERE COALESCE(end_unix, start_unix) >= ?1 ORDER BY start_unix ASC LIMIT ?2") else { return vec![] };
        stmt.query_map(rusqlite::params![now, limit], |r| Ok(AgendaItem {
            title: r.get(0)?, start: r.get(1)?, end: r.get(2)?, location: r.get(3)?, calendar: r.get(4)?,
        }))
        .map(|rows| rows.flatten().collect())
        .unwrap_or_default()
    }).await.unwrap_or_default()
}

/* ─── Git repos ─────────────────────────────────────────── */

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RepoStatus {
    pub name:           String,
    pub path:           String,
    pub branch:         String,
    pub ahead:          usize,
    pub behind:         usize,
    pub changed:        usize,
    pub last_commit:    String,
    pub last_commit_ts: i64,
}

/// Status for `paths`, or — when empty — the most recently committed-to repos
/// under the usual code folders.
#[tauri::command]
pub async fn git_repo_status(paths: Option<Vec<String>>, limit: Option<usize>) -> Vec<RepoStatus> {
    let limit = limit.unwrap_or(4).min(20);
    tokio::task::spawn_blocking(move || {
        let candidates: Vec<std::path::PathBuf> = match paths.filter(|p| !p.is_empty()) {
            Some(p) => p.into_iter().map(|s| expand_home(&s)).collect(),
            None => discover_repos(),
        };
        let mut out: Vec<RepoStatus> = candidates.iter().filter_map(|p| repo_status(p)).collect();
        out.sort_by(|a, b| b.last_commit_ts.cmp(&a.last_commit_ts));
        out.truncate(limit);
        out
    }).await.unwrap_or_default()
}

fn expand_home(s: &str) -> std::path::PathBuf {
    match s.strip_prefix("~/") {
        Some(rest) => dirs::home_dir().unwrap_or_default().join(rest),
        None => s.into(),
    }
}

fn discover_repos() -> Vec<std::path::PathBuf> {
    let home = dirs::home_dir().unwrap_or_default();
    let mut found = vec![];
    for root in ["code", "projects", "Projects", "Developer", "dev", "src", "repos", "work", "workspace", "Documents/GitHub"] {
        let r = home.join(root);
        let Ok(rd) = std::fs::read_dir(&r) else { continue };
        for e in rd.flatten().take(400) {
            let p = e.path();
            if p.join(".git").exists() { found.push(p); continue; }
            // one level deeper (org/repo layouts)
            if let Ok(inner) = std::fs::read_dir(&p) {
                for e2 in inner.flatten().take(100) {
                    if e2.path().join(".git").exists() { found.push(e2.path()); }
                }
            }
        }
    }
    found
}

fn repo_status(path: &std::path::Path) -> Option<RepoStatus> {
    let repo = git2::Repository::open(path).ok()?;
    let head = repo.head().ok();
    let branch = head.as_ref().and_then(|h| h.shorthand().map(String::from)).unwrap_or_else(|| "detached".into());
    let commit = head.as_ref().and_then(|h| h.peel_to_commit().ok());
    let (ahead, behind) = (|| {
        let local = head.as_ref()?.target()?;
        let up = repo.find_branch(&branch, git2::BranchType::Local).ok()?.upstream().ok()?;
        repo.graph_ahead_behind(local, up.get().target()?).ok()
    })().unwrap_or((0, 0));
    let mut opts = git2::StatusOptions::new();
    opts.include_untracked(true).recurse_untracked_dirs(false).exclude_submodules(true);
    let changed = repo.statuses(Some(&mut opts)).map(|s| s.len()).unwrap_or(0);
    Some(RepoStatus {
        name: path.file_name()?.to_string_lossy().into(),
        path: path.to_string_lossy().into(),
        branch,
        ahead,
        behind,
        changed,
        last_commit: commit.as_ref().and_then(|c| c.summary().map(String::from)).unwrap_or_default(),
        last_commit_ts: commit.map(|c| c.time().seconds()).unwrap_or(0),
    })
}

/* ─── Docker ────────────────────────────────────────────── */

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ContainerInfo { pub name: String, pub image: String, pub state: String, pub status: String }

#[tauri::command]
pub async fn docker_containers() -> Result<Vec<ContainerInfo>, String> {
    use bollard::{container::ListContainersOptions, Docker};
    let docker = Docker::connect_with_local_defaults().map_err(|_| "Docker isn't running".to_string())?;
    let list = tokio::time::timeout(Duration::from_secs(3),
        docker.list_containers(Some(ListContainersOptions::<String> { all: true, ..Default::default() })))
        .await.map_err(|_| "Docker isn't responding".to_string())?
        .map_err(|_| "Docker isn't running".to_string())?;
    let mut out: Vec<ContainerInfo> = list.into_iter().map(|c| ContainerInfo {
        name: c.names.and_then(|n| n.first().cloned()).unwrap_or_default().trim_start_matches('/').to_string(),
        image: c.image.unwrap_or_default(),
        state: c.state.unwrap_or_default(),
        status: c.status.unwrap_or_default(),
    }).collect();
    out.sort_by(|a, b| (b.state == "running").cmp(&(a.state == "running")).then(a.name.cmp(&b.name)));
    Ok(out)
}

#[tauri::command]
pub async fn docker_action(name: String, action: String) -> Result<(), String> {
    use bollard::Docker;
    let docker = Docker::connect_with_local_defaults().map_err(|e| e.to_string())?;
    match action.as_str() {
        "start"   => docker.start_container::<String>(&name, None).await.map_err(|e| e.to_string()),
        "stop"    => docker.stop_container(&name, None).await.map_err(|e| e.to_string()),
        "restart" => docker.restart_container(&name, None).await.map_err(|e| e.to_string()),
        _ => Err(format!("unknown action {action}")),
    }
}

/* ─── GitHub activity (from the GitHub plugin's index) ──── */

#[derive(Debug, Clone, Serialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct GithubActivity {
    pub repos:      i64,
    pub commits_7d: i64,
    /// Commit counts per day, oldest first, ending today (`days` long).
    pub days:       Vec<i64>,
}

#[tauri::command]
pub async fn github_activity(days: Option<usize>) -> GithubActivity {
    let n = days.unwrap_or(119).clamp(7, 371);
    // Real contribution calendar when a token works; local index otherwise.
    if let Some(a) = github_activity_api(n).await { return a; }
    github_activity_index(n).await
}

fn gh_cache() -> &'static Mutex<Option<(Instant, usize, GithubActivity)>> {
    static C: OnceLock<Mutex<Option<(Instant, usize, GithubActivity)>>> = OnceLock::new();
    C.get_or_init(Default::default)
}

async fn github_activity_api(n: usize) -> Option<GithubActivity> {
    if let Some((at, cn, a)) = gh_cache().lock().ok()?.clone() {
        if cn == n && at.elapsed() < Duration::from_secs(900) { return Some(a); }
    }
    let token = tokio::task::spawn_blocking(crate::auth::github_token).await.ok()??;
    let today = chrono::Utc::now().date_naive();
    let from = today - chrono::Duration::days(n as i64 - 1);
    let q = serde_json::json!({
        "query": "query($from: DateTime!, $to: DateTime!) { viewer { repositories(ownerAffiliations: OWNER) { totalCount } contributionsCollection(from: $from, to: $to) { contributionCalendar { weeks { contributionDays { date contributionCount } } } } } }",
        "variables": { "from": format!("{from}T00:00:00Z"), "to": format!("{today}T23:59:59Z") }
    });
    let v: serde_json::Value = http().post("https://api.github.com/graphql")
        .bearer_auth(token).header("User-Agent", "Cortex").json(&q)
        .send().await.ok()?.error_for_status().ok()?.json().await.ok()?;
    let a = parse_contributions(&v, from, n)?;
    if let Ok(mut c) = gh_cache().lock() { *c = Some((Instant::now(), n, a.clone())); }
    Some(a)
}

/// Flatten the GraphQL contribution calendar into `n` daily counts from `from`.
pub fn parse_contributions(v: &serde_json::Value, from: chrono::NaiveDate, n: usize) -> Option<GithubActivity> {
    let viewer = v.get("data")?.get("viewer")?;
    let mut days = vec![0i64; n];
    for w in viewer["contributionsCollection"]["contributionCalendar"]["weeks"].as_array()? {
        for d in w["contributionDays"].as_array().into_iter().flatten() {
            let Some(date) = d["date"].as_str().and_then(|s| chrono::NaiveDate::parse_from_str(s, "%Y-%m-%d").ok()) else { continue };
            let idx = (date - from).num_days();
            if (0..n as i64).contains(&idx) { days[idx as usize] = d["contributionCount"].as_i64().unwrap_or(0); }
        }
    }
    Some(GithubActivity {
        repos: viewer["repositories"]["totalCount"].as_i64().unwrap_or(0),
        commits_7d: days.iter().rev().take(7).sum(),
        days,
    })
}

async fn github_activity_index(n: usize) -> GithubActivity {
    tokio::task::spawn_blocking(move || {
        let Some(db) = dirs::home_dir().map(|h| h.join(".cortex/github/items.db")) else { return GithubActivity::default() };
        let Ok(conn) = rusqlite::Connection::open_with_flags(&db, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY) else {
            return GithubActivity { days: vec![0; n], ..Default::default() };
        };
        let today = chrono::Local::now().date_naive();
        let start = today - chrono::Duration::days(n as i64 - 1);
        let start_ts = start.and_hms_opt(0, 0, 0).and_then(|d| d.and_local_timezone(chrono::Local).single())
            .map(|d| d.timestamp()).unwrap_or(0);
        let mut buckets = vec![0i64; n];
        if let Ok(mut stmt) = conn.prepare("SELECT updated_unix FROM items WHERE kind='commit' AND updated_unix >= ?1") {
            if let Ok(rows) = stmt.query_map([start_ts], |r| r.get::<_, i64>(0)) {
                for ts in rows.flatten() {
                    if let Some(d) = chrono::DateTime::from_timestamp(ts, 0) {
                        let day = d.with_timezone(&chrono::Local).date_naive();
                        let idx = (day - start).num_days();
                        if (0..n as i64).contains(&idx) { buckets[idx as usize] += 1; }
                    }
                }
            }
        }
        let repos = conn.query_row("SELECT COUNT(*) FROM items WHERE kind='repo'", [], |r| r.get(0)).unwrap_or(0);
        let commits_7d = buckets.iter().rev().take(7).sum();
        GithubActivity { repos, commits_7d, days: buckets }
    }).await.unwrap_or_default()
}

/* ─── Photo frame ───────────────────────────────────────── */

/// A random image from `folder` (default ~/Pictures), downscaled to a JPEG
/// data URL. Walks at most 2 levels and 2 000 entries to stay fast.
#[tauri::command]
pub async fn photo_pick(folder: Option<String>, seed: Option<u64>) -> Result<String, String> {
    tokio::task::spawn_blocking(move || {
        let dir = folder.filter(|f| !f.trim().is_empty()).map(|f| expand_home(&f))
            .unwrap_or_else(|| dirs::picture_dir().unwrap_or_else(|| dirs::home_dir().unwrap_or_default().join("Pictures")));
        let imgs: Vec<std::path::PathBuf> = walkdir::WalkDir::new(&dir).max_depth(2).into_iter()
            .flatten().take(2_000)
            .map(|e| e.into_path())
            .filter(|p| matches!(p.extension().and_then(|e| e.to_str()).map(|e| e.to_ascii_lowercase()).as_deref(),
                Some("jpg" | "jpeg" | "png" | "webp")))
            .collect();
        if imgs.is_empty() { return Err(format!("No photos in {}", dir.display())); }
        let pick = seed.unwrap_or_else(|| chrono::Utc::now().timestamp() as u64 / 300) as usize % imgs.len();
        let img = image::open(&imgs[pick]).map_err(|e| e.to_string())?.thumbnail(900, 900);
        let mut buf = std::io::Cursor::new(Vec::new());
        img.to_rgb8().write_to(&mut buf, image::ImageFormat::Jpeg).map_err(|e| e.to_string())?;
        use base64::Engine;
        Ok(format!("data:image/jpeg;base64,{}", base64::engine::general_purpose::STANDARD.encode(buf.into_inner())))
    }).await.map_err(|e| e.to_string())?
}

/* ─── Installed applications (pickers for dock / launcher) ── */

#[derive(Debug, Clone, Serialize)]
pub struct InstalledApp { pub name: String, pub path: String }

#[tauri::command]
pub async fn list_installed_apps() -> Vec<InstalledApp> {
    tokio::task::spawn_blocking(|| {
        let mut out: Vec<InstalledApp> = vec![];
        #[cfg(target_os = "macos")]
        {
            let home = dirs::home_dir().unwrap_or_default();
            let roots = [
                std::path::PathBuf::from("/Applications"),
                std::path::PathBuf::from("/Applications/Utilities"),
                std::path::PathBuf::from("/System/Applications"),
                std::path::PathBuf::from("/System/Applications/Utilities"),
                home.join("Applications"),
            ];
            for r in roots {
                let Ok(rd) = std::fs::read_dir(&r) else { continue };
                for e in rd.flatten() {
                    let p = e.path();
                    if p.extension().and_then(|x| x.to_str()) == Some("app") {
                        let name = p.file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_default();
                        out.push(InstalledApp { name, path: p.to_string_lossy().into() });
                    }
                }
            }
            // Finder lives outside /Applications.
            out.push(InstalledApp { name: "Finder".into(), path: "/System/Library/CoreServices/Finder.app".into() });
        }
        #[cfg(target_os = "linux")]
        {
            for r in ["/usr/share/applications", "/var/lib/flatpak/exports/share/applications"] {
                let Ok(rd) = std::fs::read_dir(r) else { continue };
                for e in rd.flatten() {
                    let p = e.path();
                    if p.extension().and_then(|x| x.to_str()) != Some("desktop") { continue; }
                    let Ok(txt) = std::fs::read_to_string(&p) else { continue };
                    if txt.contains("NoDisplay=true") { continue; }
                    if let Some(name) = txt.lines().find_map(|l| l.strip_prefix("Name=")) {
                        out.push(InstalledApp { name: name.to_string(), path: p.to_string_lossy().into() });
                    }
                }
            }
        }
        out.sort_by_key(|a| a.name.to_lowercase());
        out.dedup_by(|a, b| a.name.eq_ignore_ascii_case(&b.name));
        out
    }).await.unwrap_or_default()
}

/// Launch / focus an app (or open any path/URL) without hiding the caller.
#[tauri::command]
pub async fn launch_path(path: String) -> Result<(), String> {
    tokio::task::spawn_blocking(move || {
        #[cfg(target_os = "linux")]
        if path.ends_with(".desktop") {
            let id = std::path::Path::new(&path).file_name().map(|s| s.to_string_lossy().to_string()).unwrap_or_default();
            return std::process::Command::new("gtk-launch").arg(id).spawn().map(|_| ()).map_err(|e| e.to_string());
        }
        opener::open(&path).map_err(|e| e.to_string())
    }).await.map_err(|e| e.to_string())?
}


/* ─── Any-app widget: status + control ──────────────────── */

#[derive(Debug, Clone, Serialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct AppStatus {
    pub running:   bool,
    /// Summed over the app's processes (helpers included).
    pub cpu:       f32,
    pub mem_bytes: u64,
    pub processes: usize,
}

/// Live status for the `.app` at `path` — processes whose executable lives
/// inside the bundle (renderer/helper processes included).
#[tauri::command]
pub async fn app_status(path: String) -> AppStatus {
    tokio::task::spawn_blocking(move || {
        let Ok(mut s) = sampler().lock() else { return AppStatus::default() };
        s.sys.refresh_processes(sysinfo::ProcessesToUpdate::All, true);
        let root = path.trim_end_matches('/');
        let mut st = AppStatus::default();
        for p in s.sys.processes().values() {
            let Some(exe) = p.exe() else { continue };
            if exe.to_string_lossy().starts_with(&format!("{root}/")) {
                st.running = true;
                st.cpu += p.cpu_usage();
                st.mem_bytes += p.memory();
                st.processes += 1;
            }
        }
        st
    }).await.unwrap_or_default()
}

fn app_name(path: &str) -> String {
    std::path::Path::new(path.trim_end_matches('/')).file_stem()
        .map(|s| s.to_string_lossy().replace('"', "")).unwrap_or_default()
}

/// `open` | `hide` | `quit` for the app at `path`.
#[tauri::command]
pub async fn app_action(path: String, action: String) -> Result<(), String> {
    let name = app_name(&path);
    tokio::task::spawn_blocking(move || {
        #[cfg(target_os = "macos")]
        {
            let script = match action.as_str() {
                "open" => return opener::open(&path).map_err(|e| e.to_string()),
                "hide" => format!("tell application \"System Events\" to set visible of process \"{name}\" to false"),
                "quit" => format!("tell application \"{name}\" to quit"),
                _ => return Err(format!("unknown action {action}")),
            };
            return std::process::Command::new("osascript").args(["-e", &script]).status()
                .map(|_| ()).map_err(|e| e.to_string());
        }
        #[allow(unreachable_code)]
        match action.as_str() {
            "open" => opener::open(&path).map_err(|e| e.to_string()),
            _ => { let _ = name; Err("only open is supported on this OS".into()) }
        }
    }).await.map_err(|e| e.to_string())?
}

/* ─── Recent files / Downloads ──────────────────────────── */

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RecentFile { pub name: String, pub path: String, pub modified: i64, pub size: u64, pub is_dir: bool }

/// Newest files in `folder` (one level), or — without a folder — across
/// Desktop, Documents and Downloads (two levels deep). Hidden files skipped.
#[tauri::command]
pub async fn recent_files(folder: Option<String>, limit: Option<usize>) -> Vec<RecentFile> {
    let limit = limit.unwrap_or(8).min(50);
    tokio::task::spawn_blocking(move || {
        let home = dirs::home_dir().unwrap_or_default();
        let (roots, depth): (Vec<std::path::PathBuf>, usize) = match folder.filter(|f| !f.trim().is_empty()) {
            Some(f) => (vec![expand_home(&f)], 1),
            None => (["Desktop", "Documents", "Downloads"].iter().map(|d| home.join(d)).collect(), 2),
        };
        let mut out: Vec<RecentFile> = roots.iter().flat_map(|r| {
            walkdir::WalkDir::new(r).min_depth(1).max_depth(depth).into_iter()
                .filter_entry(|e| !e.file_name().to_string_lossy().starts_with('.'))
                .flatten().take(3_000)
                .filter_map(|e| {
                    let md = e.metadata().ok()?;
                    let is_dir = md.is_dir();
                    // Bundles (.app, .pages…) count as files; plain folders only at the top level.
                    if is_dir && e.depth() > 1 { return None; }
                    let modified = md.modified().ok()?.duration_since(std::time::UNIX_EPOCH).ok()?.as_secs() as i64;
                    Some(RecentFile {
                        name: e.file_name().to_string_lossy().into(),
                        path: e.path().to_string_lossy().into(),
                        modified, size: md.len(), is_dir,
                    })
                })
                .collect::<Vec<_>>()
        }).collect();
        out.sort_by(|a, b| b.modified.cmp(&a.modified));
        out.truncate(limit);
        out
    }).await.unwrap_or_default()
}

/* ─── VS Code / Cursor recent projects ──────────────────── */

#[derive(Debug, Clone, Serialize)]
pub struct Project { pub name: String, pub path: String, pub editor: String }

#[tauri::command]
pub async fn editor_recent(limit: Option<usize>) -> Vec<Project> {
    let limit = limit.unwrap_or(8).min(30);
    tokio::task::spawn_blocking(move || {
        let Some(base) = dirs::config_dir() else { return vec![] };
        let mut out = vec![];
        for (dir, editor) in [("Code", "Visual Studio Code"), ("Cursor", "Cursor"), ("Code - Insiders", "Visual Studio Code - Insiders"), ("Windsurf", "Windsurf")] {
            let db = base.join(dir).join("User/globalStorage/state.vscdb");
            let Ok(conn) = rusqlite::Connection::open_with_flags(&db, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY) else { continue };
            let Ok(raw) = conn.query_row(
                "SELECT value FROM ItemTable WHERE key = 'history.recentlyOpenedPathsList'", [], |r| r.get::<_, String>(0)) else { continue };
            out.extend(parse_recent_paths(&raw, editor));
        }
        let mut seen = std::collections::HashSet::new();
        out.retain(|p| seen.insert(p.path.clone()));
        out.truncate(limit);
        out
    }).await.unwrap_or_default()
}

/// `{"entries":[{"folderUri":"file:///…"},{"fileUri":"…"},…]}` → local projects.
pub fn parse_recent_paths(raw: &str, editor: &str) -> Vec<Project> {
    let Ok(v) = serde_json::from_str::<serde_json::Value>(raw) else { return vec![] };
    v["entries"].as_array().into_iter().flatten().filter_map(|e| {
        let uri = e["folderUri"].as_str().or_else(|| e["fileUri"].as_str())?;
        let path = url::Url::parse(uri).ok().filter(|u| u.scheme() == "file")?.to_file_path().ok()?;
        Some(Project {
            name: path.file_name()?.to_string_lossy().into(),
            path: path.to_string_lossy().into(),
            editor: editor.to_string(),
        })
    }).collect()
}

/// Open `path` in a specific editor app (falls back to the default handler).
#[tauri::command]
pub async fn open_in(app: String, path: String) -> Result<(), String> {
    tokio::task::spawn_blocking(move || {
        #[cfg(target_os = "macos")]
        if std::process::Command::new("open").args(["-a", &app, &path]).status().map(|s| s.success()).unwrap_or(false) {
            return Ok(());
        }
        let _ = &app;
        opener::open(&path).map_err(|e| e.to_string())
    }).await.map_err(|e| e.to_string())?
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pmset_discharging() {
        let b = parse_pmset("Now drawing from 'Battery Power'\n -InternalBattery-0 (id=4653155)\t82%; discharging; 5:12 remaining present: true\n").unwrap();
        assert_eq!(b.percent, 82.0);
        assert!(!b.charging);
        assert_eq!(b.minutes_left, Some(312));
    }

    #[test]
    fn pmset_charging_no_estimate() {
        let b = parse_pmset("Now drawing from 'AC Power'\n -InternalBattery-0 (id=1)\t7%; charging; (no estimate) present: true").unwrap();
        assert_eq!(b.percent, 7.0);
        assert!(b.charging);
        assert_eq!(b.minutes_left, None);
    }

    #[test]
    fn pmset_desktop_mac_has_no_battery() {
        assert!(parse_pmset("Now drawing from 'AC Power'\n").is_none());
    }

    #[test]
    fn now_playing_fields() {
        let raw = "Spotify\u{1f}playing\u{1f}Midnight City\u{1f}M83\u{1f}Hurry Up\u{1f}92,5\u{1f}244.0\u{1f}https://i.scdn.co/x\n";
        let n = parse_now_playing(raw);
        assert_eq!(n.app, "Spotify");
        assert_eq!(n.state, "playing");
        assert_eq!(n.position, 92.5);
        assert_eq!(n.duration, 244.0);
        assert_eq!(n.artwork.as_deref(), Some("https://i.scdn.co/x"));
        assert_eq!(parse_now_playing("").state, "stopped");
    }

    #[test]
    fn recent_paths_parse() {
        let raw = r#"{"entries":[{"folderUri":"file:///Users/me/code/aio"},{"fileUri":"file:///Users/me/notes%20today.md"},{"folderUri":"vscode-remote://ssh/x"}]}"#;
        let p = parse_recent_paths(raw, "Cursor");
        assert_eq!(p.len(), 2, "remote URIs skipped");
        assert_eq!(p[0].name, "aio");
        assert_eq!(p[1].path, "/Users/me/notes today.md");
        assert_eq!(p[1].editor, "Cursor");
    }

    #[tokio::test]
    async fn recent_files_sorted_newest_first() {
        let dir = std::env::temp_dir().join(format!("cortex-recent-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        for (i, n) in ["a.txt", "b.txt", ".hidden"].iter().enumerate() {
            let p = dir.join(n);
            std::fs::write(&p, "x").unwrap();
            let t = std::time::SystemTime::now() - std::time::Duration::from_secs(100 - i as u64 * 10);
            std::fs::File::options().write(true).open(&p).unwrap().set_modified(t).unwrap();
        }
        let r = recent_files(Some(dir.to_string_lossy().into()), Some(5)).await;
        assert_eq!(r.iter().map(|f| f.name.as_str()).collect::<Vec<_>>(), ["b.txt", "a.txt"]);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[tokio::test]
    async fn app_status_for_missing_app() {
        let s = app_status("/Applications/Definitely Not Installed.app".into()).await;
        assert!(!s.running);
    }

    #[test]
    fn contributions_parse() {
        let from = chrono::NaiveDate::from_ymd_opt(2026, 10, 20).unwrap();
        let v = serde_json::json!({ "data": { "viewer": { "repositories": { "totalCount": 24 },
            "contributionsCollection": { "contributionCalendar": { "weeks": [
                { "contributionDays": [ { "date": "2026-10-19", "contributionCount": 9 }, { "date": "2026-10-20", "contributionCount": 3 } ] },
                { "contributionDays": [ { "date": "2026-10-26", "contributionCount": 5 } ] } ] } } } } });
        let a = parse_contributions(&v, from, 7).unwrap();
        assert_eq!(a.repos, 24);
        assert_eq!(a.days, vec![3, 0, 0, 0, 0, 0, 5], "out-of-range day dropped");
        assert_eq!(a.commits_7d, 8);
        assert!(parse_contributions(&serde_json::json!({ "errors": [] }), from, 7).is_none());
    }

    #[test]
    fn weather_parse() {
        let v = serde_json::json!({
            "current": { "time": 10000, "temperature_2m": 21.5, "apparent_temperature": 20.0, "relative_humidity_2m": 60,
                         "weather_code": 3, "wind_speed_10m": 12.0, "is_day": 0 },
            "hourly": { "time": [0, 10000, 13600], "temperature_2m": [19.0, 21.5, 22.0], "weather_code": [1, 3, 61] },
            "daily": { "time": [0, 86400], "temperature_2m_max": [24.0, 25.0], "temperature_2m_min": [15.0, 16.0], "weather_code": [3, 61] }
        });
        let w = parse_weather(&v, "Pune".into());
        assert_eq!(w.location, "Pune");
        assert_eq!(w.temp_c, 21.5);
        assert!(!w.is_day);
        assert_eq!(w.hourly.len(), 2, "drops points older than an hour");
        assert_eq!((w.high, w.low), (24.0, 15.0));
        assert_eq!(w.daily[1].code, 61);
    }

    #[tokio::test]
    async fn sys_stats_samples() {
        let s = sys_stats().await;
        assert!(s.mem_total > 0);
        assert!(!s.cores.is_empty());
        assert!((0.0..=100.0).contains(&s.cpu));
    }

    #[test]
    fn repo_status_reads_this_repo() {
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap();
        if let Some(st) = repo_status(root) {
            assert!(!st.branch.is_empty());
            assert!(st.last_commit_ts > 0);
        }
    }
}
