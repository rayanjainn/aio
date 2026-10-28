/// Embedding + vector-search infrastructure.
///
/// Embeddings: Nomic-embed-text via Ollama (localhost:11434) by default.
///             Override with `CORTEX_EMBED_URL`.
///
/// Vector DB:  Qdrant REST API (localhost:6333) by default.
///             Override with `CORTEX_QDRANT_URL`.
///
/// Both are optional — if unavailable, semantic search degrades gracefully to
/// fuzzy text search; the calling plugin catches errors and continues.

use anyhow::{Context, Result};
use serde_json::{json, Value};
use std::sync::Arc;
use uuid::Uuid;

/* ─── Nomic embed client ────────────────────────────────── */

const DEFAULT_EMBED_URL: &str = "http://localhost:11434/api/embeddings";
const EMBED_MODEL: &str = "nomic-embed-text";
const EMBED_DIM: usize = 768;

#[derive(Clone)]
pub struct EmbedClient {
    http:    reqwest::Client,
    url:     String,
    pub dim: usize,
}

impl EmbedClient {
    pub fn new() -> Self {
        Self {
            http: reqwest::Client::new(),
            url:  std::env::var("CORTEX_EMBED_URL")
                      .unwrap_or_else(|_| DEFAULT_EMBED_URL.to_string()),
            dim:  EMBED_DIM,
        }
    }

    /// Embed `text` → float vector of length `self.dim`.
    /// Returns `Err` if Ollama is not running; callers must handle gracefully.
    pub async fn embed(&self, text: &str) -> Result<Vec<f32>> {
        let body = json!({ "model": EMBED_MODEL, "prompt": text });
        let resp: Value = self.http
            .post(&self.url)
            .json(&body)
            .timeout(std::time::Duration::from_secs(30))
            .send()
            .await
            .context("embed request")?
            .json()
            .await
            .context("embed parse")?;
        resp["embedding"]
            .as_array()
            .ok_or_else(|| anyhow::anyhow!("no embedding field"))?
            .iter()
            .map(|v| v.as_f64().map(|f| f as f32).ok_or_else(|| anyhow::anyhow!("bad float")))
            .collect()
    }
}

/* ─── Qdrant REST client ────────────────────────────────── */

const DEFAULT_QDRANT_URL: &str = "http://localhost:6333";

#[derive(Clone)]
pub struct QdrantClient {
    http:     reqwest::Client,
    base_url: String,
}

impl QdrantClient {
    pub fn new() -> Self {
        Self {
            http:     reqwest::Client::new(),
            base_url: std::env::var("CORTEX_QDRANT_URL")
                          .unwrap_or_else(|_| DEFAULT_QDRANT_URL.to_string()),
        }
    }

    /// Create collection if it does not already exist.
    pub async fn ensure_collection(&self, name: &str, dim: usize) -> Result<()> {
        let url = format!("{}/collections/{}", self.base_url, name);
        let resp = self.http.get(&url).send().await;
        if resp.map(|r| r.status().is_success()).unwrap_or(false) {
            return Ok(()); // already exists
        }
        let body = json!({
            "vectors": { "size": dim, "distance": "Cosine" }
        });
        self.http.put(&url).json(&body).send().await
            .context("qdrant create collection")?;
        Ok(())
    }

    /// Upsert a single vector point.  `id` is hashed to a deterministic UUID.
    pub async fn upsert(
        &self,
        collection: &str,
        id: &str,
        vector: Vec<f32>,
        payload: Value,
    ) -> Result<()> {
        let url = format!("{}/collections/{}/points?wait=true", self.base_url, collection);
        let point_id = str_to_uuid(id);
        let body = json!({
            "points": [{ "id": point_id.to_string(), "vector": vector, "payload": payload }]
        });
        self.http.put(&url).json(&body).send().await
            .context("qdrant upsert")?;
        Ok(())
    }

    /// Vector-search, return (payload_id: String, score: f32).
    pub async fn search(
        &self,
        collection: &str,
        vector: Vec<f32>,
        limit: usize,
    ) -> Result<Vec<(String, f32)>> {
        let url = format!("{}/collections/{}/points/search", self.base_url, collection);
        let body = json!({
            "vector": vector,
            "limit": limit,
            "with_payload": ["id"]
        });
        let resp: Value = self.http.post(&url).json(&body).send().await
            .context("qdrant search")?
            .json().await
            .context("qdrant search parse")?;
        let hits = resp["result"].as_array().cloned().unwrap_or_default();
        Ok(hits.into_iter().filter_map(|h| {
            let id    = h["payload"]["id"].as_str()?.to_string();
            let score = h["score"].as_f64()? as f32;
            Some((id, score))
        }).collect())
    }
}

/// Deterministic UUID v5 from arbitrary string.
fn str_to_uuid(s: &str) -> Uuid {
    Uuid::new_v5(&Uuid::NAMESPACE_OID, s.as_bytes())
}

/* ─── Shared handle ─────────────────────────────────────── */

#[derive(Clone)]
pub struct VectorStore {
    pub embed:  Arc<EmbedClient>,
    pub qdrant: Arc<QdrantClient>,
}

impl VectorStore {
    pub fn new() -> Self {
        Self {
            embed:  Arc::new(EmbedClient::new()),
            qdrant: Arc::new(QdrantClient::new()),
        }
    }

    /// Embed text and upsert into collection.  Silently skips if Ollama/Qdrant
    /// are offline (graceful degradation).
    pub async fn index(
        &self,
        collection: &str,
        id: &str,
        text: &str,
        payload: Value,
    ) {
        let vec = match self.embed.embed(text).await {
            Ok(v) => v,
            Err(e) => {
                tracing::debug!("embed skip ({collection}/{id}): {e}");
                return;
            }
        };
        let dim = vec.len();
        if let Err(e) = self.qdrant.ensure_collection(collection, dim).await {
            tracing::debug!("qdrant collection: {e}");
            return;
        }
        if let Err(e) = self.qdrant.upsert(collection, id, vec, payload).await {
            tracing::debug!("qdrant upsert ({collection}/{id}): {e}");
        }
    }

    /// Search collection.  Returns empty vec if Qdrant/Ollama unavailable.
    pub async fn search(&self, collection: &str, query: &str, limit: usize) -> Vec<(String, f32)> {
        let vec = match self.embed.embed(query).await {
            Ok(v)  => v,
            Err(_) => return vec![],
        };
        self.qdrant.search(collection, vec, limit).await.unwrap_or_default()
    }
}
