# Cortex

**Created by [Rayan Jain](https://github.com/rayanjainn).** © 2025–2026 Rayan Jain. All rights reserved — see [LICENSE](LICENSE).

A native macOS launcher, Dock, notch and desktop-widget suite — one app, real Liquid Glass.
Swift / SwiftUI / AppKit for everything you see, a Rust engine (`cortexd`) for search and memory.

| | |
|---|---|
| **Act on this** | `⌃⌥A` on any selection: summarise, fix grammar, translate, reply, search, pin, note — with Ollama, Ollama Cloud or any OpenAI-compatible server |
| **⌘K palette** | Apps, files, shell history, git, browser tabs, clipboard history, snippets, quicklinks, calculator, unit & currency conversion, emoji, dictionary, system commands, window snapping, search the front app's menus, quit processes, colour picker, AI chat (Ollama) |
| **Island** | A Dynamic-Island for the notch (or a virtual one on Macs without a notch): Now Playing from any app with synced lyrics, volume & brightness HUD, next meeting with Join, focus timer, file shelf with AirDrop, Bluetooth/AirPods, downloads, mic/camera indicators, camera mirror, Shortcuts |
| **Dock** | Magnifying glass Dock on any edge, live window previews, folder stacks, **live widget tiles (music, clock, battery, weather, timer, system, next meeting)**, custom icons, presets, drag to reorder, badges, launch bounce, auto-hide, hides under full-screen apps, optional replacement of the macOS Dock |
| **Window switcher** | `⌥⇥` — every window of every app and Space, with previews |
| **Widgets** | Clock, calendar, system, now playing, notes, to-dos, weather, Claude Code & Codex usage |
| **Windows** | Halves, thirds, corners, maximize, centre, next display, saved window layouts — all rebindable |

## Install

Download the `.dmg` from the [latest release](https://github.com/rayanjainn/aio/releases/latest), drag Cortex to Applications.
Cortex isn't notarized yet: if macOS says it is damaged run `xattr -cr /Applications/Cortex.app`.
Requires macOS 14+; the glass is the real Liquid Glass material on macOS 26+.

## Layout

```
native/    Swift package — the app (UI, Island, Dock, widgets, palette, settings)
cortexd/   Rust engine — plugins, ranking, memory; JSON-RPC over ~/.cortex/cortexd.sock
chrome-extension/   Browser tab feed for the engine
marketing/ Website (GitHub Pages)
```

## Build

```bash
native/scripts/bundle.sh 0.3.0     # universal Cortex.app + Cortex.dmg in native/build/
cd native && swift test            # unit tests
cd cortexd && cargo test           # engine tests
```

CI (`.github/workflows/native.yml`) compiles and tests on every push to `native/**`; `release.yml` publishes a release.

## Privacy

Everything stays on your Mac. Screen memory is **off** until you turn it on, never captures password fields or blocked apps, and `⌘⇧P` pauses it. Logs: `~/.cortex/logs/`. Data: `~/.cortex/`.

## License

Cortex is **source-available, not open source**. © 2025–2026 Rayan Jain, all rights reserved.
You can use the official releases for free and read the code, but you may not redistribute it, publish a product
based on it, or remove the author's name. Full terms: [LICENSE](LICENSE). Third-party components: [NOTICE](NOTICE).
