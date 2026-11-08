# Using Cortex

**⌘K** opens the palette. Type to search; `↩` opens, `⌘↩` reveals in Finder, `⌘⇧↩` copies the path.

| Type | You get |
|---|---|
| `12*(3+4)` | calculator |
| `10km to mi`, `32f in c`, `100 usd to inr` | conversions |
| `:heart` | emoji picker |
| `> ls -la` | run in Terminal |
| `? why is the sky blue` | ask the local model (Ollama) |
| `clip` | clipboard history (↩ pastes into the app you were using) |
| `snip` | snippets |
| `gh swiftui`, `yt lofi`, `maps cafe` | quicklinks (edit in Settings) |
| `define serendipity` | dictionary |
| `kill safari` | quit an app (`⌘↩` force quits) |
| `m export` | search the front app's menu items |
| `sleep`, `dark`, `mute`, `wifi off`, `pick color` | system commands |
| `left half`, `max`, `next display` | window snapping (leaves room for the Dock) |
| `tab docs` | find an open browser tab (Safari, Chrome, Brave, Arc, Edge) and jump to it |
| `ai` | AI presets on your clipboard: summarise, fix grammar, explain, translate… |
| `tr es good morning` | translate to any language code |
| `layout coding` / `layout` | save the arrangement of all your windows / bring one back |
| `mem <words>`, *Screen Memory timeline* | search or browse what you saw (needs Screen Memory on) |
| `⌥↩` on a file | Quick Look |
| *(nothing typed)* | quick actions, your newest files, your running apps |

| `cal` | today's schedule, with Join buttons |
| `note buy milk` | jot a quick note (kept in `~/.cortex/native/quicknotes.md`) |
| `pin` | pin the clipboard (text or an image) and paste it back later |

| `⌃⌥A` | **Act on this**: copies your selection and offers summarise, fix grammar, translate, reply, search, note, pin |
| `⌃⌥⇧V` | paste as plain text |
| `dock work` | save / switch Dock profiles (auto-switch per display in Settings → Dock) |
| *(nothing typed)* | commands for the app you were just in, then quick actions and recent files |

| `port 3000` | what is listening on a port — ↩ quits it |
| `uuid`, `now`, `1700000000`, `b64 …`, `sha256 …`, `md5 …`, `urlencode …` | developer tools, ↩ copies |
| `ip` | your local and public IP |
| *(nothing typed)* | your last five commands come first |

| `⌃⌥L` | **Launcher** — every app full screen, with folders, search, widgets and your wallpaper |
| `⌃⌥P` | **Music player** — full screen, vinyl / cover / waves (or double-click the Island artwork, ⌥-click the Dock music tile) |
| `space work` | save your whole setup as a Space (Dock, windows, tabs, wallpaper, glass) — `space work` again switches back |

Snippets can ask for values: `Hi {ask:Name}, see you {ask:When}`.
Scripts and Shortcuts can drive Cortex: `open "cortex://run/timer.25"`, `cortex://palette?q=tab`, `cortex://toast?text=Hello`, `cortex://layout?name=coding`.
Window layouts now also remember and reopen your browser tabs.

Snippets understand `{date}`, `{time}`, `{datetime}`, `{day}`, `{uuid}` and `{clipboard}`.

**Island** also has a Clipboard page (recent text, click to paste), hides in full-screen apps, and can show a pill on every display (Settings → Island).
**Dock Peek** — drag a window preview off the Dock and the window lands where you drop it.
**Nudges** — meeting start/end, focus sessions count app switches (and can hide other apps), battery hogs, "welcome back" after sleep.
**Hyper key** — Settings → General: Caps Lock presses ⌃⌥⌘⇧ with another key; use it in Settings → Shortcuts.
**AI** — Settings → AI: Ollama on this Mac, **Ollama Cloud** (paste your ollama.com key), or any OpenAI-compatible server.
**Dock widgets** — Settings → Dock, or right-click the Dock → *Add widget*: Now Playing, Clock, Battery, Weather, Focus Timer, System, Next Meeting.
**Dock** — right-click the bar for size, magnification, position; right-click an icon for *Change Icon…*, *Show All Windows*, Hide, Quit.
**⌥⇥** — switch between any window. **Notch** — hover it; swipe sideways to change page; drop files on it to park them on the Shelf.
**Scripts** — put executable files in `~/.cortex/scripts/`; they show up in the palette.
**Settings** — `⌘,` from the ✦ menu: shortcuts, Island, Dock, appearance, permissions, snippets, quicklinks, updates.

Permissions (all optional): Accessibility (window snapping, volume keys, paste, menu search), Screen Recording (window previews), Calendar (meetings).
