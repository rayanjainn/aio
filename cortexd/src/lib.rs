//! cortexd — the Cortex engine as a library. The engine modules are the same
//! source files the old desktop app used (included by path, so there is one copy);
//! the few places they reached into the Tauri layer are answered by the small
//! shims below.

#[path = "../../src-tauri/src/auth.rs"]       pub mod auth;
#[path = "../../src-tauri/src/daemon/mod.rs"] pub mod daemon;
#[path = "../../src-tauri/src/embed.rs"]      pub mod embed;
#[path = "../../src-tauri/src/embeddings.rs"] pub mod embeddings;
#[path = "../../src-tauri/src/executor.rs"]   pub mod executor;
#[path = "../../src-tauri/src/intent.rs"]     pub mod intent;
#[path = "../../src-tauri/src/ollama.rs"]     pub mod ollama;
#[path = "../../src-tauri/src/plugin.rs"]     pub mod plugin;
#[path = "../../src-tauri/src/plugins/mod.rs"] pub mod plugins;
#[path = "../../src-tauri/src/ranker.rs"]     pub mod ranker;
#[path = "../../src-tauri/src/temporal.rs"]   pub mod temporal;
#[path = "../../src-tauri/src/ws_server.rs"]  pub mod ws_server;

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
