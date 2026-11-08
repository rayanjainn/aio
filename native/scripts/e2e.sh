#!/bin/bash
# Cortex end-to-end test — run on the Mac with Cortex installed.
#
#   bash e2e.sh                 # finds Cortex.app, runs everything (about 4 minutes)
#   bash e2e.sh /path/Cortex.app
#
# Opens every surface through cortex:// links, checks the windows really appear (size and
# position), takes screenshots, probes the search engine, Now Playing, permissions and
# performance, collects logs and crash reports, then zips everything onto your Desktop:
#     ~/Desktop/cortex-e2e-<time>.zip      ← send me this
#
# Your Cortex settings are backed up first and restored at the end. Nothing is deleted.
# Please don't use the mouse or keyboard while it runs (it takes screenshots).

set -u
APP="${1:-}"
STAMP="$(date +%Y%m%d-%H%M%S)"
WORK="$HOME/Desktop/cortex-e2e-$STAMP"
SHOTS="$WORK/screenshots"
LOGS="$WORK/logs"
REPORT="$WORK/report.md"
CORTEX="$HOME/.cortex"
mkdir -p "$SHOTS" "$LOGS"

PASS=0; FAIL=0; WARN=0; SKIP=0
say()  { printf '%s\n' "$*" | tee -a "$REPORT"; }
ok()   { PASS=$((PASS+1)); say "- ✅ $*"; }
bad()  { FAIL=$((FAIL+1)); say "- ❌ $*"; }
warn() { WARN=$((WARN+1)); say "- ⚠️ $*"; }
skip() { SKIP=$((SKIP+1)); say "- ⏭ $*"; }
section() { say ""; say "## $*"; echo "→ $*" >&2; }

# ---------------------------------------------------------------- helpers
urlenc() { /usr/bin/python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$1" 2>/dev/null || printf '%s' "$1" | sed 's/ /%20/g'; }
link()   { open -g "cortex://$1" >/dev/null 2>&1; }
shot()   { screencapture -x -t png "$SHOTS/$1.png" 2>/dev/null; }
shot_region() { screencapture -x -t png -R "$2" "$SHOTS/$1.png" 2>/dev/null; }   # x,y,w,h (top-left origin)

# Cortex's on-screen windows as "x y w h" lines (top-left origin), via the window server.
cortex_windows() {
  osascript -l JavaScript <<'JXA' 2>/dev/null
ObjC.import('CoreGraphics');
var list = ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo(1, 0))) || [];
var out = [];
list.forEach(function (w) {
  if (w.kCGWindowOwnerName === 'Cortex' && w.kCGWindowBounds) {
    var b = w.kCGWindowBounds;
    out.push([Math.round(b.X), Math.round(b.Y), Math.round(b.Width), Math.round(b.Height), w.kCGWindowLayer].join(' '));
  }
});
out.join('\n');
JXA
}
has_window_wider_than() { cortex_windows | awk -v m="$1" '$3 >= m { found=1 } END { exit found ? 0 : 1 }'; }
has_window_size() { cortex_windows | awk -v w="$1" -v tol="${2:-4}" '($3 - w) <= tol && (w - $3) <= tol { f=1 } END { exit f ? 0 : 1 }'; }
screen_w() { osascript -e 'tell application "Finder" to get item 3 of (get bounds of window of desktop)' 2>/dev/null || echo 1440; }
screen_h() { osascript -e 'tell application "Finder" to get item 4 of (get bounds of window of desktop)' 2>/dev/null || echo 900; }
cpu_of() { ps -o pcpu= -p "$1" 2>/dev/null | tr -d ' '; }
rss_mb() { ps -o rss= -p "$1" 2>/dev/null | awk '{printf "%d", $1/1024}'; }
# Synthetic pointer events (top-left origin). Needs Accessibility for the terminal app; otherwise they're ignored.
mouse_event() {  # type x y button
  osascript -l JavaScript -e "ObjC.import('CoreGraphics'); var e = \$.CGEventCreateMouseEvent(null, $1, {x: $2, y: $3}, $4); \$.CGEventPost(0, e);" >/dev/null 2>&1
}
mouse_to()    { mouse_event 5 "$1" "$2" 0; }
mouse_click() { mouse_to "$1" "$2"; sleep 0.1; mouse_event 1 "$1" "$2" 0; sleep 0.05; mouse_event 2 "$1" "$2" 0; }
mouse_right() { mouse_to "$1" "$2"; sleep 0.1; mouse_event 3 "$1" "$2" 1; sleep 0.05; mouse_event 4 "$1" "$2" 1; }
front_app()   { osascript -e 'tell application "System Events" to get name of first process whose frontmost is true' 2>/dev/null; }

{
  echo "# Cortex end-to-end report"
  echo ""
  echo "Started $(date). Screenshots are in \`screenshots/\`, logs in \`logs/\`."
} > "$REPORT"

# ---------------------------------------------------------------- 0. context
section "0. This Mac"
say "- macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion)), $(uname -m), $(sysctl -n machdep.cpu.brand_string 2>/dev/null)"
say "- RAM $(( $(sysctl -n hw.memsize) / 1073741824 )) GB · $(pmset -g batt 2>/dev/null | sed -n 2p | sed 's/^[[:space:]]*//')"
SW=$(screen_w); SH=$(screen_h)
say "- Main display (points): ${SW}×${SH}"
system_profiler SPDisplaysDataType 2>/dev/null | grep -E "Resolution|Main Display" | sed 's/^ */  - /' | tee -a "$REPORT" >/dev/null

# ---------------------------------------------------------------- 1. app + backup
section "1. App bundle"
if [ -z "$APP" ]; then
  PID0=$(pgrep -x Cortex | head -1)
  if [ -n "$PID0" ]; then APP="$(ps -o comm= -p "$PID0" | sed 's#/Contents/MacOS/.*##')"; fi
fi
[ -z "$APP" ] && for c in /Applications/Cortex.app "$HOME/Applications/Cortex.app" "$HOME/Desktop/Cortex.app" "$HOME/Downloads/Cortex.app"; do [ -d "$c" ] && APP="$c" && break; done
if [ ! -d "$APP" ]; then bad "Cortex.app not found — pass its path: bash e2e.sh /path/Cortex.app"; fi
VER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null)
say "- App: \`$APP\` version **$VER** ($(lipo -archs "$APP/Contents/MacOS/Cortex" 2>/dev/null))"
[ -x "$APP/Contents/Helpers/cortexd" ] && ok "search engine helper is in the bundle" || bad "cortexd helper missing"
[ -f "$APP/Contents/Resources/mediaremote/mediaremote-adapter.pl" ] && ok "Now Playing adapter is in the bundle" || bad "mediaremote adapter missing"
/usr/libexec/PlistBuddy -c 'Print :CFBundleURLTypes:0:CFBundleURLSchemes:0' "$APP/Contents/Info.plist" 2>/dev/null | grep -q cortex \
  && ok "cortex:// links are registered" || bad "cortex:// URL scheme missing — this build is too old for the e2e test (need v0.3.5+)"
codesign --verify "$APP" 2>/dev/null && ok "code signature is valid" || warn "code signature did not verify"
xattr "$APP" 2>/dev/null | grep -q quarantine && warn "app is quarantined (run: xattr -cr \"$APP\")"

if [ -d "$CORTEX/native" ]; then
  cp -R "$CORTEX/native" "$WORK/settings-backup" 2>/dev/null && ok "settings backed up (restored at the end)"
fi
restore() {
  if [ -d "$WORK/settings-backup" ]; then
    rsync -a --delete "$WORK/settings-backup/" "$CORTEX/native/" 2>/dev/null
    rm -rf "$WORK/settings-backup"
  fi
}
trap restore EXIT

# ---------------------------------------------------------------- 2. launch
section "2. Launch"
if ! pgrep -x Cortex >/dev/null; then
  open "$APP"; sleep 8
fi
PID=$(pgrep -x Cortex | head -1)
DPID=$(pgrep -x cortexd | head -1)
[ -n "$PID" ] && ok "Cortex is running (pid $PID)" || { bad "Cortex is not running — stopping"; exit 1; }
[ -n "$DPID" ] && ok "search engine running (pid $DPID)" || bad "search engine (cortexd) not running"
link "run/app.diagnostics.export"; sleep 1.5
if [ -f "$CORTEX/logs/diagnostics.txt" ]; then
  cp "$CORTEX/logs/diagnostics.txt" "$LOGS/diagnostics-start.txt"; ok "Diagnostics exported"
  grep -q "Accessibility (window snapping): granted" "$LOGS/diagnostics-start.txt" && ok "Accessibility permission granted" || warn "Accessibility NOT granted — window snapping, previews, media keys, paste and menus won't work"
  grep -q "screenRecording=true" "$LOGS/diagnostics-start.txt" && ok "Screen Recording permission granted" || warn "Screen Recording not granted — Dock window thumbnails won't show"
else
  bad "Diagnostics export didn't appear (cortex:// links may not reach the app)"
fi
shot "00-desktop"
say "- Windows Cortex has on screen: \`$(cortex_windows | tr '\n' ';')\`"

# ---------------------------------------------------------------- 3. engine
section "3. Search engine"
SOCK="$CORTEX/cortexd.sock"
if [ -S "$SOCK" ] && command -v nc >/dev/null; then
  rpc() { printf '%s\n' "$1" | nc -U -w 4 "$SOCK" 2>/dev/null | head -1; }
  R=$(rpc '{"id":1,"method":"ping","params":{}}')
  echo "$R" | grep -q uptimeMs && ok "ping: $R" || bad "engine ping failed: ${R:-no reply}"
  for q in safari notes terminal readme; do
    T0=$(perl -MTime::HiRes=time -e 'print time'); R=$(rpc "{\"id\":2,\"method\":\"search\",\"params\":{\"query\":\"$q\",\"limit\":8}}"); T1=$(perl -MTime::HiRes=time -e 'print time')
    N=$(echo "$R" | grep -o '"title"' | wc -l | tr -d ' '); MS=$(awk -v a="$T0" -v b="$T1" 'BEGIN{printf "%.0f",(b-a)*1000}')
    [ "$N" -gt 0 ] && ok "search \"$q\": $N results in ${MS} ms" || warn "search \"$q\": no results (${MS} ms)"
    [ "$MS" -gt 500 ] && warn "search \"$q\" took ${MS} ms (aim: under 200)"
  done
  rpc '{"id":3,"method":"status","params":{}}' > "$LOGS/engine-status.json"
else
  bad "engine socket missing"
fi

# ---------------------------------------------------------------- 4. palette
section "4. ⌘K palette"
pal() {  # name query
  link "palette?q=$(urlenc "$2")"; sleep 1.6
  if has_window_size 740 6; then ok "palette opens for \`$2\`"; else bad "palette window not found for \`$2\`"; fi
  shot "palette-$1"
  link "run/palette"; sleep 0.6   # toggles it closed
}
pal 01-empty ""
pal 02-app "safari"
pal 03-calculator "12*(3+4)"
pal 04-convert "10km to mi"
pal 05-currency "100 usd to inr"
pal 06-emoji ":heart"
pal 07-clipboard "clip"
pal 08-snippets "snip"
pal 09-ai "ai"
pal 10-tabs "tab"
pal 11-windows "win"
pal 12-layouts "layout"
pal 13-spaces "space"
pal 14-dock-profiles "dock"
pal 15-schedule "cal"
pal 16-notes "note test from e2e"
pal 17-pins "pin"
pal 18-uuid "uuid"
pal 19-epoch "1700000000"
pal 20-base64 "b64 hello"
pal 21-port "port 22"
pal 22-ip "ip"
pal 23-translate "tr es good morning"
pal 24-define "define serendipity"
pal 25-menu "m new"
pal 26-kill "kill finder"
pal 27-system "dark"
pal 28-widget "widget battery cycle count"
pal 29-memory "mem"

# ---------------------------------------------------------------- 5. launcher
section "5. Launcher"
link "run/launcher"; sleep 2.5
if has_window_wider_than $((SW - 4)); then ok "launcher fills the screen"; else bad "launcher window not full screen"; fi
shot "launcher-01"
link "run/launcher"; sleep 1
cortex_windows | awk -v m=$((SW - 4)) '$3 >= m { f=1 } END { exit f ? 1 : 0 }' && ok "launcher closes again" || warn "launcher still on screen after toggling"

# ---------------------------------------------------------------- 6. music player
section "6. Full-screen music player"
for s in vinyl cover waves; do
  link "run/music.style:$s"; sleep 0.3
  link "run/music"; sleep 2
  has_window_wider_than $((SW - 4)) && ok "music player opens ($s)" || bad "music player not on screen ($s)"
  shot "music-$s"
  link "run/music"; sleep 0.8
done
link "run/music.style:vinyl"

# Lyrics pane + keyboard: open the player, press 2 (cover) and L (lyrics), check prefs follow.
link "run/music.lyrics:on"; sleep 0.3
link "run/music"; sleep 2.5
shot "music-lyrics"
osascript -e 'tell application "System Events" to keystroke "2"' >/dev/null 2>&1; sleep 0.8
grep -q '"musicPlayerStyle":"cover"' "$CORTEX/native/prefs.json" 2>/dev/null && ok "pressing 2 in the player switches to the cover style" || bad "pressing 2 did not change the player style"
shot "music-lyrics-cover"
osascript -e 'tell application "System Events" to keystroke "l"' >/dev/null 2>&1; sleep 0.8
grep -q '"musicPlayerLyrics":false' "$CORTEX/native/prefs.json" 2>/dev/null && ok "pressing L hides the lyrics" || bad "pressing L did not toggle lyrics"
shot "music-no-lyrics"
osascript -e 'tell application "System Events" to key code 53' >/dev/null 2>&1; sleep 0.8
has_window_wider_than $((SW - 4)) && bad "Esc did not close the player" || ok "Esc closes the player"
link "run/music.lyrics:on"; link "run/music.style:vinyl"

# ---------------------------------------------------------------- 7. island
section "7. Island"
shot_region "island-00-compact" "$((SW/2 - 360)),0,720,60"
cortex_windows | awk '$2 <= 2 && $3 < 1000 { f=1 } END { exit f ? 0 : 1 }' && ok "Island pill is at the top of the screen" || bad "Island pill not found at the top"
for page in player calendar shelf clipboard rewind tools; do
  link "run/island.page:$page"; sleep 1.2
  shot_region "island-page-$page" "$((SW/2 - 360)),0,720,320"
  cortex_windows | awk '$2 <= 2 && $4 >= 150 { f=1 } END { exit f ? 0 : 1 }' && ok "Island expands to the $page page" || bad "Island did not expand for $page"
done
link "run/island.collapse"; sleep 1

# ---------------------------------------------------------------- 8. dock
section "8. Dock"
TERM_APP=$(front_app)
DOCKLINE=$(cortex_windows | awk -v h="$SH" '($2 + $4) >= h - 8 && $3 > 200 { print; exit }')
if [ -n "$DOCKLINE" ]; then
  ok "Cortex Dock on screen: \`$DOCKLINE\`"
  set -- $DOCKLINE; DX=$1; DY=$2; DW=$3; DH=$4
  shot_region "dock" "$DX,$(( DY - 160 )),$DW,$(( DH + 160 ))"
  MIDY=$(( DY + DH / 2 ))

  # Hover sweep with magnification on: the Dock window must grow while the pointer is over it.
  link "run/dock.magnify:on"; sleep 0.6
  mouse_to $(( DX + DW / 2 )) $(( DY - 200 )); sleep 0.4
  BEFORE=$(cortex_windows | awk -v h="$SH" '($2 + $4) >= h - 8 && $3 > 200 { print $4; exit }')
  MAXH=$BEFORE; i=0
  for x in $(seq $(( DX + 24 )) 22 $(( DX + DW - 24 ))); do
    mouse_to "$x" "$MIDY"; sleep 0.07
    i=$((i+1))
    if [ $((i % 6)) -eq 0 ]; then
      H=$(cortex_windows | awk -v h="$SH" '($2 + $4) >= h - 8 && $3 > 200 { print $4; exit }')
      [ -n "$H" ] && [ "$H" -gt "${MAXH:-0}" ] && MAXH=$H
    fi
    [ $i -eq 12 ] && shot_region "dock-hover-magnify" "$DX,$(( DY - 200 )),$DW,$(( DH + 200 ))"
  done
  if [ "${MAXH:-0}" -gt "${BEFORE:-0}" ]; then ok "Dock magnifies under the pointer (height $BEFORE → $MAXH)"
  else warn "Dock height didn't change while hovering ($BEFORE) — the terminal may need Accessibility to move the pointer"; fi

  # Rest on the first icon (Finder is always running): label + window previews should appear above it.
  mouse_to $(( DX + 30 )) "$MIDY"; sleep 1.6
  shot_region "dock-hover-preview" "$DX,$(( DY - 420 )),$(( DW / 2 + 200 )),$(( DH + 420 ))"
  cortex_windows | awk -v top="$DY" '($2 + $4) <= top + 4 && $4 > 60 && $3 > 100 { f=1 } END { exit f ? 0 : 1 }' \
    && ok "hovering a running app shows its window previews" || warn "no preview panel above the Dock (no Screen Recording, or Finder has no windows)"

  # A first click activates the app (non-activating panel: the click must not be spent on focus).
  [ -n "$TERM_APP" ] && [ "$TERM_APP" != "Finder" ] && osascript -e "tell application \"System Events\" to set frontmost of process \"$TERM_APP\" to true" >/dev/null 2>&1; sleep 0.4
  mouse_click $(( DX + 30 )) "$MIDY"; sleep 1.2
  [ "$(front_app)" = "Finder" ] && ok "one click on the Finder icon brings Finder forward" || warn "after one click the front app is $(front_app), not Finder"

  # Right-click the bar background (past the Trash divider) for the Dock menu.
  mouse_right $(( DX + DW - 6 )) "$MIDY"; sleep 0.8
  shot "dock-context-menu"
  osascript -e 'tell application "System Events" to key code 53' >/dev/null 2>&1; sleep 0.3

  mouse_to $(( DX + DW / 2 )) $(( DY - 300 )); sleep 0.8
  link "run/dock.magnify:restore"; sleep 0.4
  AFTER=$(cortex_windows | awk -v h="$SH" '($2 + $4) >= h - 8 && $3 > 200 { print $4; exit }')
  [ "${AFTER:-0}" -le "$(( ${BEFORE:-0} + 2 ))" ] && ok "Dock shrinks back after the pointer leaves" || bad "Dock window stayed tall ($AFTER) after the pointer left — it would block clicks"
else
  warn "no Cortex Dock at the bottom (off, auto-hidden, or on another edge)"; shot "dock-fullscreen"
fi
say "- macOS Dock autohide=$(defaults read com.apple.dock autohide 2>/dev/null || echo 0)"

# ---------------------------------------------------------------- 9. windows & settings
section "9. Windows"
link "run/app.settings"; sleep 2; shot "settings"; osascript -e 'tell application "System Events" to keystroke "w" using command down' >/dev/null 2>&1
link "run/app.timeline"; sleep 2; shot "memory-timeline"; osascript -e 'tell application "System Events" to keystroke "w" using command down' >/dev/null 2>&1
link "run/app.addWidget"; sleep 2; shot "widget-gallery"; osascript -e 'tell application "System Events" to keystroke "w" using command down' >/dev/null 2>&1
link "run/app.diagnostics"; sleep 2; shot "diagnostics-window"; osascript -e 'tell application "System Events" to keystroke "w" using command down' >/dev/null 2>&1
ok "opened Settings, Screen Memory, widget gallery and Diagnostics (see screenshots)"
osascript -e 'tell application "Finder" to activate' >/dev/null 2>&1; sleep 1
shot "desktop-widgets"

# ---------------------------------------------------------------- 10. now playing
section "10. Now Playing"
AD="$APP/Contents/Resources/mediaremote"
OUTJ=$(/usr/bin/perl "$AD/mediaremote-adapter.pl" "$AD/MediaRemoteAdapter.framework" get --micros 2>&1 | sed 's/"artworkData":"[^"]*"/"artworkData":"…"/' | head -c 800)
if echo "$OUTJ" | grep -q '"bundleIdentifier"'; then ok "Now Playing adapter works: \`$(echo "$OUTJ" | grep -o '"title":"[^"]*"' | head -1)\`"
elif [ -z "$OUTJ" ] || [ "$OUTJ" = "null" ]; then warn "nothing playing (start a song and re-run to test music surfaces)"
else bad "adapter output unexpected: \`$OUTJ\`"; fi

# ---------------------------------------------------------------- 11. performance
section "11. Performance"
sleep 3
CPU_IDLE=$(top -l 3 -s 3 -pid "$PID" -stats cpu 2>/dev/null | tail -1 | tr -d ' ')
say "- Cortex idle CPU: ${CPU_IDLE}% · memory $(rss_mb "$PID") MB · threads $(ps -M -p "$PID" | tail -n +2 | wc -l | tr -d ' ')"
[ -n "$DPID" ] && say "- cortexd CPU: $(cpu_of "$DPID")% · memory $(rss_mb "$DPID") MB"
awk -v c="${CPU_IDLE:-0}" 'BEGIN{ exit (c+0 > 10) ? 1 : 0 }' && ok "idle CPU is low" || bad "idle CPU is high (${CPU_IDLE}%)"
link "run/launcher"; sleep 1
sample "$PID" 4 -file "$LOGS/profile-launcher.txt" >/dev/null 2>&1 && ok "profiled the launcher while open (logs/profile-launcher.txt)"
link "run/launcher"; sleep 1
sample "$PID" 4 -file "$LOGS/profile-idle.txt" >/dev/null 2>&1 && ok "profiled idle (logs/profile-idle.txt)"

# ---------------------------------------------------------------- 12. hyper key + misc state
section "12. State"
MAP=$(hidutil property --get UserKeyMapping 2>/dev/null | tr -d '\n' | head -c 300)
say "- hidutil key mapping: \`${MAP:-none}\`"
say "- prefs: \`$(head -c 1500 "$CORTEX/native/prefs.json" 2>/dev/null | tr -d '\n')\`"

# ---------------------------------------------------------------- 13. logs
section "13. Logs and crashes"
cp "$CORTEX/logs/native.log" "$LOGS/" 2>/dev/null
cp "$CORTEX/logs/cortexd.log" "$LOGS/" 2>/dev/null
link "run/app.diagnostics.export"; sleep 1; cp "$CORTEX/logs/diagnostics.txt" "$LOGS/diagnostics-end.txt" 2>/dev/null
ERRS=$(grep -c " ERROR " "$CORTEX/logs/native.log" 2>/dev/null); ERRS=${ERRS:-0}
[ "$ERRS" = "0" ] && ok "no ERROR lines in native.log" || bad "$ERRS ERROR lines in native.log (see logs/native.log)"
log show --last 15m --style compact --predicate 'process == "Cortex" AND (messageType == error OR messageType == fault)' > "$LOGS/system-errors.txt" 2>/dev/null
CR=$(ls -t "$HOME/Library/Logs/DiagnosticReports/" 2>/dev/null | grep -iE "^Cortex" | head -3)
if [ -n "$CR" ]; then
  bad "crash reports found: $(echo $CR)"
  for f in $CR; do cp "$HOME/Library/Logs/DiagnosticReports/$f" "$LOGS/" 2>/dev/null; done
else ok "no Cortex crash reports"; fi

# ---------------------------------------------------------------- done
section "Summary"
say "- ✅ $PASS passed · ❌ $FAIL failed · ⚠️ $WARN warnings · ⏭ $SKIP skipped"
say "- Not automatable here (please check by hand): Peek, drag-and-drop to the Shelf, media keys/HUD, Act on this (⌃⌥A), Hyper key."
restore; trap - EXIT
# Keep the zip small enough to attach anywhere: JPEG screenshots at a readable size, compressed profiles.
for f in "$SHOTS"/*.png; do
  [ -f "$f" ] || continue
  sips -Z 1600 -s format jpeg -s formatOptions 72 "$f" --out "${f%.png}.jpg" >/dev/null 2>&1 && rm -f "$f"
done
gzip -9 "$LOGS"/profile-*.txt 2>/dev/null
ZIP="$HOME/Desktop/cortex-e2e-$STAMP.zip"
ditto -c -k --sequesterRsrc --keepParent "$WORK" "$ZIP" && rm -rf "$WORK"
echo ""
echo "Done: $PASS passed, $FAIL failed, $WARN warnings."
echo "Send this file: $ZIP ($(du -h "$ZIP" | cut -f1))"
open -R "$ZIP" 2>/dev/null
