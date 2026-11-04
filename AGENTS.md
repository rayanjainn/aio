# Cortex — Agent Notes

## Project
Cortex — native macOS launcher + Dock + notch Island + widgets. Swift/SwiftUI/AppKit app, Rust engine.
No Tauri, no web UI.

## Key paths
- `native/Sources/Cortex/` — the app. One file per area:
  `AppDelegate` (wiring, menu bar), `Palette*` (⌘K), `Island*` (notch), `Dock*` (Dock + previews),
  `Widget*`, `Settings*`, `Onboarding`, `HotKeys` (Carbon hotkeys + shortcut table), `WindowManager` (snapping),
  `WindowService` (window listing/raising via Accessibility + ScreenCaptureKit), `WindowSwitcher`,
  `NowPlaying` (system Now Playing through the vendored mediaremote-adapter), `HUDService`, `CalendarService`,
  `FocusTimer`, `ShelfStore`, `ActivityServices` (Bluetooth, downloads, mic/camera, lyrics, Shortcuts),
  `CodingUsage`, `WeatherService`, `EngineClient` (talks to cortexd), `Prefs`, `Updates`, `Glass`, `Log`, `Diagnostics`.
- `native/Resources/mediaremote/` — mediaremote-adapter (BSD-3): perl + prebuilt framework, loaded by `/usr/bin/perl`.
- `native/Tests/CortexTests/` — unit tests for pure logic (`swift test`).
- `cortexd/` — Rust engine (plugins, ranker, daemon/memory, ollama). `cortexd/src/rpc.rs` is the whole API.
- `~/.cortex/` — runtime data (indices, sessions, `config.json`, `native/*.json`, `logs/`).

## Build & test
```
native/scripts/bundle.sh <version>   # universal .app + .dmg (needs macOS + Rust targets)
cd native && swift build && swift test
cd cortexd && cargo test
```
No Mac? CI is the compiler: push to `native/**`; the `swift-check` job prints only compile errors (~1 min).

## Rules that bit us
- Windows are non-activating `NSPanel`s (`canBecomeKey` false) so a click never spends itself on activation.
- Window frames hug the visible content and only grow instantly / shrink after the animation (Island, Dock) —
  a big transparent window blocks clicks on whatever is behind it.
- Music's AppleScript `current track` fails (-1728) on macOS 26 for streamed tracks; Now Playing comes from MediaRemote via the adapter.
- Not hardened-runtime: a hardened app without the Apple-Events entitlement is silently denied automation.
- Glass: use `cortexGlass(in:darken:)` (SwiftUI `glassEffect` on 26+, material before). Glass is for the control layer, not content; never stack glass on glass.
- Mac without a notch (safeAreaInsets.top == 0): the Island draws a virtual notch.

## Privacy non-negotiables
- Screen memory is paused at launch (`CORTEX_CAPTURE_PAUSED`); `BLOCKED_APPS` in `cortexd/src/daemon/memory.rs` is never skipped.
- Password-field detection before OCR. `⌘⇧P` pauses capture.

## Aesthetic
Monochrome Liquid Glass: white/grey on glass, no hues. System fonts (SF Pro).
