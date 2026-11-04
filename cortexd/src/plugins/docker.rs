/// Docker plugin — live container/image status via bollard + compose file search.
///
/// SQLite: ~/.cortex/docker/docker.db
/// Live cache: refreshed every 30 seconds from Docker daemon
/// Compose files: walked from home/code/projects dirs

use anyhow::{Context, Result};
use async_trait::async_trait;
use bollard::{
    container::{InspectContainerOptions, ListContainersOptions},
    image::ListImagesOptions,
    Docker,
};
use chrono::Utc;
use fuzzy_matcher::{skim::SkimMatcherV2, FuzzyMatcher};
use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};
use std::{
    path::PathBuf,
    sync::Arc,
};
use tokio::sync::RwLock;

use crate::plugin::{Plugin, ResultAction, SearchQuery, SearchResult, SourceType};

/* ─── Data types ────────────────────────────────────────── */

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ContainerEntry {
    pub container_id: String,
    pub name:         String,
    pub image:        String,
    pub status:       String,
    pub state:        String,
    pub command:      String,
    pub ports:        String,  // JSON
    pub created_at:   i64,
    pub run_cmd:      String,  // reconstructed `docker run ...`
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ImageEntry {
    pub image_id:   String,
    pub repo_tags:  String,
    pub size_mb:    f64,
    pub created_at: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ComposeFile {
    pub path:    String,
    pub services: String, // comma-separated service names
}

/* ─── Cache ─────────────────────────────────────────────── */

#[derive(Default)]
pub(crate) struct DockerCache {
    containers:    Vec<ContainerEntry>,
    images:        Vec<ImageEntry>,
    compose_files: Vec<ComposeFile>,
}

/* ─── Plugin ────────────────────────────────────────────── */

pub struct DockerPlugin {
    db_path: PathBuf,
    cache:   Arc<RwLock<DockerCache>>,
    matcher: SkimMatcherV2,
    data_dir: PathBuf,
}

impl DockerPlugin {
    pub fn new(data_dir: PathBuf) -> Result<Self> {
        std::fs::create_dir_all(&data_dir)?;
        let db_path = data_dir.join("docker.db");
        Self::init_db(&db_path)?;
        Ok(Self {
            data_dir: data_dir.clone(),
            db_path,
            cache:   Arc::new(RwLock::new(DockerCache::default())),
            matcher: SkimMatcherV2::default(),
        })
    }

    fn init_db(path: &PathBuf) -> Result<()> {
        let conn = Connection::open(path)?;
        conn.execute_batch("
            CREATE TABLE IF NOT EXISTS containers (
                container_id TEXT PRIMARY KEY,
                name         TEXT NOT NULL,
                image        TEXT NOT NULL,
                status       TEXT NOT NULL DEFAULT '',
                state        TEXT NOT NULL DEFAULT '',
                command      TEXT NOT NULL DEFAULT '',
                ports_json   TEXT NOT NULL DEFAULT '{}',
                created_at   INTEGER NOT NULL DEFAULT 0,
                run_cmd      TEXT NOT NULL DEFAULT '',
                updated_at   INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS images (
                image_id    TEXT PRIMARY KEY,
                repo_tags   TEXT NOT NULL DEFAULT '',
                size_mb     REAL NOT NULL DEFAULT 0.0,
                created_at  INTEGER NOT NULL DEFAULT 0,
                updated_at  INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS compose_files (
                path     TEXT PRIMARY KEY,
                services TEXT NOT NULL DEFAULT '',
                raw_yaml TEXT NOT NULL DEFAULT '',
                indexed_at INTEGER NOT NULL DEFAULT 0
            );
        ")?;
        Ok(())
    }

    fn db(&self) -> Result<Connection> {
        Connection::open(&self.db_path).context("docker db")
    }

    /* ── Container refresh ───────────────────────────────── */

    async fn refresh_containers(&self, docker: &Docker) -> Result<usize> {
        let options = ListContainersOptions::<String> {
            all: true,
            ..Default::default()
        };
        let list = docker.list_containers(Some(options)).await?;
        let now = Utc::now().timestamp();
        let mut entries = Vec::new();

        for c in &list {
            let container_id = c.id.as_deref().unwrap_or("").to_string();
            if container_id.is_empty() { continue; }

            let name = c.names.as_ref()
                .and_then(|n| n.first())
                .map(|n| n.trim_start_matches('/').to_string())
                .unwrap_or_default();
            let image      = c.image.clone().unwrap_or_default();
            let status     = c.status.clone().unwrap_or_default();
            let state      = c.state.clone().unwrap_or_default();
            let command    = c.command.clone().unwrap_or_default();
            let ports_json = serde_json::to_string(&c.ports).unwrap_or_else(|_| "{}".into());
            let created_at = c.created.unwrap_or(0);

            // Inspect for full run command
            let run_cmd = match docker.inspect_container(
                &container_id,
                None::<InspectContainerOptions>,
            ).await {
                Ok(info) => reconstruct_run_cmd(&info),
                Err(_)   => String::new(),
            };

            let id_short = container_id.chars().take(12).collect::<String>();
            entries.push(ContainerEntry {
                container_id: id_short,
                name, image, status, state, command,
                ports: ports_json,
                created_at,
                run_cmd,
            });
        }

        // Persist to DB in blocking thread (rusqlite is not Send)
        let db_path  = self.db_path.clone();
        let rows     = entries.clone();
        tokio::task::spawn_blocking(move || {
            let Ok(conn) = Connection::open(&db_path) else { return };
            for e in &rows {
                let _ = conn.execute(
                    "INSERT OR REPLACE INTO containers \
                     (container_id, name, image, status, state, command, ports_json, created_at, run_cmd, updated_at) \
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
                    params![e.container_id, e.name, e.image, e.status, e.state,
                            e.command, e.ports, e.created_at, e.run_cmd, now],
                );
            }
        }).await.ok();

        let count = entries.len();
        self.cache.write().await.containers = entries;
        Ok(count)
    }

    /* ── Image refresh ───────────────────────────────────── */

    async fn refresh_images(&self, docker: &Docker) -> Result<usize> {
        let list = docker.list_images(None::<ListImagesOptions<String>>).await?;
        let now  = Utc::now().timestamp();
        let mut entries = Vec::new();

        for img in &list {
            let image_id = img.id.trim_start_matches("sha256:")
                .chars().take(12).collect::<String>();
            if image_id.is_empty() { continue; }

            let repo_tags  = img.repo_tags.join(", ");
            let size_mb    = img.size as f64 / 1_048_576.0;
            let created_at = img.created;

            entries.push(ImageEntry { image_id, repo_tags, size_mb, created_at });
        }

        // Persist
        let db_path = self.db_path.clone();
        let rows    = entries.clone();
        tokio::task::spawn_blocking(move || {
            let Ok(conn) = Connection::open(&db_path) else { return };
            for e in &rows {
                let _ = conn.execute(
                    "INSERT OR REPLACE INTO images \
                     (image_id, repo_tags, size_mb, created_at, updated_at) \
                     VALUES (?1, ?2, ?3, ?4, ?5)",
                    params![e.image_id, e.repo_tags, e.size_mb, e.created_at, now],
                );
            }
        }).await.ok();

        let count = entries.len();
        self.cache.write().await.images = entries;
        Ok(count)
    }

    /* ── Compose files ───────────────────────────────────── */

    async fn sync_compose_files(&self) -> Result<usize> {
        let home  = dirs::home_dir().unwrap_or_default();
        let roots = vec![
            home.join("code"),
            home.join("projects"),
            home.join("Projects"),
            home.join("dev"),
            home.join("workspace"),
        ].into_iter().filter(|p| p.exists()).collect::<Vec<_>>();

        let db_path = self.db_path.clone();
        let count = tokio::task::spawn_blocking(move || -> usize {
            let Ok(conn) = Connection::open(&db_path) else { return 0 };
            let now = Utc::now().timestamp();
            let mut found = 0usize;
            let mut compose_entries = Vec::new();

            for root in &roots {
                for entry in walkdir::WalkDir::new(root)
                    .max_depth(5)
                    .into_iter()
                    .filter_map(|e| e.ok())
                    .filter(|e| {
                        let name = e.file_name().to_string_lossy();
                        (name == "docker-compose.yml"
                            || name == "docker-compose.yaml"
                            || name == "compose.yml"
                            || name == "compose.yaml")
                        && !e.path().to_string_lossy().contains("node_modules")
                        && !e.path().to_string_lossy().contains("/target/")
                    })
                {
                    let path = entry.path().to_string_lossy().to_string();
                    let raw  = std::fs::read_to_string(entry.path()).unwrap_or_default();
                    let services = extract_compose_services(&raw);

                    let _ = conn.execute(
                        "INSERT OR REPLACE INTO compose_files (path, services, raw_yaml, indexed_at) \
                         VALUES (?1, ?2, ?3, ?4)",
                        params![path, services, raw, now],
                    );
                    compose_entries.push(ComposeFile {
                        path: path.clone(),
                        services: services.clone(),
                    });
                    found += 1;
                }
            }
            found
        }).await.unwrap_or(0);

        // Reload compose entries into cache (blocking read)
        let db_path = self.db_path.clone();
        let compose: Vec<ComposeFile> = tokio::task::spawn_blocking(move || {
            let Ok(conn)   = Connection::open(&db_path) else { return vec![] };
            let Ok(mut st) = conn.prepare("SELECT path, services FROM compose_files") else { return vec![] };
            st.query_map([], |r| Ok(ComposeFile { path: r.get(0)?, services: r.get(1)? }))
              .map(|rows| rows.filter_map(|r| r.ok()).collect())
              .unwrap_or_default()
        }).await.unwrap_or_default();
        self.cache.write().await.compose_files = compose;

        Ok(count)
    }

    #[allow(dead_code)]
    pub(crate) fn live_cache_handle(&self) -> Arc<RwLock<DockerCache>> {
        self.cache.clone()
    }
}

/* ─── Run command reconstruction ───────────────────────── */

fn reconstruct_run_cmd(info: &bollard::models::ContainerInspectResponse) -> String {
    let name = info.name.as_deref().unwrap_or("").trim_start_matches('/');
    let image = info.config.as_ref()
        .and_then(|c| c.image.as_deref())
        .unwrap_or("");

    let mut parts = vec!["docker run".to_string()];

    if !name.is_empty() {
        parts.push(format!("--name {name}"));
    }

    // Port bindings
    if let Some(host_config) = &info.host_config {
        if let Some(port_bindings) = &host_config.port_bindings {
            for (container_port, host_bindings) in port_bindings {
                if let Some(bindings) = host_bindings {
                    for binding in bindings {
                        let host_port = binding.host_port.as_deref().unwrap_or("");
                        parts.push(format!("-p {host_port}:{container_port}"));
                    }
                }
            }
        }

        // Restart policy
        if let Some(restart) = &host_config.restart_policy {
            if let Some(name) = &restart.name {
                let name_str = format!("{name:?}").to_lowercase().trim_matches('"').to_string();
                if name_str != "no" && !name_str.is_empty() {
                    parts.push(format!("--restart {name_str}"));
                }
            }
        }
    }

    // Environment variables (public ones only)
    if let Some(config) = &info.config {
        if let Some(env) = &config.env {
            for var in env.iter().take(5) {
                // Skip secrets-looking vars
                let upper = var.to_uppercase();
                if upper.contains("SECRET") || upper.contains("PASSWORD") || upper.contains("TOKEN") {
                    continue;
                }
                parts.push(format!("-e {var}"));
            }
        }
    }

    parts.push(image.to_string());

    // Command override
    if let Some(config) = &info.config {
        if let Some(cmd) = &config.cmd {
            let cmd_str = cmd.join(" ");
            if !cmd_str.is_empty() {
                parts.push(cmd_str);
            }
        }
    }

    parts.join(" ")
}

/* ─── Compose parser (quick YAML service name extract) ─── */

fn extract_compose_services(yaml: &str) -> String {
    let mut in_services = false;
    let mut services = Vec::new();
    for line in yaml.lines() {
        if line.trim() == "services:" {
            in_services = true;
            continue;
        }
        if in_services {
            if line.starts_with("  ") && !line.starts_with("    ") {
                let svc = line.trim().trim_end_matches(':');
                if !svc.is_empty() && !svc.starts_with('#') {
                    services.push(svc.to_string());
                }
            } else if !line.starts_with(' ') && !line.is_empty() {
                break; // left services block
            }
        }
    }
    services.join(", ")
}

/* ─── Plugin impl ───────────────────────────────────────── */

#[async_trait]
impl Plugin for DockerPlugin {
    fn id(&self)   -> &str { "docker" }
    fn name(&self) -> &str { "Docker" }
    fn icon(&self) -> &str { "🐳" }

    async fn count(&self) -> u64 {
        let cache = self.cache.read().await;
        (cache.containers.len() + cache.images.len()) as u64
    }

    async fn sync(&self) -> Result<usize> {
        let docker = match Docker::connect_with_unix_defaults() {
            Ok(d) => d,
            Err(e) => {
                tracing::debug!("Docker not available: {e}");
                return Ok(0);
            }
        };

        // Check daemon is actually running
        if docker.ping().await.is_err() {
            tracing::debug!("Docker daemon not responding");
            return Ok(0);
        }

        let containers = self.refresh_containers(&docker).await.unwrap_or_else(|e| {
            tracing::warn!("docker containers: {e}"); 0
        });
        let images = self.refresh_images(&docker).await.unwrap_or_else(|e| {
            tracing::warn!("docker images: {e}"); 0
        });
        let compose = self.sync_compose_files().await.unwrap_or(0);

        tracing::info!("Docker: {containers} containers, {images} images, {compose} compose files");
        Ok(containers + images + compose)
    }

    async fn search(&self, query: &SearchQuery) -> Result<Vec<SearchResult>> {
        let q = &query.raw;
        let cache = self.cache.read().await;
        let mut results: Vec<SearchResult> = Vec::new();

        // Containers
        for c in &cache.containers {
            let hay = format!("{} {} {} {}", c.name, c.image, c.run_cmd, c.status);
            if let Some(score) = self.matcher.fuzzy_match(&hay, q) {
                let running = c.state == "running";
                let status_icon = if running { "🟢" } else { "⚫" };
                let mut r = SearchResult::new("docker", format!("{status_icon} {}", c.name));
                r.id          = format!("docker:container:{}", c.container_id);
                r.source_type = SourceType::Unknown;
                r.subtitle    = Some(format!("{} · {}", c.image, c.status));
                r.score       = (score as f32 / 300.0).min(0.99);
                r.action      = ResultAction::Run;
                r.metadata.insert("container_id".into(), c.container_id.as_str().into());
                r.metadata.insert("run_cmd".into(),      c.run_cmd.as_str().into());
                r.metadata.insert("state".into(),        c.state.as_str().into());
                results.push(r);
            }
        }

        // Images
        for img in &cache.images {
            if let Some(score) = self.matcher.fuzzy_match(&img.repo_tags, q) {
                let mut r = SearchResult::new("docker", format!("📦 {}", img.repo_tags));
                r.id          = format!("docker:image:{}", img.image_id);
                r.source_type = SourceType::Unknown;
                r.subtitle    = Some(format!("Image · {:.1} MB", img.size_mb));
                r.score       = (score as f32 / 300.0).min(0.95);
                r.action      = ResultAction::Copy;
                r.metadata.insert("image_id".into(),  img.image_id.as_str().into());
                r.metadata.insert("repo_tags".into(), img.repo_tags.as_str().into());
                results.push(r);
            }
        }

        // Compose files
        for f in &cache.compose_files {
            let filename = PathBuf::from(&f.path)
                .file_name().map(|n| n.to_string_lossy().to_string())
                .unwrap_or_default();
            let hay = format!("{} {} {}", filename, f.path, f.services);
            if let Some(score) = self.matcher.fuzzy_match(&hay, q) {
                let mut r = SearchResult::new("docker", format!("🗂 {filename}"));
                r.id          = format!("docker:compose:{}", f.path);
                r.source_type = SourceType::File;
                r.subtitle    = Some(format!("compose · {}", f.services));
                r.path        = Some(f.path.clone());
                r.score       = (score as f32 / 300.0).min(0.95);
                r.action      = ResultAction::Open;
                results.push(r);
            }
        }

        results.sort_by(|a, b| b.score.partial_cmp(&a.score).unwrap());
        results.truncate(20);
        Ok(results)
    }

    async fn execute(&self, result: &SearchResult) -> Result<()> {
        if let Some(path) = &result.path {
            opener::open(path)?;
        } else if let Some(tags) = result.metadata.get("repo_tags").and_then(|v| v.as_str()) {
            // Copy image name to clipboard
            let mut cb = arboard::Clipboard::new()?;
            cb.set_text(tags.split(',').next().unwrap_or(tags).trim().to_string())?;
        } else if let Some(run_cmd) = result.metadata.get("run_cmd").and_then(|v| v.as_str()) {
            // Copy run command to clipboard
            let mut cb = arboard::Clipboard::new()?;
            cb.set_text(run_cmd.to_string())?;
        }
        Ok(())
    }
}

/// Spawn background task that refreshes container status every 30 seconds.
pub async fn watch_docker(plugin: std::sync::Arc<DockerPlugin>) {
    loop {
        tokio::time::sleep(std::time::Duration::from_secs(30)).await;
        let docker = match Docker::connect_with_unix_defaults() {
            Ok(d) => d,
            Err(_) => continue,
        };
        if docker.ping().await.is_err() { continue; }
        let _ = plugin.refresh_containers(&docker).await;
        let _ = plugin.refresh_images(&docker).await;
    }
}
