/// Intent parser — phi3:mini via Ollama.
///
/// Sends the user query to phi3:mini with a system prompt that forces JSON
/// output. Hard 3-second timeout; falls back to a default `ParsedIntent`
/// (pure BM25 mode) on any failure so the search path is never blocked.

use anyhow::Result;
use reqwest::Client;
use serde::{Deserialize, Serialize};
use std::time::Duration;
use tokio::time::timeout;

const PHI3_MODEL: &str = "phi3:mini";
const OLLAMA_GENERATE: &str = "http://localhost:11434/api/generate";
const INTENT_TIMEOUT: Duration = Duration::from_secs(3);

/* ─── System prompt ──────────────────────────────────────── */

const SYSTEM_PROMPT: &str = r#"You are a search intent parser. Output ONLY valid JSON, no explanation.

Given a user query, output:
{
  "is_execution": bool,        // true if user wants to RUN something (start/stop/deploy/kill/restart)
  "temporal_filter": {
    "label": "string or null", // natural language time ref, e.g. "last Tuesday"
    "relative": "string or null" // "yesterday"|"last_week"|"last_month"|"N_days_ago"|null
  } or null,
  "topic": "string",           // 2-3 word topic summary
  "source_hints": ["file"|"shell"|"git"|"browser"|"email"|"slack"|"docker"|"vscode"]  // likely sources
}

Examples:
query: "show me the redis config I edited last week" → {"is_execution":false,"temporal_filter":{"label":"last week","relative":"last_week"},"topic":"redis config","source_hints":["file","git"]}
query: "restart the api server" → {"is_execution":true,"temporal_filter":null,"topic":"api server","source_hints":["shell","docker"]}
"#;

/* ─── Output types ───────────────────────────────────────── */

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct ParsedIntent {
    pub is_execution:    bool,
    pub temporal_filter: Option<TemporalHint>,
    pub topic:           String,
    pub source_hints:    Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TemporalHint {
    pub label:    Option<String>,
    pub relative: Option<String>,
}

/* ─── Parser ─────────────────────────────────────────────── */

pub struct IntentParser {
    http: Client,
}

impl IntentParser {
    pub fn new() -> Self {
        Self {
            http: Client::builder()
                // Individual request timeouts are handled via tokio::time::timeout
                // so we give the client a generous overall limit.
                .timeout(Duration::from_secs(10))
                .build()
                .expect("reqwest client"),
        }
    }

    /// Parse query intent with a 3 s hard timeout.
    /// Returns `ParsedIntent::default()` on timeout or any error, allowing
    /// the caller to fall back to BM25-only search immediately.
    pub async fn parse(&self, query: &str) -> ParsedIntent {
        timeout(INTENT_TIMEOUT, self.call_phi3(query))
            .await
            // outer Err → timeout elapsed
            .unwrap_or_else(|_| {
                tracing::debug!("intent parse timeout for: {query}");
                Ok(ParsedIntent::default())
            })
            // inner Err → LLM/network error
            .unwrap_or_else(|e| {
                tracing::debug!("intent parse error: {e}");
                ParsedIntent::default()
            })
    }

    /// Call phi3:mini on Ollama's /api/generate endpoint (stream: false).
    async fn call_phi3(&self, query: &str) -> Result<ParsedIntent> {
        let body = serde_json::json!({
            "model":  PHI3_MODEL,
            "prompt": format!("Query: {}", query),
            "system": SYSTEM_PROMPT,
            "stream": false,
            "format": "json",
            "options": {
                "temperature": 0.0,
                "num_predict": 256
            }
        });

        let resp: serde_json::Value = self
            .http
            .post(OLLAMA_GENERATE)
            .json(&body)
            .send()
            .await?
            .json()
            .await?;

        let text = resp["response"].as_str().unwrap_or("{}");
        serde_json::from_str::<ParsedIntent>(text)
            .map_err(|e| anyhow::anyhow!("intent parse JSON error: {e}\nraw: {text}"))
    }
}

impl Default for IntentParser {
    fn default() -> Self {
        Self::new()
    }
}
