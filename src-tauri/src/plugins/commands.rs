//! System commands plugin — Raycast-style quick actions.
//!
//! A curated set of OS actions (lock, sleep, empty trash, toggle dark mode…).
//! Fuzzy-matched by title; executed directly by this plugin (not via the
//! generic file/url dispatcher). Stable ids `cmd:<id>` for frecency.

use anyhow::Result;
use async_trait::async_trait;
use fuzzy_matcher::{skim::SkimMatcherV2, FuzzyMatcher};
use std::process::Command;

use crate::plugin::{Plugin, ResultAction, SearchQuery, SearchResult, SourceType};

/// (id, title, subtitle, shell-program, args…) — kept tiny and explicit.
struct Cmd {
    id:    &'static str,
    title: &'static str,
    sub:   &'static str,
    /// Shell line run via `sh -c`.
    run:   &'static str,
}

#[cfg(target_os = "macos")]
const COMMANDS: &[Cmd] = &[
    // Ctrl-⌘-Q is the real lock; pmset is the fallback when Accessibility is off.
    Cmd { id: "lock",       title: "Lock Screen",        sub: "Lock the Mac",                run: "osascript -e 'tell application \"System Events\" to keystroke \"q\" using {control down, command down}' 2>/dev/null || pmset displaysleepnow" },
    Cmd { id: "sleep",      title: "Sleep",              sub: "Put the Mac to sleep",        run: "pmset sleepnow" },
    Cmd { id: "displaysleep", title: "Sleep Displays",   sub: "Turn the screens off",        run: "pmset displaysleepnow" },
    Cmd { id: "screensaver",title: "Start Screen Saver", sub: "Launch the screen saver",     run: "open -a ScreenSaverEngine" },
    Cmd { id: "emptytrash", title: "Empty Trash",        sub: "Permanently delete trash",    run: "osascript -e 'tell application \"Finder\" to empty trash'" },
    Cmd { id: "opentrash",  title: "Open Trash",         sub: "Reveal the Trash folder",     run: "open ~/.Trash" },
    Cmd { id: "darkmode",   title: "Toggle Dark Mode",   sub: "Switch light / dark theme",   run: "osascript -e 'tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode'" },
    Cmd { id: "togglewifi", title: "Toggle Wi-Fi",       sub: "Turn Wi-Fi on or off",        run: "dev=$(networksetup -listallhardwareports | awk '/Wi-Fi/{getline; print $2}'); networksetup -setairportpower \"${dev:-en0}\" $(networksetup -getairportpower \"${dev:-en0}\" | grep -q On && echo off || echo on)" },
    // sudo has no TTY here — ask for the admin password through the GUI instead.
    Cmd { id: "flushdns",   title: "Flush DNS Cache",    sub: "Reset the DNS resolver cache",run: "osascript -e 'do shell script \"dscacheutil -flushcache; killall -HUP mDNSResponder\" with administrator privileges'" },
    Cmd { id: "screenshot", title: "Take Screenshot",    sub: "Capture a region to the Desktop", run: "screencapture -i ~/Desktop/\"Screenshot $(date '+%Y-%m-%d at %H.%M.%S').png\"" },
    Cmd { id: "screenclip", title: "Screenshot to Clipboard", sub: "Capture a region, copy it", run: "screencapture -ic" },
    Cmd { id: "downloads",  title: "Open Downloads",     sub: "Reveal the Downloads folder", run: "open ~/Downloads" },
    Cmd { id: "volup",      title: "Volume Up",          sub: "Raise output volume",         run: "osascript -e 'set volume output volume ((output volume of (get volume settings)) + 10)'" },
    Cmd { id: "voldown",    title: "Volume Down",        sub: "Lower output volume",         run: "osascript -e 'set volume output volume ((output volume of (get volume settings)) - 10)'" },
    Cmd { id: "mute",       title: "Toggle Mute",        sub: "Mute / unmute audio",         run: "osascript -e 'set volume output muted (not (output muted of (get volume settings)))'" },
    Cmd { id: "hiddenfiles",title: "Toggle Hidden Files",sub: "Show / hide dotfiles in Finder", run: "v=$(defaults read com.apple.finder AppleShowAllFiles 2>/dev/null); if [ \"$v\" = 1 ] || [ \"$v\" = YES ]; then defaults write com.apple.finder AppleShowAllFiles -bool false; else defaults write com.apple.finder AppleShowAllFiles -bool true; fi; killall Finder" },
    Cmd { id: "desktopicons", title: "Toggle Desktop Icons", sub: "Hide clutter for screen sharing", run: "v=$(defaults read com.apple.finder CreateDesktop 2>/dev/null); if [ \"$v\" = 0 ] || [ \"$v\" = false ]; then defaults write com.apple.finder CreateDesktop -bool true; else defaults write com.apple.finder CreateDesktop -bool false; fi; killall Finder" },
    Cmd { id: "dockhide",   title: "Toggle Dock Auto-hide", sub: "Show / hide the macOS Dock", run: "osascript -e 'tell application \"System Events\" to tell dock preferences to set autohide to not autohide'" },
    Cmd { id: "restartdock",title: "Restart Dock",       sub: "Relaunch the Dock",           run: "killall Dock" },
    Cmd { id: "restartfinder", title: "Restart Finder",  sub: "Relaunch Finder",             run: "killall Finder" },
    Cmd { id: "ejectall",   title: "Eject All Disks",    sub: "Unmount external volumes",    run: "osascript -e 'tell application \"Finder\" to eject (every disk whose ejectable is true)'" },
    Cmd { id: "caffeinate", title: "Keep Awake (1 hour)",sub: "Prevent sleep for 60 minutes",run: "nohup caffeinate -dimsu -t 3600 >/dev/null 2>&1 &" },
    Cmd { id: "decaf",      title: "Allow Sleep",        sub: "Stop Keep Awake",             run: "pkill -x caffeinate; true" },
    Cmd { id: "activity",   title: "Activity Monitor",   sub: "See what's eating your CPU",  run: "open -a 'Activity Monitor'" },
];

#[cfg(not(target_os = "macos"))]
const COMMANDS: &[Cmd] = &[
    Cmd { id: "lock",      title: "Lock Screen", sub: "Lock the session",  run: "loginctl lock-session" },
    Cmd { id: "downloads", title: "Open Downloads", sub: "Reveal Downloads", run: "xdg-open ~/Downloads" },
];

pub struct CommandsPlugin {
    matcher: SkimMatcherV2,
}

impl CommandsPlugin {
    pub fn new() -> Self { Self { matcher: SkimMatcherV2::default() } }
}

impl Default for CommandsPlugin {
    fn default() -> Self { Self::new() }
}

#[async_trait]
impl Plugin for CommandsPlugin {
    fn id(&self)   -> &str { "commands" }
    fn name(&self) -> &str { "Commands" }
    fn icon(&self) -> &str { "command" }

    async fn count(&self) -> u64 { COMMANDS.len() as u64 }

    async fn sync(&self) -> Result<usize> { Ok(COMMANDS.len()) }

    async fn search(&self, query: &SearchQuery) -> Result<Vec<SearchResult>> {
        let q = query.raw.trim();
        // Only surface commands when the user is actually typing — keeps the
        // empty *root* palette focused on apps/recents. But when explicitly in
        // the System Commands scope (source_filter=commands), browse the full
        // list on empty query.
        if q.is_empty() {
            let scoped = query.source_filter.as_ref()
                .map_or(false, |f| f.iter().any(|s| s == "commands"));
            if !scoped { return Ok(vec![]); }
            let results = COMMANDS.iter().map(|c| make_result(c, 0.8)).collect();
            return Ok(results);
        }

        let mut out: Vec<(i64, SearchResult)> = COMMANDS.iter()
            .filter_map(|c| {
                // Match against title and subtitle.
                let s = self.matcher.fuzzy_match(c.title, q)
                    .or_else(|| self.matcher.fuzzy_match(c.sub, q))?;
                Some((s, make_result(c, (s as f32 / 100.0).clamp(0.55, 0.97))))
            })
            .collect();
        out.sort_by(|a, b| b.0.cmp(&a.0));
        let results: Vec<SearchResult> = out.into_iter().take(6).map(|(_, r)| r).collect();
        tracing::debug!(target: "aio_cortex_lib", "commands: '{q}' → {} matches", results.len());
        Ok(results)
    }

    async fn execute(&self, result: &SearchResult) -> Result<()> {
        // Resolve by id against the compiled-in table — never execute a shell
        // line carried in (mutable, cache-round-tripped) result metadata.
        let id = result.id.strip_prefix("cmd:").unwrap_or(&result.id);
        let cmd = COMMANDS.iter().find(|c| c.id == id)
            .ok_or_else(|| anyhow::anyhow!("unknown command: {id}"))?;
        tracing::info!(target: "aio_cortex_lib", "commands: exec `{}`", cmd.id);
        let mut child = Command::new("sh").arg("-c").arg(cmd.run).spawn()?;
        // Reap in the background so finished commands don't linger as zombies.
        std::thread::spawn(move || { let _ = child.wait(); });
        Ok(())
    }
}

fn make_result(c: &Cmd, score: f32) -> SearchResult {
    let mut r = SearchResult::new("commands", c.title);
    r.id          = format!("cmd:{}", c.id);
    r.source_type = SourceType::Unknown;
    r.subtitle    = Some(c.sub.to_string());
    r.score       = score;
    r.action      = ResultAction::Run;
    r.metadata.insert("run".into(), serde_json::Value::String(c.run.to_string()));
    r
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ids_are_unique() {
        let mut ids: Vec<_> = COMMANDS.iter().map(|c| c.id).collect();
        ids.sort();
        let before = ids.len();
        ids.dedup();
        assert_eq!(before, ids.len());
    }

    #[tokio::test]
    async fn unknown_id_is_rejected() {
        let p = CommandsPlugin::new();
        let mut r = SearchResult::new("commands", "x");
        r.id = "cmd:does-not-exist".into();
        r.metadata.insert("run".into(), serde_json::Value::String("echo pwned".into()));
        assert!(p.execute(&r).await.is_err());
    }
}
