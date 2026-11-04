//! cortexd — the Cortex engine as a library: search plugins, ranking, the session
//! graph and the memory daemon, served to the native app over a local socket.

pub mod auth;
pub mod daemon;
pub mod embed;
pub mod embeddings;
pub mod executor;
pub mod intent;
pub mod ollama;
pub mod plugin;
pub mod plugins;
pub mod ranker;
pub mod temporal;
pub mod ws_server;

pub mod config_ipc;
pub mod exec;
pub mod exec_ipc;
pub mod engine;
pub mod rpc;

pub fn dir_size_bytes(path: &std::path::Path) -> u64 {
    walkdir::WalkDir::new(path)
        .into_iter()
        .filter_map(|e| e.ok())
        .filter(|e| e.file_type().is_file())
        .filter_map(|e| e.metadata().ok())
        .map(|m| m.len())
        .sum()
}
