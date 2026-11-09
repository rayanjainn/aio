# Testing AIO on your Mac

Two parts: an **automatic self-test** (one command, produces a report) and a **manual checklist**
(things only a human can judge). Do both, send me the report file + screenshots of anything that
looks wrong, and I can fix from facts instead of guesses.

---

## Part 0 — Full end-to-end test (recommended, ~4 minutes)

```bash
curl -fsSLo ~/Desktop/e2e.sh https://raw.githubusercontent.com/rayanjainn/aio/main/native/scripts/e2e.sh
bash ~/Desktop/e2e.sh
```

It opens every surface (palette with ~30 queries, launcher, music player in each style, every Island page, Dock,
Settings, Screen Memory, widget gallery, Diagnostics), checks each window really appears, screenshots everything,
probes the engine, Now Playing, permissions and performance (with CPU profiles), collects logs and crash reports,
and zips it all to `~/Desktop/cortex-e2e-<time>.zip`. Your AIO settings are backed up and restored. Don't touch
the mouse or keyboard while it runs. Send me the zip.

## Part A — Automatic self-test (3 minutes)

```bash
bash /path/to/aio/native/scripts/selftest.sh              # auto-finds AIO.app
bash /path/to/aio/native/scripts/selftest.sh ~/Desktop/AIO.app   # or give the path
```

If you don't have the repo checked out, download the single file:

```bash
curl -fsSLo ~/Desktop/selftest.sh https://raw.githubusercontent.com/rayanjainn/aio/native/swift-rewrite/native/scripts/selftest.sh
bash ~/Desktop/selftest.sh
```

What it does (read-only, it changes nothing):

| Section | What it checks | Why it matters |
|---|---|---|
| 0 Context | macOS, chip, RAM, displays, low-power mode | Low Power Mode and Reduce Transparency both change how glass and animation behave |
| 1 App bundle | version, architectures, helper + adapter present, signing flags | A hardened signature silently blocks Apple Events; a missing helper kills search |
| 2 Processes | AIO / cortexd running, CPU, RAM, threads, open files | Finds a runaway process or a leak |
| 3 Idle CPU | 10 s of CPU with the mouse untouched | Anything above ~15 % idle means a timer or animation is spinning |
| 4 Lag profile | 8 s CPU **profile while you hover the Dock / Island / palette** | The single most useful file for fixing lag: shows which function is hot |
| 5 Log | ERROR/WARN lines, last lines, crash reports, system errors | Shows real failures |
| 6 Engine | pings `cortexd`, runs 4 searches and times them | Tells apart "engine down" from "palette UI broken" |
| 7 Now Playing | runs the MediaRemote adapter by hand | Separates "adapter broken" from "Island not showing it" |
| 8 Permissions | probes Screen Recording, Automation → Music, reads Accessibility from the log | Window previews/snapping/badges need Accessibility + Screen Recording |
| 9 Dock | state of the macOS Dock + the one-line restore command | |
| 10 Data | `prefs.json`, partial downloads in `~/Downloads` | Stale `.crdownload` files trigger the Island download activity |
| 11 Noise | top CPU processes, competing apps, Reduce Transparency/Motion | Bartender/Rectangle/NotchNook etc. fight over the same windows |

It writes `~/Desktop/cortex-selftest-<time>.txt` and `…sample.txt` (CPU profile). **Send both.**

During step 4 you'll get a 3-2-1 countdown — then slowly sweep the mouse across every Dock icon,
go to the top-centre so the Island opens and closes, and press ⌘K, type a few letters, Esc.

---

## Part B — Manual checklist

For each item write **OK / BROKEN / SLOW** and, if not OK, one line on what you saw. Screenshots
or a short screen recording (⇧⌘5) beat descriptions.

Before you start: AIO menu-bar icon → **Diagnostics** → copy the text and keep it for the report.

### B1. First run & permissions
1. Quit AIO, relaunch. Does the welcome walkthrough appear (first run only)?
2. Settings (menu-bar icon → Settings, or ⌘,) → **Privacy**: grant **Accessibility** and **Screen Recording**. After granting, quit and reopen AIO (macOS requires it).
3. Diagnostics should now say `Accessibility: granted` and `screenRecording=true`.

### B2. Dock
| # | Do | Expect |
|---|---|---|
| 1 | Look at the bar | Pinned apps, a divider, other running apps, Trash; running apps have a dot |
| 2 | Move the pointer slowly along the icons | Icons swell under the pointer in a smooth bell curve; a light tick on the trackpad each time you cross an icon |
| 3 | Rest on a running app ~0.3 s | Name label, then window thumbnails above the icon |
| 4 | Click a thumbnail | That exact window comes forward |
| 5 | Click an icon once | App opens/activates on the **first** click; a click haptic |
| 6 | Click a not-running app | Icon bounces while launching |
| 7 | Drag an icon sideways | It follows the pointer; releasing moves it |
| 8 | Drag an icon up off the bar | It is removed (not for Trash) |
| 9 | Right-click an icon | Show/Hide/Quit/Force Quit/Show in Finder/Keep in Dock |
| 10 | Right-click the **bar background** | Magnify, Hide automatically, Size ▸, Position ▸, Dock Settings… |
| 11 | Settings → Dock | Size slider, edge, auto-hide, darkness presets all change the Dock live |
| 12 | Drop a file on an app icon | The app opens the file |
| 13 | Folder icon (Downloads etc.) | Hover shows recent files; click opens |
| 14 | Auto-hide on, move to bottom edge | Slides in; leaves when the pointer goes away |
| 15 | Is the real macOS Dock gone? | Hidden while AIO runs, restored on quit (Diagnostics shows state) |

Report: icon size feels (too big / right / too small), any stutter (when exactly: entering, magnifying, leaving).

### B3. Island (top-centre)
| # | Do | Expect |
|---|---|---|
| 1 | Play a song in Music / Spotify / a browser | Compact pill shows artwork + equaliser |
| 2 | Hover the pill | Expands in ~0.15 s with a haptic; shows artwork, title, artist, progress, play/next/prev |
| 3 | Press play/pause/next in the Island | The real app responds |
| 4 | Scrub the progress bar | Seeks |
| 5 | Two-finger swipe left/right on the open Island | Switches pages: Player → Calendar → Shelf → Tools (haptic per page) |
| 6 | Change volume with the keyboard | Island shows a volume HUD, native HUD is replaced (needs Accessibility) |
| 7 | Brightness keys | Brightness HUD |
| 8 | Drag a file onto the Island | It lands on the Shelf page; drag it back out to Finder |
| 9 | Start a focus timer (Tools page) | Ring progress in the compact pill |
| 10 | Calendar page | Today's events; a **Join** button on events with a Zoom/Meet/Teams link |
| 11 | Plug in/out power; connect AirPods | Short activity pill with battery |
| 12 | Start a download in a browser | Download activity while the file grows, gone when finished (a **stale** `.crdownload` should *not* show) |
| 13 | Use the mic/camera in any app | Privacy dot |
| 14 | Lyrics (Settings → Island → Lyrics on) | Current line under the title |
| 15 | Move the pointer along the menu bar around the Island | Menu-bar clicks near it are **not** blocked |

### B4. ⌘K palette
Type each and note whether the result is right and how fast it appears:

| Type | Expect |
|---|---|
| `safari` | App result, Enter opens it |
| `12*(3+4)` | `84`, Enter copies |
| `10km to mi` | `6.21 mi` |
| `100 usd to inr` | Live conversion |
| `:heart` | Emoji grid |
| `clip` | Clipboard history; Enter pastes |
| `snip` | Snippets |
| `kill safari` | Process list |
| `m export` | Menu items of the frontmost app |
| `gh swiftui` / `g hello` | Quicklink/web search |
| `define serendipity` | Dictionary |
| `color` | Colour picker |
| `> ls` | Shell command |
| `mem <something you did earlier>` | Screen-memory search (needs memory enabled) |
| ⌘↩ / ⌥↩ / Tab on a result | Secondary actions |
| `Esc` | Closes instantly |

Also: does the palette open instantly on the hotkey (target < 100 ms)? Does typing feel laggy?

### B5. Widgets
1. Menu-bar icon → **Add Widget…** → add a Clock, Now Playing, Calendar, System, Weather, To-Do, Notes.
2. Drag to move; drag a corner to resize; right-click for options (float/desktop layer, remove).
3. Quit and relaunch: positions and contents persist?
4. Now Playing widget: artwork backdrop, controls work.

### B6. Window management
- `⌃⌥←/→/↑/↓`, `⌃⌥↩` etc. (see Settings → Shortcuts for the list): snaps the frontmost window.
- `⌥⇥` window switcher: appears, cycles, releases to switch.

### B7. Stability
- Leave AIO running 30 min while you work. Afterwards run the self-test again and compare section 2 (RSS memory should not have grown by hundreds of MB; idle CPU still low).
- Sleep/wake the Mac, plug/unplug a display: do Dock/Island reposition correctly?
- Quit from the menu bar: macOS Dock comes back?

---

## What to send

1. `cortex-selftest-*.txt` and `cortex-selftest-*.sample.txt` from Part A.
2. The Diagnostics text.
3. The filled-in checklist (just the lines that are not OK) + screenshots/recording.
4. Anything not covered: what you expected vs. what happened.

## If something goes wrong

- **Real Dock stays hidden after a crash**:
  `defaults write com.apple.dock autohide -bool false; defaults delete com.apple.dock autohide-delay; killall Dock`
- **Reset AIO settings** (keeps nothing): quit AIO, `mv ~/.cortex/native ~/Desktop/cortex-native-backup`, relaunch.
- **Permissions stuck** (switch is on in System Settings but AIO says off): Settings → Privacy & Permissions → **Reset and ask again**. It clears AIO's entries and relaunches straight into *Grant everything*. By hand: `tccutil reset All dev.cortex.native`.
- **Gatekeeper blocks launch**: `xattr -dr com.apple.quarantine /path/to/AIO.app`

## Signing and notarization (optional)

Releases are ad-hoc signed until these repository secrets exist (Settings → Secrets and variables → Actions):

| Secret | What |
|---|---|
| `MACOS_CERT_P12` | Your "Developer ID Application" certificate exported as .p12, base64-encoded (`base64 -i cert.p12 \| pbcopy`) |
| `MACOS_CERT_PASSWORD` | The .p12 password |
| `NOTARY_APPLE_ID` | Your Apple ID email |
| `NOTARY_TEAM_ID` | Your 10-character Team ID |
| `NOTARY_PASSWORD` | An app-specific password from appleid.apple.com |

**No paid Apple account?** Run `bash native/scripts/make-signing-cert.sh` once on your Mac. It makes a self-signed
certificate and stores it as `MACOS_CERT_P12` / `MACOS_CERT_PASSWORD` (with `gh`, or prints what to paste). Releases are
then signed with the same identity every time, so macOS keeps your permission grants across updates — no more removing
and re-adding AIO. (It does not remove the first-launch Gatekeeper warning; only a Developer ID does.)

With Developer ID secrets set, the Release workflow signs with your Developer ID (hardened runtime), notarizes and staples the .dmg — no more `xattr -cr`.
