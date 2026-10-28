# Cortex / AIO — Agent Notes

## Project
AllInOne (AIO) — codename Cortex. Cross-platform ⌘K launcher + episodic memory engine.
Tauri 2.0 shell, Rust daemon, React UI.

## Key paths
- `src/` — React frontend (TypeScript strict)
- `src-tauri/src/` — Rust backend
- `src-tauri/src/plugins/` — one file per source plugin
- `src-tauri/src/daemon/` — memory capture + session graph
- `src-tauri/src/ranker.rs` — hybrid BM25 + temporal + behavioral scorer
- `src-tauri/src/ipc.rs` — all Tauri commands exposed to frontend
- `~/.cortex/` — runtime data dir (indices, sessions, captures)

## Run
```
npm install && npm run tauri dev
```

## Rust crates — key ones
- `tantivy` — full-text index (BM25)
- `rusqlite` — session graph + clipboard DB
- `notify` — filesystem watcher
- `fuzzy-matcher` — skim algorithm for filename fuzzy search
- `git2` — git history indexing
- `arboard` — clipboard access (cross-platform)
- `tauri-plugin-global-shortcut` — ⌘K hotkey

## Plugin contract
Every plugin implements `src-tauri/src/plugin.rs::Plugin` trait.
3 methods: `sync()`, `search(query)`, `execute(result)`.
All results go through `Ranker::rank()` before returning to frontend.

## Phase 1 target (weeks 1-6)
Ship: files + shell + browser + git + clipboard plugins.
UI: command palette working with NL query + unified ranker.
No memory daemon yet.

## Phase 2 target (weeks 7-14)
Memory daemon on, OCR pipeline, session graph wired to search results.
Temporal queries work: "last Tuesday", "before the incident".

## Privacy non-negotiables
- BLOCKED_APPS in `daemon/memory.rs` — never skip this check
- Password field detection before OCR
- ⌘⇧P pause hotkey must always work
- ~/.cortex encrypted at rest

## Desktop layer (`src-tauri/src/desktop/`)
- `glass.rs` — native Liquid Glass (NSGlassEffectView, macOS 26+), vibrancy fallback
- `widgets.rs` — one window per widget, `~/.cortex/widgets.json`; frontend `src/widgets/`
- `dock.rs` — Cortex Dock (`~/.cortex/dock.json`, frontend `src/dock/`) + macOS Dock editor
- `providers.rs` — widget data (sysinfo, pmset, Open-Meteo, git2, Docker, …)
- Windows are routed by hash: `#/widget/<id>`, `#/dock`, otherwise the palette.

## IPC pattern
Frontend → `invoke("search", { query, sourceFilter, limit })`
Backend → `ipc.rs::search()` → fan-out to plugins → rank → return `SearchResponse`

## Aesthetic
Liquid Glass: neutral white-on-glass, one subtle accent — phosphor amber (#e8a430),
used only for state that needs attention. Near-black base (#06060a).
Fonts: Syne (display), JetBrains Mono (search/code), DM Sans (body).
All design tokens in `src/styles/globals.css`.
