//! Executing a result: open / run / copy by `SourceType` (moved verbatim from the old
//! desktop app's IPC layer).

use crate::plugin::{SearchResult, SourceType};

/// Dispatch an action based on the result's `source_type`.
pub fn execute_by_type(result: &SearchResult) -> anyhow::Result<()> {
    match &result.source_type {
        // ── File: open with OS default application ─────────
        SourceType::File => {
            let path = result.path.as_deref()
                .ok_or_else(|| anyhow::anyhow!("File result has no path"))?;
            opener::open(path)?;
        }

        // ── URL: open in default browser ───────────────────
        SourceType::Url => {
            let url = result.url.as_deref()
                .ok_or_else(|| anyhow::anyhow!("Url result has no url"))?;
            webbrowser::open(url)?;
        }

        // ── Shell command: run in a visible terminal ────────
        SourceType::ShellCommand => {
            let cmd = result.title.as_str();
            spawn_in_terminal(cmd)?;
        }

        // ── Git commit: git show <sha> in terminal ──────────
        SourceType::GitCommit => {
            let sha = result.metadata
                .get("sha")
                .and_then(|v| v.as_str())
                .unwrap_or("HEAD");
            let repo_path = result.metadata
                .get("repo_path")
                .and_then(|v| v.as_str())
                .unwrap_or(".");
            let cmd = format!("git -C {} show {}", shell_quote(repo_path), shell_quote(sha));
            spawn_in_terminal(&cmd)?;
        }

        // ── Clipboard: write content back to clipboard ──────
        SourceType::ClipboardText => {
            let text = result.content.as_deref()
                .unwrap_or(result.title.as_str());
            arboard::Clipboard::new()?.set_text(text.to_string())?;
        }

        // ── Unknown: best-effort fallback ───────────────────
        SourceType::Unknown => {
            if let Some(path) = &result.path {
                opener::open(path)?;
            } else if let Some(url) = &result.url {
                webbrowser::open(url)?;
            }
            // else: no-op
        }
    }
    Ok(())
}

/* ─── Terminal spawn ─────────────────────────────────────
   Opens a new terminal window running `cmd`.
   macOS  → Terminal.app via AppleScript
   Linux  → detects $TERM_PROGRAM, falls back to xterm
   Windows → cmd.exe /c start cmd /k
────────────────────────────────────────────────────────── */

/// POSIX single-quote a string for safe interpolation into `sh -c` lines.
pub fn shell_quote(s: &str) -> String {
    if !s.is_empty() && s.chars().all(|c| c.is_ascii_alphanumeric() || "-_./:@%+=,".contains(c)) {
        return s.to_string();
    }
    format!("'{}'", s.replace('\'', r"'\''"))
}

fn spawn_in_terminal(cmd: &str) -> anyhow::Result<()> {
    #[cfg(target_os = "macos")]
    let term = crate::config_ipc::configured_terminal();

    #[cfg(target_os = "macos")]
    {
        let escaped = cmd.replace('\\', "\\\\").replace('"', "\\\"");
        match term.as_str() {
            // AppleScript-driven terminals.
            "Terminal" | "iTerm" | "iTerm2" => {
                let app = if term.starts_with("iTerm") { "iTerm" } else { "Terminal" };
                let script = if app == "iTerm" {
                    format!(r#"tell application "iTerm"
                        create window with default profile
                        tell current session of current window to write text "{escaped}"
                        activate
                    end tell"#)
                } else {
                    format!(r#"tell application "Terminal"
                        do script "{escaped}"
                        activate
                    end tell"#)
                };
                std::process::Command::new("osascript").args(["-e", &script]).spawn()?;
            }
            // CLI terminals that accept `-e`/`start`.
            "kitty"     => { std::process::Command::new("kitty").args(["sh", "-c", &format!("{cmd}; exec $SHELL")]).spawn()?; }
            "Alacritty" => { std::process::Command::new("alacritty").args(["-e", "sh", "-c", &format!("{cmd}; exec $SHELL")]).spawn()?; }
            "WezTerm"   => { std::process::Command::new("wezterm").args(["start", "--", "sh", "-c", &format!("{cmd}; exec $SHELL")]).spawn()?; }
            "Ghostty"   => { std::process::Command::new("open").args(["-a", "Ghostty"]).spawn()?;
                             std::process::Command::new("osascript").args(["-e", &format!(r#"tell application "Terminal" to do script "{escaped}""#)]).spawn().ok(); }
            other       => { std::process::Command::new("open").args(["-a", other]).spawn()?; }
        }
        return Ok(());
    }

    #[cfg(target_os = "linux")]
    {
        // Prefer the running terminal emulator; fall back down the list
        let term = detect_linux_terminal();
        std::process::Command::new(&term)
            .args(terminal_exec_args(&term, cmd))
            .spawn()?;
        return Ok(());
    }

    #[cfg(target_os = "windows")]
    {
        std::process::Command::new("cmd")
            .args(["/c", "start", "cmd", "/k", cmd])
            .spawn()?;
        return Ok(());
    }

    #[allow(unreachable_code)]
    Ok(())
}

#[cfg(target_os = "linux")]
fn detect_linux_terminal() -> String {
    // $TERM_PROGRAM is set by VS Code, Ghostty, Warp, etc.
    // $COLORTERM / $TERM are weaker signals but useful fallbacks.
    for var in &["TERM_PROGRAM", "TERMINAL"] {
        if let Ok(v) = std::env::var(var) {
            if !v.is_empty() {
                return v;
            }
        }
    }
    // Binary availability check
    for candidate in &["ghostty", "kitty", "alacritty", "wezterm", "xterm"] {
        if which_exists(candidate) {
            return candidate.to_string();
        }
    }
    "xterm".to_string()
}

#[cfg(target_os = "linux")]
fn terminal_exec_args<'a>(term: &str, cmd: &'a str) -> Vec<&'a str> {
    // Different terminals use different flags to pass a command
    match term {
        "kitty" | "alacritty" | "ghostty" => vec!["-e", cmd],
        "wezterm"                          => vec!["start", "--", "sh", "-c", cmd],
        _                                  => vec!["-e", cmd],
    }
}

#[cfg(target_os = "linux")]
fn which_exists(bin: &str) -> bool {
    std::process::Command::new("which")
        .arg(bin)
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

