//! Now Playing for Apple Music and Spotify, plus transport controls.
//!
//! One short AppleScript per player, run only while that player is running
//! (see `automation.rs` for why). Reads are cheap and cached: artwork is
//! extracted once per track, not per poll.

use super::automation::{self, Permission, MUSIC, SPOTIFY};
use serde::Serialize;
use std::{
    collections::HashSet,
    io::Read,
    process::{Command, Stdio},
    sync::{Mutex, OnceLock},
    time::{Duration, Instant},
};

const SEP: char = '\u{1f}';

#[derive(Debug, Clone, Copy)]
pub struct Player { pub name: &'static str, pub bundle: &'static str }

pub const PLAYERS: [Player; 2] = [
    Player { name: "Music", bundle: MUSIC },
    Player { name: "Spotify", bundle: SPOTIFY },
];

#[derive(Debug, Clone, Serialize, Default, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct NowPlaying {
    /// "Music" | "Spotify" | "" when nothing is playing.
    pub app:        String,
    /// "playing" | "paused" | "stopped"
    pub state:      String,
    pub title:      String,
    pub artist:     String,
    pub album:      String,
    pub position:   f64,
    pub duration:   f64,
    /// data: URL (Music) or https URL (Spotify).
    pub artwork:    Option<String>,
    /// Stable id of the track (for change detection in the UI).
    pub track_id:   String,
    /// "ok" | "denied" | "none" — "denied" means a player is running but macOS
    /// blocks Cortex from asking it; `denied_app` names it.
    pub permission: String,
    pub denied_app: String,
}

#[derive(Debug, PartialEq)]
pub enum Reply {
    Stopped,
    Track { state: String, title: String, artist: String, album: String, position: f64, duration: f64, id: String, art_url: Option<String> },
    Error { code: i32, message: String },
}

/// Parse a player script's reply.
pub fn parse_reply(raw: &str) -> Reply {
    let raw = raw.trim_end_matches(['\n', '\r']);
    let f: Vec<&str> = raw.split(SEP).collect();
    match f.first().map(|s| s.trim()) {
        Some("playing") | Some("paused") if f.len() >= 7 => {
            // AppleScript can localise decimals ("92,5").
            let num = |s: &str| s.trim().replace(',', ".").parse::<f64>().unwrap_or(0.0);
            Reply::Track {
                state: f[0].trim().to_string(),
                title: f[1].to_string(),
                artist: f[2].to_string(),
                album: f[3].to_string(),
                position: num(f[4]),
                duration: num(f[5]),
                id: f[6].trim().to_string(),
                art_url: f.get(7).map(|s| s.trim().to_string()).filter(|s| s.starts_with("http")),
            }
        }
        Some("ERR") => Reply::Error {
            code: f.get(1).and_then(|s| s.trim().parse().ok()).unwrap_or(0),
            message: f.get(2).unwrap_or(&"").to_string(),
        },
        _ => Reply::Stopped,
    }
}

fn metadata_script(p: Player) -> String {
    // `tell application id` + running-only keeps the script compilable and
    // prompt-free; every enum is mapped to text explicitly (no locale surprises).
    let (duration, extra) = if p.bundle == SPOTIFY {
        ("(((duration of t) / 1000) as integer)", r#" & sep & (try_art)"#)
    } else {
        ("((duration of t) as integer)", "")
    };
    let id = if p.bundle == SPOTIFY { "(id of t)" } else { "(persistent ID of t)" };
    let art_prelude = if p.bundle == SPOTIFY {
        "set try_art to \"\"\n      try\n        set try_art to artwork url of t\n      end try\n      "
    } else { "" };
    format!(r#"set sep to (ASCII character 31)
try
  tell application id "{bundle}"
    if player state is playing then
      set st to "playing"
    else if player state is paused then
      set st to "paused"
    else
      return "stopped"
    end if
    set t to current track
    {art_prelude}return st & sep & (name of t) & sep & (artist of t) & sep & (album of t) & sep & ((player position) as integer) & sep & {duration} & sep & {id}{extra}
  end tell
on error errMsg number errNum
  return "ERR" & sep & errNum & sep & errMsg
end try"#, bundle = p.bundle)
}

fn artwork_script(out: &str) -> String {
    let out = out.replace('\\', "\\\\").replace('"', "\\\"");
    format!(r#"set outPath to "{out}"
try
  tell application id "{MUSIC}"
    set d to raw data of artwork 1 of current track
  end tell
  set f to open for access (POSIX file outPath) with write permission
  set eof f to 0
  write d to f
  close access f
  return "ok"
on error errMsg number errNum
  try
    close access (POSIX file outPath)
  end try
  return "ERR" & (ASCII character 31) & errNum & (ASCII character 31) & errMsg
end try"#)
}

/// `osascript` with a hard timeout (a hung app must never hang the Island).
pub(crate) fn run_osascript(script: &str, timeout: Duration) -> Option<String> {
    let mut child = Command::new("/usr/bin/osascript")
        .args(["-e", script])
        .stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null())
        .spawn().ok()?;
    let start = Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) if start.elapsed() < timeout => std::thread::sleep(Duration::from_millis(15)),
            _ => { let _ = child.kill(); let _ = child.wait(); return None; }
        }
    }
    let mut out = String::new();
    child.stdout.take()?.read_to_string(&mut out).ok()?;
    Some(out)
}

fn asked() -> &'static Mutex<HashSet<&'static str>> {
    static A: OnceLock<Mutex<HashSet<&'static str>>> = OnceLock::new();
    A.get_or_init(Default::default)
}

/// Permission for a running player; shows the consent dialog the first time.
fn ensure_permission(p: Player) -> Permission {
    let mut perm = automation::permission(p.bundle, false);
    if perm == Permission::Ask {
        let first = asked().lock().map(|mut s| s.insert(p.bundle)).unwrap_or(false);
        if first { perm = automation::permission(p.bundle, true); }
    }
    perm
}

#[derive(Default)]
struct ArtCache { key: String, art: Option<String> }

fn art_cache() -> &'static Mutex<ArtCache> {
    static C: OnceLock<Mutex<ArtCache>> = OnceLock::new();
    C.get_or_init(Default::default)
}

/// Cover art for the current Apple Music track as a small JPEG data URL.
fn music_artwork(track_id: &str) -> Option<String> {
    if let Ok(c) = art_cache().lock() {
        if c.key == track_id { return c.art.clone(); }
    }
    let path = std::env::temp_dir().join(format!("cortex-art-{}.bin", uuid::Uuid::new_v4()));
    let reply = run_osascript(&artwork_script(&path.to_string_lossy()), Duration::from_secs(5));
    let art = (reply.as_deref().map(str::trim) == Some("ok")).then(|| shrink_to_data_url(&path)).flatten();
    let _ = std::fs::remove_file(&path);
    if let Ok(mut c) = art_cache().lock() { *c = ArtCache { key: track_id.to_string(), art: art.clone() }; }
    art
}

fn shrink_to_data_url(path: &std::path::Path) -> Option<String> {
    use base64::Engine;
    let img = image::open(path).ok()?.thumbnail(256, 256);
    let mut buf = std::io::Cursor::new(Vec::new());
    img.to_rgb8().write_to(&mut buf, image::ImageFormat::Jpeg).ok()?;
    Some(format!("data:image/jpeg;base64,{}", base64::engine::general_purpose::STANDARD.encode(buf.into_inner())))
}

/// Blocking: query every running player, prefer one that is playing.
pub fn poll() -> NowPlaying {
    let mut paused: Option<NowPlaying> = None;
    let mut denied = String::new();
    let mut any_running = false;
    for p in PLAYERS {
        if !automation::is_running(p.bundle) { continue; }
        any_running = true;
        if ensure_permission(p) == Permission::Denied { if denied.is_empty() { denied = p.name.to_string(); } continue; }
        let Some(raw) = run_osascript(&metadata_script(p), Duration::from_secs(4)) else { continue };
        match parse_reply(&raw) {
            Reply::Track { state, title, artist, album, position, duration, id, art_url } => {
                let artwork = if p.bundle == MUSIC { music_artwork(&id) } else { art_url };
                let np = NowPlaying {
                    app: p.name.into(), state: state.clone(), title, artist, album, position, duration, artwork,
                    track_id: format!("{}:{id}", p.bundle), permission: "ok".into(), denied_app: String::new(),
                };
                if state == "playing" { return np; }
                if paused.is_none() { paused = Some(np); }
            }
            Reply::Error { code: -1743, .. } => { if denied.is_empty() { denied = p.name.to_string(); } }
            Reply::Error { .. } | Reply::Stopped => {}
        }
    }
    if let Some(np) = paused { return np; }
    NowPlaying {
        state: "stopped".into(),
        permission: if !denied.is_empty() { "denied" } else if any_running { "ok" } else { "none" }.into(),
        denied_app: denied,
        ..Default::default()
    }
}

#[tauri::command]
pub async fn now_playing() -> NowPlaying {
    #[cfg(target_os = "macos")]
    { return tokio::task::spawn_blocking(poll).await.unwrap_or_default(); }
    #[allow(unreachable_code)]
    NowPlaying { state: "stopped".into(), permission: "none".into(), ..Default::default() }
}

fn player_for(app: &str) -> Player {
    PLAYERS.iter().copied().find(|p| p.name.eq_ignore_ascii_case(app)).unwrap_or(PLAYERS[0])
}

/// The AppleScript line for a transport action.
pub fn control_statement(action: &str, seconds: Option<f64>) -> Result<String, String> {
    Ok(match action {
        "playpause" => "playpause".into(),
        "next"      => "next track".into(),
        "previous"  => "previous track".into(),
        "seek"      => format!("set player position to {}", seconds.ok_or("seek needs a position")?.max(0.0).round() as i64),
        other       => return Err(format!("unknown media action {other}")),
    })
}

#[tauri::command]
pub async fn media_control(action: String, app: String) -> Result<(), String> {
    media_control_inner(action, app, None).await
}

#[tauri::command]
pub async fn media_seek(app: String, seconds: f64) -> Result<(), String> {
    media_control_inner("seek".into(), app, Some(seconds)).await
}

async fn media_control_inner(action: String, app: String, seconds: Option<f64>) -> Result<(), String> {
    let stmt = control_statement(&action, seconds)?;
    let p = player_for(&app);
    #[cfg(target_os = "macos")]
    {
        return tokio::task::spawn_blocking(move || {
            // Never launch a player that isn't running just because a button was pressed.
            if !automation::is_running(p.bundle) { return Err(format!("{} isn't running", p.name)); }
            let script = format!("tell application id \"{}\" to {stmt}", p.bundle);
            match run_osascript(&script, Duration::from_secs(4)) {
                Some(_) => Ok(()),
                None => Err(format!("{} didn't respond", p.name)),
            }
        }).await.map_err(|e| e.to_string())?;
    }
    #[allow(unreachable_code)]
    { let _ = (stmt, p); Err("media control is macOS-only".into()) }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_music_track() {
        let raw = "playing\u{1f}Aerodynamic\u{1f}Daft Punk\u{1f}Discovery\u{1f}92\u{1f}212\u{1f}ABCDEF0123456789\n";
        match parse_reply(raw) {
            Reply::Track { state, title, artist, position, duration, id, art_url, .. } => {
                assert_eq!((state.as_str(), title.as_str(), artist.as_str()), ("playing", "Aerodynamic", "Daft Punk"));
                assert_eq!((position, duration), (92.0, 212.0));
                assert_eq!(id, "ABCDEF0123456789");
                assert!(art_url.is_none());
            }
            r => panic!("{r:?}"),
        }
    }

    #[test]
    fn parses_spotify_track_with_artwork_and_comma_decimals() {
        let raw = "paused\u{1f}Midnight City\u{1f}M83\u{1f}Hurry Up\u{1f}92,5\u{1f}244\u{1f}spotify:track:1\u{1f}https://i.scdn.co/image/x";
        match parse_reply(raw) {
            Reply::Track { state, position, art_url, .. } => {
                assert_eq!(state, "paused");
                assert_eq!(position, 92.5);
                assert_eq!(art_url.as_deref(), Some("https://i.scdn.co/image/x"));
            }
            r => panic!("{r:?}"),
        }
    }

    #[test]
    fn parses_stopped_errors_and_garbage() {
        assert_eq!(parse_reply("stopped\n"), Reply::Stopped);
        assert_eq!(parse_reply(""), Reply::Stopped);
        assert_eq!(parse_reply("playing\u{1f}too\u{1f}short"), Reply::Stopped);
        assert_eq!(parse_reply("ERR\u{1f}-1743\u{1f}Not authorized to send Apple events to Music."),
            Reply::Error { code: -1743, message: "Not authorized to send Apple events to Music.".into() });
    }

    #[test]
    fn scripts_target_bundle_ids_and_are_per_player() {
        let m = metadata_script(PLAYERS[0]);
        let s = metadata_script(PLAYERS[1]);
        assert!(m.contains("com.apple.Music") && !m.contains("spotify"), "Music script must not mention Spotify");
        assert!(s.contains("com.spotify.client") && !s.contains("com.apple.Music"), "Spotify script must not mention Music");
        assert!(m.contains("persistent ID") && s.contains("artwork url"));
        assert!(artwork_script("/tmp/a \"b\".bin").contains(r#"/tmp/a \"b\".bin"#));
    }

    #[test]
    fn control_statements() {
        assert_eq!(control_statement("next", None).unwrap(), "next track");
        assert_eq!(control_statement("seek", Some(41.6)).unwrap(), "set player position to 42");
        assert!(control_statement("seek", None).is_err());
        assert!(control_statement("explode", None).is_err());
        assert_eq!(player_for("spotify").bundle, SPOTIFY);
        assert_eq!(player_for("anything").bundle, MUSIC);
    }
}
