#!/bin/bash
# Cortex self-test — run on the Mac that has Cortex installed.
#
#   bash selftest.sh [path/to/Cortex.app]
#
# Collects everything needed to diagnose lag and broken features into ONE text file on the
# Desktop (plus a CPU profile of the app). Read-only: it changes nothing, except that the
# interactive phase asks you to move the mouse for a few seconds.
#
# Send the resulting ~/Desktop/cortex-selftest-*.txt (and the .sample.txt next to it).

set -u
APP="${1:-}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$HOME/Desktop/cortex-selftest-$STAMP.txt"
SAMPLE="$HOME/Desktop/cortex-selftest-$STAMP.sample.txt"
CORTEX_HOME="$HOME/.cortex"

exec > >(tee "$OUT") 2>&1

PASS=0; FAIL=0; WARN=0
section() { printf '\n==================== %s ====================\n' "$1"; }
ok()      { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad()     { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }
warn()    { WARN=$((WARN+1)); printf '  [WARN] %s\n' "$1"; }
info()    { printf '         %s\n' "$1"; }
have()    { command -v "$1" >/dev/null 2>&1; }

section "0. Context"
date
sw_vers 2>/dev/null
uname -m
sysctl -n machdep.cpu.brand_string 2>/dev/null
printf 'RAM: %s GB\n' "$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1073741824 ))"
pmset -g batt 2>/dev/null | head -2
printf 'Low Power Mode: '; pmset -g 2>/dev/null | awk '/lowpowermode/ {print $2}' | head -1
echo
echo "Displays:"
system_profiler SPDisplaysDataType 2>/dev/null | grep -E "Resolution|Chipset Model|Display Type|Main Display|Mirror|UI Looks" | sed 's/^ */  /'

# ------------------------------------------------------------------------------------------
section "1. App bundle"
if [ -z "$APP" ]; then
  for c in "/Applications/Cortex.app" "$HOME/Applications/Cortex.app" "$HOME/Desktop/Cortex.app" "$HOME/Downloads/Cortex.app"; do
    [ -d "$c" ] && APP="$c" && break
  done
fi
RUNNING_BIN="$(pgrep -x Cortex | head -1)"
if [ -n "$RUNNING_BIN" ]; then
  RPATH="$(ps -p "$RUNNING_BIN" -o comm= 2>/dev/null)"
  [ -n "$RPATH" ] && APP="${RPATH%/Contents/MacOS/*}"
fi
if [ -d "$APP" ]; then
  ok "found app: $APP"
  PLIST="$APP/Contents/Info.plist"
  info "version: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST" 2>/dev/null)"
  info "bundle id: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST" 2>/dev/null)"
  info "executable arch: $(lipo -archs "$APP/Contents/MacOS/Cortex" 2>/dev/null)"
  [ -x "$APP/Contents/Helpers/cortexd" ] && ok "cortexd helper present ($(lipo -archs "$APP/Contents/Helpers/cortexd" 2>/dev/null))" || bad "cortexd helper missing in Contents/Helpers"
  [ -f "$APP/Contents/Resources/mediaremote/mediaremote-adapter.pl" ] && ok "mediaremote adapter script present" || bad "mediaremote adapter script missing"
  [ -d "$APP/Contents/Resources/mediaremote/MediaRemoteAdapter.framework" ] && ok "mediaremote framework present" || bad "mediaremote framework missing"
  codesign -dv "$APP" 2>&1 | grep -E "Identifier|Signature|flags|TeamIdentifier" | sed 's/^/         /'
  if codesign -dv "$APP" 2>&1 | grep -q "runtime"; then
    bad "app is hardened-runtime signed (Apple Events would be denied)"
  else
    ok "not hardened-runtime (Apple Events allowed)"
  fi
  xattr "$APP" 2>/dev/null | grep -q quarantine && warn "app is quarantined — right-click > Open once, or: xattr -dr com.apple.quarantine \"$APP\""
else
  bad "Cortex.app not found. Pass its path: bash selftest.sh /path/to/Cortex.app"
fi

# ------------------------------------------------------------------------------------------
section "2. Processes"
PID="$(pgrep -x Cortex | head -1)"
DPID="$(pgrep -x cortexd | head -1)"
if [ -n "$PID" ]; then ok "Cortex running (pid $PID)"; else bad "Cortex is not running — open it and re-run"; fi
if [ -n "$DPID" ]; then ok "cortexd engine running (pid $DPID)"; else bad "cortexd engine not running"; fi
echo "mediaremote adapter processes:"; pgrep -fl mediaremote-adapter || echo "  (none)"
echo
echo "Process table (CPU% MEM% RSS-MB threads):"
for p in $PID $DPID; do
  ps -p "$p" -o pid=,pcpu=,pmem=,rss=,comm= 2>/dev/null | awk '{printf "  pid %s  cpu %s%%  mem %s%%  rss %.0f MB  %s\n",$1,$2,$3,$4/1024,$5}'
  printf '  threads: %s\n' "$(ps -M -p "$p" 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')"
  printf '  open files: %s\n' "$(lsof -p "$p" 2>/dev/null | wc -l | tr -d ' ')"
done

# ------------------------------------------------------------------------------------------
if [ -z "$PID" ]; then
  echo
  echo "  Cortex is not running, so the CPU, profile and engine checks would be meaningless."
  echo "  → Open Cortex ($APP), wait ~10 s for the Dock/Island to appear, then run this script again."
  echo "  (Log below is from the LAST run, not now.)"
  section "5. Log (last run)"
  grep -E "starting on" "$CORTEX_HOME/logs/native.log" 2>/dev/null | tail -3 | sed 's/^/  /'
  grep -E ' (ERROR|WARN) ' "$CORTEX_HOME/logs/native.log" 2>/dev/null | tail -8 | sed 's/^/  /'
  printf '\n  PASS: %s   WARN: %s   FAIL: %s\n  Report: %s\n' "$PASS" "$WARN" "$FAIL" "$OUT"
  exit 0
fi

section "3. Idle CPU (10 s, hands off the mouse)"
if [ -n "$PID" ]; then
  echo "Sampling… don't touch the mouse for 10 seconds."
  IDLE="$(top -l 3 -s 4 -pid "$PID" -stats pid,cpu,mem,threads,command 2>/dev/null | awk '$1=='"$PID"' {print $2}' | tail -1)"
  printf '  Cortex idle CPU (last sample): %s%%\n' "${IDLE:-?}"
  if [ -n "${IDLE:-}" ]; then
    awk -v c="$IDLE" 'BEGIN{ if (c+0 > 15) exit 1; else exit 0 }' && ok "idle CPU is low" || bad "idle CPU is high (${IDLE}%) — something is spinning; see the profile below"
  fi
  if [ -n "$DPID" ]; then
    DIDLE="$(top -l 2 -s 3 -pid "$DPID" -stats pid,cpu 2>/dev/null | awk '$1=='"$DPID"' {print $2}' | tail -1)"
    printf '  cortexd idle CPU: %s%%\n' "${DIDLE:-?}"
  fi
fi

# ------------------------------------------------------------------------------------------
section "4. Interactive lag profile"
if [ -n "$PID" ] && have sample; then
  cat <<'MSG'
  For the next 8 seconds the app is profiled. DURING this time please:
    1. Slide the mouse slowly back and forth over the whole Dock (hover every icon)
    2. Move the pointer to the top-centre of the screen so the Island expands, then away
    3. Press ⌘K (or your palette shortcut) once and type a few letters, then Esc
MSG
  printf '  Starting in '; for i in 3 2 1; do printf '%s… ' "$i"; sleep 1; done; echo "GO"
  sample "$PID" 8 -file "$SAMPLE" >/dev/null 2>&1
  if [ -s "$SAMPLE" ]; then
    ok "profile written: $SAMPLE"
    echo "  Heaviest main-thread frames (top 12):"
    awk '/Thread_.*DispatchQueue_1: com.apple.main-thread/ {m=1} m && /^    [+!:| ]*[0-9]+ / {print} /Thread_/ && !/main-thread/ {m=0}' "$SAMPLE" 2>/dev/null | sort -rn | head -12 | sed 's/^/    /'
  else
    warn "sample produced nothing"
  fi
else
  warn "skipped (app not running or 'sample' missing)"
fi

# ------------------------------------------------------------------------------------------
section "5. Log (~/.cortex/logs/native.log)"
LOG="$CORTEX_HOME/logs/native.log"
if [ -f "$LOG" ]; then
  ok "log exists ($(wc -l < "$LOG" | tr -d ' ') lines)"
  printf '  ERROR lines: %s   WARN lines: %s\n' "$(grep -c ' ERROR ' "$LOG")" "$(grep -c ' WARN ' "$LOG")"
  echo "  Last ERROR/WARN lines:"
  grep -E ' (ERROR|WARN) ' "$LOG" | tail -15 | sed 's/^/    /'
  echo "  Last 15 lines:"
  tail -15 "$LOG" | sed 's/^/    /'
else
  bad "no native.log — the app has never run, or runs under another user"
fi
[ -f "$CORTEX_HOME/logs/cortexd.log" ] && { echo "  cortexd.log tail:"; tail -8 "$CORTEX_HOME/logs/cortexd.log" | sed 's/^/    /'; }

echo
echo "Crash reports (last 5):"
ls -t "$HOME/Library/Logs/DiagnosticReports/" 2>/dev/null | grep -iE "cortex" | head -5 | sed 's/^/  /'
[ -z "$(ls "$HOME/Library/Logs/DiagnosticReports/" 2>/dev/null | grep -iE cortex)" ] && echo "  none"

echo
echo "Unified log, last 10 min (Cortex errors/faults):"
log show --last 10m --style compact --predicate 'process == "Cortex" AND (messageType == error OR messageType == fault)' 2>/dev/null | tail -15 | sed 's/^/  /'

# ------------------------------------------------------------------------------------------
section "6. Engine (cortexd JSON-RPC over unix socket)"
SOCK="$CORTEX_HOME/cortexd.sock"
if [ -S "$SOCK" ]; then
  ok "socket exists"
  if have nc; then
    rpc() { printf '%s\n' "$1" | nc -U -w 3 "$SOCK" 2>/dev/null | head -1; }
    R="$(rpc '{"id":1,"method":"ping","params":{}}')"
    if echo "$R" | grep -q uptimeMs; then ok "ping: $R"; else bad "ping failed: ${R:-no reply}"; fi
    for q in "safari" "notes" "calc" "1+1"; do
      T0=$(perl -MTime::HiRes=time -e 'print time')
      R="$(rpc "{\"id\":2,\"method\":\"search\",\"params\":{\"query\":\"$q\",\"limit\":5}}")"
      T1=$(perl -MTime::HiRes=time -e 'print time')
      N="$(echo "$R" | grep -o '"title"' | wc -l | tr -d ' ')"
      MS="$(awk -v a="$T0" -v b="$T1" 'BEGIN{printf "%.0f",(b-a)*1000}')"
      if [ "$N" -gt 0 ]; then ok "search '$q' → $N hits in ${MS} ms"; else warn "search '$q' → 0 hits (${MS} ms): ${R:0:160}"; fi
    done
    R="$(rpc '{"id":3,"method":"status","params":{}}')"; info "status: ${R:0:300}"
  else warn "nc not available"; fi
else
  bad "no socket at $SOCK — engine is down; palette search will be empty"
fi

# ------------------------------------------------------------------------------------------
section "7. Now Playing (MediaRemote adapter run by hand)"
AD="$APP/Contents/Resources/mediaremote"
if [ -f "$AD/mediaremote-adapter.pl" ]; then
  OUTJ="$(/usr/bin/perl "$AD/mediaremote-adapter.pl" "$AD/MediaRemoteAdapter.framework" get --micros 2>&1 | head -c 1500)"
  if echo "$OUTJ" | grep -q '"title"'; then ok "adapter returns the current track"; info "${OUTJ:0:500}"
  elif [ "$OUTJ" = "null" ] || [ -z "$OUTJ" ]; then warn "adapter works but nothing is playing/paused right now (start a song and re-run)"
  else bad "adapter output unexpected: ${OUTJ:0:400}"; fi
else warn "adapter not found, skipped"; fi

# ------------------------------------------------------------------------------------------
section "8. Permissions"
echo "  (macOS 14+ hides the TCC database; these probes test the real capability instead)"
# Accessibility: System Events can only read UI elements if the *terminal* has it, so test via Cortex's own log/Diagnostics.
grep -E "Accessibility" "$LOG" 2>/dev/null | tail -2 | sed 's/^/  log: /'
echo "  → In Cortex: menu-bar icon → Diagnostics shows 'Accessibility: granted/missing' and 'screenRecording'."
printf '  Screen Recording (Terminal probe): '
screencapture -x -t png /tmp/cortex-probe.png 2>/dev/null && [ -s /tmp/cortex-probe.png ] && echo "capture ok" || echo "capture failed"
rm -f /tmp/cortex-probe.png
printf '  Automation → Music: '
osascript -e 'tell application "Music" to get player state' 2>&1 | head -1
printf '  Calendar access (EventKit via icalBuddy not available; checking Calendar app is installed): '
[ -d /System/Applications/Calendar.app ] && echo yes || echo no

# ------------------------------------------------------------------------------------------
section "9. Dock coexistence"
printf '  macOS Dock autohide: %s\n' "$(defaults read com.apple.dock autohide 2>/dev/null || echo 0)"
printf '  macOS Dock autohide-delay: %s\n' "$(defaults read com.apple.dock autohide-delay 2>/dev/null || echo default)"
printf '  macOS Dock tilesize: %s\n' "$(defaults read com.apple.dock tilesize 2>/dev/null || echo default)"
printf '  Dock process: %s\n' "$(pgrep -x Dock | head -1)"
echo "  If Cortex quit uncleanly and the real Dock stays hidden, restore it with:"
echo "      defaults write com.apple.dock autohide -bool false; defaults delete com.apple.dock autohide-delay; killall Dock"

# ------------------------------------------------------------------------------------------
section "10. Settings & data files"
ls -la "$CORTEX_HOME/native/" 2>/dev/null | sed 's/^/  /'
echo
echo "  prefs.json:"
[ -f "$CORTEX_HOME/native/prefs.json" ] && sed 's/^/    /' "$CORTEX_HOME/native/prefs.json" | head -40 || echo "    (none — defaults in use)"
echo
echo "  Partial downloads in ~/Downloads (the Island watches these):"
find "$HOME/Downloads" -maxdepth 1 \( -name '*.crdownload' -o -name '*.download' -o -name '*.part' -o -name '*.opdownload' -o -name '*.partial' \) -exec ls -l {} \; 2>/dev/null | sed 's/^/    /'
echo "    (a file listed here that is not changing is a leftover — delete it)"

# ------------------------------------------------------------------------------------------
section "11. Other things that make macOS laggy"
echo "  Top 8 CPU processes right now (if WindowServer/nehelper/another app is high, lag may not be Cortex):"
ps -Ao pcpu,pmem,comm -r 2>/dev/null | head -9 | awk 'NR==1{print "    "$0;next}{printf "    %5s%% %5s%%  %s\n",$1,$2,$3}'
echo
echo "  Other Dock / window-manager style apps running (they fight over the same windows):"
ps -Ao comm 2>/dev/null | grep -E "/Applications/.*(Bartender|Rectangle|Magnet|AltTab|Raycast|Alfred|NotchNook|boring|DockDoor|Hammerspoon|Ice|yabai|Amethyst|uBar|Stats|Ferrite|OBS|Zoom|Teams)" | sed 's/^/    /' | sort -u
echo "  Reduce Transparency: $(defaults read com.apple.universalaccess reduceTransparency 2>/dev/null || echo 0)  (1 disables Liquid Glass)"
echo "  Reduce Motion:       $(defaults read com.apple.universalaccess reduceMotion 2>/dev/null || echo 0)"

# ------------------------------------------------------------------------------------------
section "SUMMARY"
printf '  PASS: %s   WARN: %s   FAIL: %s\n' "$PASS" "$WARN" "$FAIL"
printf '\n  Report:  %s\n' "$OUT"
[ -s "$SAMPLE" ] && printf '  Profile: %s\n' "$SAMPLE"
echo
echo "  Now take screenshots of the things that look wrong and send everything together."
