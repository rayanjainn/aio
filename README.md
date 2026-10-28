# Cortex — Neural Command Palette + Episodic Memory

> What were you doing right before the prod incident on Tuesday?

Cortex reconstructs it — files open, tabs visited, commands run, clipboard contents. No tool on earth can do that.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  ⌘K  Query surface — Tauri popup, <16ms fuzzy results   │
├─────────────────────────────────────────────────────────┤
│  Intent parser — Phi-3 Mini (async, re-ranks on done)   │
├─────────────────────────────────────────────────────────┤
│  Plugin registry — 28 sources, identical Rust trait     │
│  Files · Browser · Shell · Git · Clipboard · Docker…    │
├─────────────────────────────────────────────────────────┤
│  Ranker — BM25 + temporal decay + behavioral boost      │
├─────────────────────────────────────────────────────────┤
│  Session graph — SQLite episodic store, all events      │
├─────────────────────────────────────────────────────────┤
│  Memory daemon — adaptive screen capture + OCR + embed  │
└─────────────────────────────────────────────────────────┘
```

## Stack

| Layer | Tech |
|-------|------|
| Shell | Tauri 2.0 (Rust + webview) |
| UI | React 18 + TypeScript + Framer Motion |
| IPC | Unix socket / Tauri invoke |
| Full-text | Tantivy (Rust-native Lucene) |
| Vector | Qdrant embedded |
| Sessions | SQLite via rusqlite |
| OCR | Apple Vision (macOS) / Tesseract (Linux) |
| Embeddings | nomic-embed-text via Ollama |
| Intent | Phi-3 Mini 4B via llama.cpp |
| Screen | CGDisplay (macOS) / x11grab (Linux) |

## Launch sequence

### Prerequisites

```bash
# Rust toolchain
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

# Node
brew install node   # or nvm

# Tauri CLI
cargo install tauri-cli --version "^2.0"

# macOS: Xcode CLI tools (for CGDisplay + Vision)
xcode-select --install
```

### Run dev

```bash
cd AIO
npm install
npm run tauri dev
```

### Build

```bash
npm run tauri build
# Binary at src-tauri/target/release/aio-cortex
```

## Privacy

- **100% local** — zero outbound connections (verify with `lsof -i` or Little Snitch)
- **App blocklist** — 1Password, Signal, banking apps never captured
- **Password fields** — OS accessibility API skips secure inputs
- **Pause hotkey** — `⌘⇧P` halts all capture instantly
- **Retention** — 30-day screen captures, 1-year text index (configurable)
- **Encrypted at rest** — `~/.cortex/` via macOS Keychain / Linux Secret Service
- **Full export/delete** — one command, no residue

## Phase roadmap

| Phase | Weeks | Milestone |
|-------|-------|-----------|
| 1 — Command-K core | 1–6 | Tauri shell, file/shell/browser/git plugins, NL query, ranker — **HN launch #1** |
| 2 — Memory layer | 7–14 | Screen capture daemon, OCR, session graph, episodic queries — **HN launch #2** |
| 3 — AI layer | 15+ | Phi-3 intent parsing, Ollama embeddings, execution mode |

## Plugin API

Implement `Plugin` trait to add any source:

```rust
#[async_trait]
pub trait Plugin: Send + Sync {
    fn id(&self)   -> &str;
    fn name(&self) -> &str;
    fn icon(&self) -> &str;
    async fn sync(&self) -> Result<usize>;
    async fn search(&self, query: &SearchQuery) -> Result<Vec<SearchResult>>;
    async fn execute(&self, result: &SearchResult) -> Result<()>;
}
```

## Killer queries

```
what was I doing right before the prod incident on Tuesday?
that dark-themed Rust async website I had open at 2am last month
docker compose file where redis was exposed on port 6379
restart redis with the same config as last Thursday
open all the tabs I had when I was working on the auth bug
```
