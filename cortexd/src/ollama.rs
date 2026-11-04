/// Ollama health-check + model-watch module.
///
/// On startup, pings localhost:11434/api/tags to verify required models are
/// present. Re-checks every 30 s in a background task and updates the shared
/// `OllamaStatus`.

use anyhow::{Context, Result};
use reqwest::Client;
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use tokio::{
    sync::RwLock,
    time::{sleep, Duration},
};

const OLLAMA_BASE: &str = "http://localhost:11434";
// phi3 removed — chat runs on Ollama Cloud now. nomic-embed-text powers local
// semantic search only (optional; search still works via BM25/fuzzy without it).
const REQUIRED_MODELS: &[&str] = &["nomic-embed-text"];
const WATCH_INTERVAL: Duration = Duration::from_secs(30);

/* ─── Status type ───────────────────────────────────────── */

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum OllamaStatus {
    /// Ollama running, all required models present.
    Ready,
    /// Ollama running but some models are missing. Vec contains missing names.
    MissingModels(Vec<String>),
    /// Ollama not reachable (not installed or not running).
    Unavailable,
}

/* ─── Wire types from /api/tags ─────────────────────────── */

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ModelInfo {
    pub name: String,
    pub size: u64,
}

#[derive(Debug, Deserialize)]
struct TagsResponse {
    models: Vec<TagsModel>,
}

#[derive(Debug, Deserialize)]
struct TagsModel {
    name: String,
    size: u64,
}

/* ─── Client ────────────────────────────────────────────── */

#[derive(Clone)]
pub struct OllamaClient {
    http: Client,
    pub status: Arc<RwLock<OllamaStatus>>,
    base_url: String,
}

impl OllamaClient {
    pub fn new() -> Self {
        Self {
            http: Client::builder()
                .timeout(Duration::from_secs(10))
                .build()
                .expect("reqwest client"),
            status: Arc::new(RwLock::new(OllamaStatus::Unavailable)),
            base_url: OLLAMA_BASE.to_string(),
        }
    }

    /// Check health once, update `self.status`, and return the new status.
    pub async fn check_health(&self) -> OllamaStatus {
        let status = match self.list_models().await {
            Err(_) => OllamaStatus::Unavailable,
            Ok(models) => {
                // Strip `:tag` suffix for matching — "nomic-embed-text:latest" → "nomic-embed-text"
                let available: Vec<&str> = models
                    .iter()
                    .map(|m| m.name.split(':').next().unwrap_or(&m.name))
                    .collect();

                // Compare on base name (strip `:tag` from BOTH sides) — otherwise
                // required "phi3:mini" never matches available "phi3" and the model
                // is forever reported missing.
                let missing: Vec<String> = REQUIRED_MODELS
                    .iter()
                    .filter(|&&req| {
                        let req_base = req.split(':').next().unwrap_or(req);
                        !available.iter().any(|a| *a == req_base)
                    })
                    .map(|s| s.to_string())
                    .collect();

                if missing.is_empty() {
                    OllamaStatus::Ready
                } else {
                    OllamaStatus::MissingModels(missing)
                }
            }
        };

        *self.status.write().await = status.clone();
        status
    }

    /// Fetch model list from GET /api/tags.
    pub async fn list_models(&self) -> Result<Vec<ModelInfo>> {
        let url = format!("{}/api/tags", self.base_url);
        let resp: TagsResponse = self
            .http
            .get(&url)
            .send()
            .await
            .context("ollama /api/tags request")?
            .json()
            .await
            .context("ollama /api/tags parse")?;

        Ok(resp
            .models
            .into_iter()
            .map(|m| ModelInfo {
                name: m.name,
                size: m.size,
            })
            .collect())
    }

    /// POST /api/pull (stream: false) — blocks until pull completes.
    /// Returns when Ollama finishes downloading or errors.
    pub async fn pull_model(&self, model: &str) -> Result<()> {
        let url = format!("{}/api/pull", self.base_url);
        // Use stream:false so the response is a single JSON object.
        let body = serde_json::json!({ "name": model, "stream": false });

        let resp: serde_json::Value = self
            .http
            .post(&url)
            .json(&body)
            .timeout(Duration::from_secs(600)) // pulls can take minutes
            .send()
            .await
            .context("ollama pull request")?
            .json()
            .await
            .context("ollama pull parse")?;

        if let Some(err) = resp["error"].as_str() {
            anyhow::bail!("ollama pull error: {err}");
        }

        let status = resp["status"].as_str().unwrap_or("unknown");
        tracing::info!("pull {model}: {status}");
        Ok(())
    }

    /// Background loop: re-check health every 30 s and update `self.status`.
    pub async fn watch(self: Arc<Self>) {
        loop {
            let status = self.check_health().await;
            tracing::info!("ollama status: {:?}", status);
            sleep(WATCH_INTERVAL).await;
        }
    }
}

impl Default for OllamaClient {
    fn default() -> Self {
        Self::new()
    }
}
