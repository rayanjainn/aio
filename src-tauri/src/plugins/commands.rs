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
    Cmd { id: "lock",       title: "Lock Screen",        sub: "Lock the display",            run: "pmset displaysleepnow" },
    Cmd { id: "sleep",      title: "Sleep",              sub: "Put the Mac to sleep",        run: "pmset sleepnow" },
    Cmd { id: "screensaver",title: "Start Screen Saver", sub: "Launch the screen saver",     run: "open -a ScreenSaverEngine" },
    Cmd { id: "emptytrash", title: "Empty Trash",        sub: "Permanently delete trash",    run: "osascript -e 'tell application \"Finder\" to empty trash'" },
    Cmd { id: "opentrash",  title: "Open Trash",         sub: "Reveal the Trash folder",     run: "open ~/.Trash" },
    Cmd { id: "darkmode",   title: "Toggle Dark Mode",   sub: "Switch light / dark theme",   run: "osascript -e 'tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode'" },
    Cmd { id: "togglewifi", title: "Toggle Wi-Fi",       sub: "Turn Wi-Fi on or off",        run: "networksetup -setairportpower en0 $(networksetup -getairportpower en0 | grep -q On && echo off || echo on)" },
    Cmd { id: "flushdns",   title: "Flush DNS Cache",    sub: "Reset the DNS resolver cache",run: "sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder" },
    Cmd { id: "screenshot", title: "Take Screenshot",    sub: "Capture a region to a file",  run: "screencapture -i ~/Desktop/cortex-shot.png" },
    Cmd { id: "downloads",  title: "Open Downloads",     sub: "Reveal the Downloads folder", run: "open ~/Downloads" },
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
        let run = result.metadata.get("run").and_then(|v| v.as_str())
            .ok_or_else(|| anyhow::anyhow!("command has no run payload"))?;
        tracing::info!(target: "aio_cortex_lib", "commands: exec `{run}`");
        Command::new("sh").arg("-c").arg(run).spawn()?;
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
