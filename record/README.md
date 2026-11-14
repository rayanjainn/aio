# Recording AIO for real (scripts do the typing, clicking and recording)

These scripts drive the **real AIO app** on your Mac, record the screen, and edit the footage into Reels and a YouTube video
with hook cards, captions and an end card with the URL. They show **only AIO and Apple's own apps**, because they run in a
clean demo account.

> **Status: written without access to a Mac.** The editor (`edit/`) was tested on stand-in footage. The recorder and the
> scenes were walked through in dry-run mode (`DRY=1`) but have **not** run on a real Mac yet. Expect to fix a coordinate or
> two on the first take. `00-check.sh` and `tools/calibrate.sh` are there for exactly that. Nothing here changes your own
> account: every script refuses to run unless you are logged in as the demo user.

## One-time setup (about 30 minutes)

1. **Make a demo account.** System Settings → Users & Groups → Add User… → *Standard* → full name `AIO Demo`, account name
   **`aiodemo`**. (A fresh account has no clipboard history, no calendar events, no browser tabs and no files of yours, so
   nothing private can end up in a video. Apps in `/Applications` are shared, which is why step 4 hides them.)
2. **Install the tools**, in your own account or the demo one, with [Homebrew](https://brew.sh):
   ```bash
   brew install ffmpeg cliclick
   ```
3. **Switch to the demo account** (menu bar → user switcher, or log out and in). Open **AIO**, finish onboarding, and in
   AIO Settings turn on **Hide the macOS Dock while AIO runs** and **Open AIO at login**.
4. **Give your terminal three permissions** (System Settings → Privacy & Security): *Accessibility*, *Screen Recording*,
   and when macOS asks, *Automation* for Finder and System Events. Then **quit and reopen the terminal**.
5. In AIO's permissions screen press **Grant everything**, and switch on Accessibility and Screen Recording for AIO itself.
6. Get the scripts into the demo account: `git clone https://github.com/rayanjainn/aio.git ~/aio && cd ~/aio/record`
   (or AirDrop the `record` folder).
7. Check everything:
   ```bash
   ./00-check.sh
   ```
   Fix every ✗ line, run it again until it says "All good".

## Recording

```bash
./run-all.sh              # prepares the account, then records all 8 scenes (about 6 minutes). Hands off the Mac.
./run-all.sh 01           # re-record just one scene (01 ⌘K … 08 music)
```

What each scene does (all keyboard-driven except where noted):

| Scene | Shows | Mouse? |
|---|---|---|
| `01-cmdk` | ⌘K: maths, units, live currency, quick-add event, emoji, apps | no |
| `02-snap` | window snapping: halves, quarters, maximize, restore | no |
| `03-switch` | ⌥⇥ window switcher | no |
| `04-act` | Act on this (⌃⌥A on selected text) | no |
| `05-notch` | the Island: hover, Clipboard / Shelf / Tools pages, volume HUD | yes (page tabs) |
| `06-dock` | magnification, live widgets, right-click presets menu | yes (a sweep) |
| `07-launcher` | Launcher, search, dragging a widget to the other side | yes (the drag) |
| `08-music` | full-screen player, five styles | no |

If a mouse scene misses its target, run `./tools/calibrate.sh` once. It asks you to hover over the right spots and writes
`config.local.sh`. `./tools/where.sh` prints the mouse position live.

Raw footage lands in `out/raw/` (`.mkv` plus a `.marks` file with the caption timings). Watch each one; re-record any
that went wrong; the scenes don't depend on each other.

## Editing

```bash
./edit/make-reels.sh                       # every Reel that has a recording → out/reels/aio-<name>.mp4 (+ its cover image)
./edit/make-reels.sh cmdk dock             # only these
MUSIC=~/Music/track.mp3 ./edit/make-reels.sh   # with a music bed (optional; see below)
./edit/make-youtube.sh                     # one landscape video → out/youtube/aio-youtube.mp4, and it prints the chapter list
```

* Each Reel is: **2.6 s hook card → the screen in a device frame with captions → end card with `aio.raycode.tech`**.
* Captions appear when the scene reaches that step. If they look early or late on your Mac, add `OFFSET=0.4` (later) or
  `OFFSET=-0.4` (earlier) in front of the command.
* Music: leave it off and add a sound inside Instagram or YouTube's own library when you post (best for reach, and it's
  licensed for you), or pass `MUSIC=` with a file you have the rights to. Don't use a song you don't own.

## When something is off

| Problem | Fix |
|---|---|
| `ffmpeg cannot see a screen` | Terminal needs Screen Recording; quit and reopen it |
| Keys do nothing | Terminal needs Accessibility; check AIO is running and its shortcuts weren't changed in Settings |
| ⌘K shows nothing | AIO isn't running, or another app owns ⌘K |
| The mouse scenes miss | `./tools/calibrate.sh` |
| The Launcher shows your other apps | Run `./01-prepare.sh` again (it rewrites AIO's launcher.json and restarts AIO) |
| Currency line is empty | needs internet |
| The Island shows no song | open QuickTime Player's window, press play on the demo track, then re-run `./run-all.sh 05 08` |
| Captions off by a second | `OFFSET=…` as above |
| Want it back to normal | switch to your own account; or in the demo user: `defaults write com.apple.finder CreateDesktop -bool true; killall Finder` |

`DRY=1 ./scenes/01-cmdk.sh` walks a scene without touching the Mac, which is how the timing and flow were checked.
