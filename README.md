# Cortex

A native macOS launcher, Dock, notch and desktop-widget suite — one app, real Liquid Glass.
Swift / SwiftUI / AppKit for everything you see, a Rust engine (`cortexd`) for search and memory.

| | |
|---|---|
| **⌘K palette** | Apps, files, shell history, git, browser tabs, clipboard history, snippets, quicklinks, calculator, unit & currency conversion, emoji, dictionary, system commands, window snapping, search the front app's menus, quit processes, colour picker, AI chat (Ollama) |
| **Island** | A Dynamic-Island for the notch (or a virtual one on Macs without a notch): Now Playing from any app with synced lyrics, volume & brightness HUD, next meeting with Join, focus timer, file shelf with AirDrop, Bluetooth/AirPods, downloads, mic/camera indicators, camera mirror, Shortcuts |
| **Dock** | Magnifying glass Dock on any edge, live window previews, folder stacks, drag to reorder, badges, launch bounce, auto-hide, optional replacement of the macOS Dock |
| **Window switcher** | `⌥⇥` — every window of every app and Space, with previews |
| **Widgets** | Clock, calendar, system, now playing, notes, to-dos, weather, Claude Code & Codex usage |
| **Windows** | Halves, thirds, corners, maximize, centre, next display — all rebindable |

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
