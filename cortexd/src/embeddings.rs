/// Batch embedding pipeline built on top of `embed.rs`.
///
/// Collection: `cortex_index`, dim 768, distance Cosine.
/// Payload stored per point: { item_id, source_type, plugin_id, timestamp }
///
/// Errors from Ollama or Qdrant are logged at DEBUG level and silently
/// skipped — callers never need to handle embedding failures.

use crate::embed::{EmbedClient, QdrantClient};
use anyhow::Result;
use serde_json::json;
use std::sync::{
    atomic::{AtomicI64, Ordering},
    Arc,
};

const COLLECTION: &str = "cortex_index";
const BATCH_SIZE: usize = 32;
const VECTOR_DIM: usize = 768;
const CHUNK_SIZE: usize = 512;
/// When Qdrant is unreachable, stop trying for this long (avoids per-chunk spam
/// + wasted Ollama embeds while Qdrant isn't running).
const QDRANT_BACKOFF_SECS: i64 = 120;

fn now_unix() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/* ─── Public types ──────────────────────────────────────── */

#[derive(Debug, Clone)]
pub struct EmbedRequest {
    pub item_id:     String,
    pub text:        String,
    pub source_type: String,
    pub plugin_id:   String,
    pub timestamp:   i64,
}

#[derive(Debug, Clone)]
pub struct SearchHit {
    pub item_id:     String,
    pub score:       f32,
    pub source_type: String,
    pub plugin_id:   String,
}

/* ─── Pipeline ──────────────────────────────────────────── */

pub struct EmbeddingPipeline {
    embed:  Arc<EmbedClient>,
    qdrant: Arc<QdrantClient>,
    /// Unix-secs until which Qdrant is considered down (skip work).
    qdrant_down_until: Arc<AtomicI64>,
}

impl EmbeddingPipeline {
    pub fn new(embed: Arc<EmbedClient>, qdrant: Arc<QdrantClient>) -> Self {
        Self { embed, qdrant, qdrant_down_until: Arc::new(AtomicI64::new(0)) }
    }

    fn qdrant_is_down(&self) -> bool {
        now_unix() < self.qdrant_down_until.load(Ordering::Relaxed)
    }

    fn mark_qdrant_down(&self) {
        let was_up = !self.qdrant_is_down();
        self.qdrant_down_until.store(now_unix() + QDRANT_BACKOFF_SECS, Ordering::Relaxed);
        if was_up {
            tracing::warn!(target: "aio_cortex_lib",
                "qdrant unreachable — pausing semantic indexing for {QDRANT_BACKOFF_SECS}s");
        }
    }

    /// Ensure `cortex_index` collection exists in Qdrant.
    pub async fn init(&self) -> Result<()> {
        self.qdrant.ensure_collection(COLLECTION, VECTOR_DIM).await
    }

    /// Embed and upsert a batch of items.
    /// Processes in sub-batches of BATCH_SIZE. Silently skips on errors.
    pub async fn index_batch(&self, items: Vec<EmbedRequest>) {
        // Skip entirely while Qdrant is in backoff — don't waste Ollama embeds.
        if self.qdrant_is_down() { return; }

        for chunk in items.chunks(BATCH_SIZE) {
            for item in chunk {
                if self.qdrant_is_down() { return; }

                let vector = match self.embed.embed(&item.text).await {
                    Ok(v) => v,
                    Err(e) => {
                        tracing::debug!("embed skip ({}): {e}", item.item_id);
                        continue;
                    }
                };

                let payload = json!({
                    "item_id":     item.item_id,
                    "source_type": item.source_type,
                    "plugin_id":   item.plugin_id,
                    "timestamp":   item.timestamp,
                });

                if let Err(e) = self
                    .qdrant
                    .upsert(COLLECTION, &item.item_id, vector, payload)
                    .await
                {
                    tracing::debug!("qdrant upsert skip ({}): {e}", item.item_id);
                    self.mark_qdrant_down();
                    return;
                }
            }
        }
    }

    /// Chunk `text` into 512-char windows (no overlap), embed each chunk,
    /// and store with item_id format `"{item_id}:chunk:{i}"`.
    pub async fn index_chunked(
        &self,
        item_id:     &str,
        text:        &str,
        source_type: &str,
        plugin_id:   &str,
        timestamp:   i64,
    ) {
        let chars: Vec<char> = text.chars().collect();
        let chunks: Vec<String> = chars
            .chunks(CHUNK_SIZE)
            .map(|c| c.iter().collect())
            .collect();

        let requests: Vec<EmbedRequest> = chunks
            .into_iter()
            .enumerate()
            .map(|(i, chunk_text)| EmbedRequest {
                item_id:     format!("{item_id}:chunk:{i}"),
                text:        chunk_text,
                source_type: source_type.to_string(),
                plugin_id:   plugin_id.to_string(),
                timestamp,
            })
            .collect();

        self.index_batch(requests).await;
    }

    /// Semantic search. Returns hits sorted by score descending.
    pub async fn search(&self, query: &str, limit: usize) -> Vec<SearchHit> {
        self.search_impl(query, None, limit).await
    }

    /// Semantic search filtered to a specific `source_type`.
    pub async fn search_filtered(
        &self,
        query:       &str,
        source_type: &str,
        limit:       usize,
    ) -> Vec<SearchHit> {
        self.search_impl(query, Some(source_type), limit).await
    }

    // ── Internal ──────────────────────────────────────────

    async fn search_impl(
        &self,
        query:       &str,
        source_type: Option<&str>,
        limit:       usize,
    ) -> Vec<SearchHit> {
        let vector = match self.embed.embed(query).await {
            Ok(v) => v,
            Err(e) => {
                tracing::debug!("embed search skip: {e}");
                return vec![];
            }
        };

        match source_type {
            None => self.qdrant_search_basic(vector, limit).await,
            Some(st) => self.qdrant_search_filtered(vector, st, limit).await,
        }
    }

    /// Plain vector search — delegates to QdrantClient::search.
    async fn qdrant_search_basic(&self, vector: Vec<f32>, limit: usize) -> Vec<SearchHit> {
        match self.qdrant.search(COLLECTION, vector, limit).await {
            Ok(raw) => raw
                .into_iter()
                .filter_map(|(id, score)| {
                    // item_id stored in payload; raw tuple first field is payload["id"]
                    Some(SearchHit {
                        item_id:     id.clone(),
                        score,
                        source_type: String::new(), // not returned by basic search
                        plugin_id:   String::new(),
                    })
                })
                .collect(),
            Err(e) => {
                tracing::debug!("qdrant search: {e}");
                vec![]
            }
        }
    }

    /// Filtered vector search — POST directly with Qdrant filter body so we
    /// can request the full payload and apply the `source_type` must-match.
    async fn qdrant_search_filtered(
        &self,
        vector:      Vec<f32>,
        source_type: &str,
        limit:       usize,
    ) -> Vec<SearchHit> {
        // Access the underlying http client and base_url from QdrantClient.
        // QdrantClient exposes these indirectly; we POST via the same pattern
        // as QdrantClient::search but with an added filter block.
        let url = format!(
            "{}/collections/{}/points/search",
            self.qdrant_base_url(),
            COLLECTION
        );

        let body = json!({
            "vector": vector,
            "limit": limit,
            "with_payload": true,
            "filter": {
                "must": [{
                    "key": "source_type",
                    "match": { "value": source_type }
                }]
            }
        });

        let resp: serde_json::Value = match self
            .qdrant_http()
            .post(&url)
            .json(&body)
            .send()
            .await
        {
            Ok(r) => match r.json().await {
                Ok(v) => v,
                Err(e) => {
                    tracing::debug!("qdrant filtered search parse: {e}");
                    return vec![];
                }
            },
            Err(e) => {
                tracing::debug!("qdrant filtered search: {e}");
                return vec![];
            }
        };

        resp["result"]
            .as_array()
            .cloned()
            .unwrap_or_default()
            .into_iter()
            .filter_map(|h| {
                let score = h["score"].as_f64()? as f32;
                let payload = &h["payload"];
                let item_id = payload["item_id"].as_str()?.to_string();
                let source_type = payload["source_type"]
                    .as_str()
                    .unwrap_or("")
                    .to_string();
                let plugin_id = payload["plugin_id"]
                    .as_str()
                    .unwrap_or("")
                    .to_string();
                Some(SearchHit { item_id, score, source_type, plugin_id })
            })
            .collect()
    }

    // ── Helpers to reach QdrantClient internals ───────────
    // QdrantClient does not expose http/base_url publicly, so we construct a
    // fresh client. Both share the same Qdrant endpoint (env var respected).

    fn qdrant_base_url(&self) -> String {
        std::env::var("CORTEX_QDRANT_URL")
            .unwrap_or_else(|_| "http://localhost:6333".to_string())
    }

    fn qdrant_http(&self) -> reqwest::Client {
        // Reuse a lightweight new client — this path is only used for filtered
        // searches and is not on the hot path.
        reqwest::Client::new()
    }
}
