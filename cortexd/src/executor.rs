// executor.rs
// Execution mode: NL → shell command via phi3:mini → collect output.
//
// Flow:
//   1. ExecutorRequest { query, session_context } → plan()
//   2. Returns ExecutorPlan { command, explanation, is_destructive }
//   3. UI shows ExecutionConfirm with the command (exec_ipc::plan_execution)
//   4. After user confirms: run_command() spawns and collects output lines

use anyhow::Result;
use reqwest::Client;
use serde::{Deserialize, Serialize};
use std::time::Duration;
use tokio::time::timeout;

// Fallback model name when no `chat_model` is configured (local-only setups).
const PHI3_MODEL: &str = "phi3:mini";
const PLAN_TIMEOUT: Duration = Duration::from_secs(45);
/// Hard cap on how long a confirmed command may run.
const RUN_TIMEOUT: Duration = Duration::from_secs(120);
/// Per-stream output cap — keeps a runaway `yes` from eating memory.
const MAX_LINES: usize = 5_000;

const EXEC_SYSTEM_PROMPT: &str = r#"You are a shell command generator for macOS/Linux.
Given a user's intent and recent session context, output ONLY valid JSON:
{
  "command": "the exact shell command to run",
  "explanation": "one sentence explaining what it does",
  "is_destructive": false
}

Rules:
- Prefer safe, non-destructive commands
- Set is_destructive=true if command deletes/overwrites/kills processes
- Use current directory shortcuts when context has a relevant cwd
- Never include credentials or secrets
- Keep commands concise and correct
"#;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExecutorRequest {
    pub query: String,
    /// Recent session context: recent commands, active app, cwd
    pub session_context: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExecutorPlan {
    pub command: String,
    pub explanation: String,
    pub is_destructive: bool,
}

impl Default for ExecutorPlan {
    fn default() -> Self {
        Self {
            command: String::new(),
            explanation: "Could not generate command".into(),
            is_destructive: false,
        }
    }
}

/// Robustly parse phi3's reply into an ExecutorPlan. Handles strict JSON,
/// JSON embedded in prose, ```json fences, and field-name variance.
fn parse_plan(text: &str) -> Result<ExecutorPlan> {
    // 1) strict
    if let Ok(p) = serde_json::from_str::<ExecutorPlan>(text) {
        if !p.command.is_empty() { return Ok(p); }
    }
    // 2) extract the first {...} block
    let slice = match (text.find('{'), text.rfind('}')) {
        (Some(a), Some(b)) if b > a => &text[a..=b],
        _ => text,
    };
    if let Ok(v) = serde_json::from_str::<serde_json::Value>(slice) {
        let command = v["command"].as_str()
            .or_else(|| v["cmd"].as_str())
            .or_else(|| v["shell"].as_str())
            .unwrap_or("").trim().to_string();
        if !command.is_empty() {
            return Ok(ExecutorPlan {
                command,
                explanation: v["explanation"].as_str().or_else(|| v["description"].as_str()).unwrap_or("").to_string(),
                is_destructive: v["is_destructive"].as_bool().unwrap_or(false),
            });
        }
    }
    // 3) last resort: treat the whole reply as a command if it looks like one
    let line = text.lines().find(|l| !l.trim().is_empty()).unwrap_or("").trim();
    if !line.is_empty() && !line.starts_with('{') {
        return Ok(ExecutorPlan { command: line.to_string(), explanation: "Generated command".into(), is_destructive: false });
    }
    anyhow::bail!("model returned no usable command")
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExecOutput {
    pub line: String,
    pub is_stderr: bool,
    pub exit_code: Option<i32>,
}

pub struct Executor {
    http: Client,
}

impl Executor {
    pub fn new() -> Self {
        Self { http: Client::new() }
    }

    /// Generate an ExecutorPlan from a natural language query.
    /// 5s timeout; returns default (empty command) on failure.
    pub async fn plan(&self, req: &ExecutorRequest) -> ExecutorPlan {
        match timeout(PLAN_TIMEOUT, self.call_phi3(req)).await {
            Err(_) => {
                tracing::warn!(target: "aio_cortex_lib", "exec plan: phi3 timed out after {}s", PLAN_TIMEOUT.as_secs());
                ExecutorPlan { command: String::new(), explanation: "AI timed out — is phi3:mini pulled and Ollama running?".into(), is_destructive: false }
            }
            Ok(Err(e)) => {
                tracing::warn!(target: "aio_cortex_lib", "exec plan: {e}");
                ExecutorPlan { command: String::new(), explanation: format!("AI error: {e}"), is_destructive: false }
            }
            Ok(Ok(mut plan)) => {
                plan.is_destructive |= looks_destructive(&plan.command);
                plan
            }
        }
    }

    async fn call_phi3(&self, req: &ExecutorRequest) -> Result<ExecutorPlan> {
        // Same Ollama target as chat — cloud when an api_key is configured.
        let cfg = crate::exec_ipc::ollama_cfg();
        let model = if cfg.model.is_empty() { PHI3_MODEL.to_string() } else { cfg.model.clone() };
        let url = format!("{}/api/generate", cfg.host);
        let prompt = format!(
            "Session context:\n{}\n\nUser intent: {}\n\nReply with ONLY the JSON object.",
            req.session_context, req.query
        );
        let body = serde_json::json!({
            "model": model,
            "prompt": prompt,
            "system": EXEC_SYSTEM_PROMPT,
            "stream": false,
            "format": "json",
            "options": { "temperature": 0.1, "num_predict": 256 }
        });
        let mut rb = self.http.post(&url).json(&body).timeout(PLAN_TIMEOUT);
        if let Some(k) = &cfg.api_key { rb = rb.bearer_auth(k); }
        let resp: serde_json::Value = rb
            .send()
            .await
            .map_err(|e| anyhow::anyhow!("Ollama unreachable: {e}"))?
            .json()
            .await?;
        let text = resp["response"].as_str().unwrap_or("").trim();
        tracing::debug!(target: "aio_cortex_lib", "exec plan raw: {text}");
        parse_plan(text)
    }

    /// Spawn a shell command, collect stdout/stderr lines, return them.
    ///
    /// Both pipes are drained concurrently — reading stdout to EOF before
    /// touching stderr deadlocks as soon as the child fills the stderr pipe
    /// buffer (~64 KB). The command is killed after `RUN_TIMEOUT` so an
    /// interactive program (`top`, `vim`, a server) can never hang the UI, and
    /// output is capped at `MAX_LINES` per stream. The final entry carries the
    /// exit code (-1 when killed by timeout or signal).
    pub async fn run_command(&self, command: &str) -> Result<Vec<ExecOutput>> {
        use tokio::io::{AsyncBufReadExt, BufReader};
        use tokio::process::Command;

        let mut child = Command::new("sh")
            .arg("-c")
            .arg(command)
            .current_dir(dirs::home_dir().unwrap_or_else(|| ".".into()))
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .kill_on_drop(true)
            .spawn()?;

        let stdout = child.stdout.take().ok_or_else(|| anyhow::anyhow!("no stdout handle"))?;
        let stderr = child.stderr.take().ok_or_else(|| anyhow::anyhow!("no stderr handle"))?;

        async fn drain<R: tokio::io::AsyncRead + Unpin>(r: R, is_stderr: bool) -> Vec<ExecOutput> {
            let mut lines = BufReader::new(r).lines();
            let mut out = Vec::new();
            while let Ok(Some(line)) = lines.next_line().await {
                if out.len() < MAX_LINES {
                    out.push(ExecOutput { line, is_stderr, exit_code: None });
                }
            }
            out
        }

        let run = async {
            let (out, err) = tokio::join!(drain(stdout, false), drain(stderr, true));
            (out, err, child.wait().await)
        };

        let (mut outputs, code) = match timeout(RUN_TIMEOUT, run).await {
            Ok((mut out, err, status)) => {
                out.extend(err);
                (out, status?.code().unwrap_or(-1))
            }
            Err(_) => {
                let _ = child.start_kill();
                let msg = format!("Timed out after {}s — process killed", RUN_TIMEOUT.as_secs());
                (vec![ExecOutput { line: msg, is_stderr: true, exit_code: None }], -1)
            }
        };

        match outputs.last_mut() {
            Some(last) => last.exit_code = Some(code),
            None => outputs.push(ExecOutput { line: String::new(), is_stderr: false, exit_code: Some(code) }),
        }
        Ok(outputs)
    }
}

/// Local safety net for the model's `is_destructive` flag. A small model can
/// (and does) label `rm -rf ~/x` as harmless — any command matching one of
/// these patterns is always shown with the destructive warning.
pub fn looks_destructive(command: &str) -> bool {
    use std::sync::OnceLock;
    static RE: OnceLock<regex::Regex> = OnceLock::new();
    let re = RE.get_or_init(|| {
        regex::Regex::new(concat!(
            r"(?i)(^|[\s;&|(`])(",
            r"rm|rmdir|shred|unlink|mkfs(\.\w+)?|dd|fdisk|diskutil\s+(erase\w*|partition\w*|unmount\w*)|",
            r"kill|killall|pkill|shutdown|reboot|halt|launchctl\s+(unload|remove|bootout)|",
            r"sudo|doas|chmod|chown|chflags|truncate|mv|",
            r"git\s+(reset\s+--hard|clean\s+-\w*f|push\s+.*(--force|-f\b)|branch\s+-D|checkout\s+--\s|restore)|",
            r"docker\s+(rm|rmi|system\s+prune|volume\s+rm|kill|stop)|",
            r"brew\s+(uninstall|remove)|npm\s+uninstall|pip\s+uninstall|defaults\s+delete|",
            r"crontab\s+-r|tmutil\s+delete",
            r")(\s|$)|(^|[^>&0-9])>\s*[^&\s]|:\s*>\s*\S"
        )).expect("destructive regex")
    });
    re.is_match(command)
}

impl Default for Executor {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn run_echo_command() {
        let ex = Executor::new();
        let out = ex.run_command("echo hello").await.unwrap();
        assert!(!out.is_empty());
        assert_eq!(out[0].line, "hello");
        // last entry carries exit code
        let last = out.last().unwrap();
        assert_eq!(last.exit_code, Some(0));
    }

    #[tokio::test]
    async fn large_stderr_does_not_deadlock() {
        // 200 KB on stderr overflows the pipe buffer; sequential draining hung here.
        let ex = Executor::new();
        let fut = ex.run_command("head -c 200000 /dev/zero | tr '\\0' 'x' | fold -w 100 >&2; echo done");
        let out = tokio::time::timeout(Duration::from_secs(10), fut).await.expect("deadlocked").unwrap();
        assert!(out.iter().any(|o| o.line == "done" && !o.is_stderr));
        assert!(out.iter().filter(|o| o.is_stderr).count() >= 2000);
        assert_eq!(out.last().unwrap().exit_code, Some(0));
    }

    #[test]
    fn destructive_heuristic() {
        for c in ["rm -rf ~/tmp", "sudo shutdown -h now", "git push origin main --force",
                  "echo hi > notes.txt", "docker system prune -a", "cd x && rm a",
                  "killall Dock", "git reset --hard HEAD~1", "mv a b"] {
            assert!(looks_destructive(c), "should flag: {c}");
        }
        for c in ["ls -la", "git status", "echo hi 2>&1", "cat a | grep b", "docker ps",
                  "brew list", "find . -name '*.rs'", "du -sh ~/Downloads", "echo storm"] {
            assert!(!looks_destructive(c), "should not flag: {c}");
        }
    }

    #[tokio::test]
    async fn failing_command_returns_nonzero_exit() {
        let ex = Executor::new();
        let out = ex.run_command("exit 42").await.unwrap();
        let code = out.last().and_then(|o| o.exit_code).unwrap_or(0);
        assert_eq!(code, 42);
    }
}
