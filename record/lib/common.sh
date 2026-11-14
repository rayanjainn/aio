#!/bin/bash
# Shared helpers for the scenes. Written for macOS bash 3.2. DRY=1 prints what would happen and fakes the clock,
# so every scene can be walked through anywhere (that is how it was tested).
RECORD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$RECORD_DIR/config.sh"
[ -f "$RECORD_DIR/config.local.sh" ] && . "$RECORD_DIR/config.local.sh"
DRY="${DRY:-0}"
OUT_RAW="${OUT_RAW:-$RECORD_DIR/out/raw}"; mkdir -p "$OUT_RAW"
VCLOCK=0; T0=0; MX=400; MY=300; SW=1512; SH=982

log() { printf '  %s\n' "$*" >&2; }
die() { printf '\n✗ %s\n' "$*" >&2; exit 1; }
now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }
nap() { if [ "$DRY" = 1 ]; then VCLOCK=$(awk -v a="$VCLOCK" -v b="$1" 'BEGIN{print a+b}'); else sleep "$1"; fi; }
elapsed() { if [ "$DRY" = 1 ]; then printf '%.2f' "$VCLOCK"; else awk -v a="$(now)" -v b="$T0" 'BEGIN{printf "%.2f", a-b}'; fi; }
run() { if [ "$DRY" = 1 ]; then log "[dry] $*"; else "$@"; fi; }
osa() { run osascript -e "$1"; }

need_demo_user() {
  [ "$DRY" = 1 ] && return 0
  [ "$FORCE" = 1 ] 2>/dev/null && return 0
  [ "$(id -un)" = "$DEMO_USER" ] || die "This must run as the macOS user \"$DEMO_USER\" (you are \"$(id -un)\"). It rearranges the desktop, hides apps and quits things; do that in a clean demo account, not your own. See record/README.md (step 1)."
}

screen_size() {
  [ "$DRY" = 1 ] && return 0
  local b; b=$(osascript -e 'tell application "Finder" to get bounds of window of desktop' 2>/dev/null | tr -d ' ')
  SW=$(echo "$b" | cut -d, -f3); SH=$(echo "$b" | cut -d, -f4)
  [ -n "$SW" ] && [ "$SW" -gt 0 ] 2>/dev/null || die "Could not read the screen size (Finder/Automation permission for your terminal?)."
}

# ---- keyboard ---------------------------------------------------------------------------------------------
keycode() { case "$1" in
  a) echo 0;; s) echo 1;; d) echo 2;; f) echo 3;; h) echo 4;; g) echo 5;; z) echo 6;; x) echo 7;; c) echo 8;; v) echo 9;;
  b) echo 11;; q) echo 12;; w) echo 13;; e) echo 14;; r) echo 15;; y) echo 16;; t) echo 17;; 1) echo 18;; 2) echo 19;; 3) echo 20;;
  4) echo 21;; 6) echo 22;; 5) echo 23;; 9) echo 25;; 7) echo 26;; 8) echo 28;; 0) echo 29;; o) echo 31;; u) echo 32;; i) echo 34;;
  p) echo 35;; l) echo 37;; j) echo 38;; k) echo 40;; n) echo 45;; m) echo 46;; return|enter) echo 36;; tab) echo 48;; space) echo 49;;
  delete|backspace) echo 51;; escape|esc) echo 53;; left) echo 123;; right) echo 124;; down) echo 125;; up) echo 126;; f12) echo 111;;
  *) die "unknown key: $1";; esac; }

# press KEY [cmd,ctrl,alt,shift]  e.g.  press k cmd   |   press left ctrl,alt
press() {
  local code using="" m
  code=$(keycode "$1") || exit 1
  for m in cmd ctrl alt shift; do
    case ",${2:-}," in *,"$m",*)
      case "$m" in cmd) m="command";; ctrl) m="control";; alt) m="option";; esac
      using="$using${using:+, }$m down";; esac
  done
  [ -n "$using" ] && using=" using {$using}"
  log "key $1${2:+ + $2}"
  osa "tell application \"System Events\" to key code $code$using"
}

# typeslow "text" [seconds per character]. One osascript per character is slow enough to look like typing.
typeslow() {
  local text="$1" d="${2:-0.075}" i=0 ch esc
  log "type \"$text\""
  while [ $i -lt ${#text} ]; do
    ch="${text:$i:1}"
    case "$ch" in '"') esc='\"';; '\') esc='\\';; *) esc="$ch";; esac
    osa "tell application \"System Events\" to keystroke \"$esc\""
    nap "$d"; i=$((i + 1))
  done
}
clear_field() { press a cmd; nap 0.15; press delete; nap 0.25; }

# hold ⌥ and press ⇥ N times (the window switcher), then let go
alt_tab() {
  local n="${1:-3}" body="" i
  log "hold ⌥, press ⇥ x$n"
  body='key down option
delay 0.45'
  for i in $(seq 1 "$n"); do body="$body
key code 48
delay 0.75"; done
  body="$body
key up option"
  osa "tell application \"System Events\"
$body
end tell"
}

# ---- mouse (needs cliclick) -------------------------------------------------------------------------------
mouse_sync() {
  [ "$DRY" = 1 ] && return 0
  local p; p=$(cliclick p:. 2>/dev/null | grep -Eo '[0-9]+' | head -2 | tr '\n' ' ')
  [ -n "$p" ] && { MX=$(echo $p | cut -d' ' -f1); MY=$(echo $p | cut -d' ' -f2); }
}
# mouse_to X Y [ms]: eased glide, ~60 steps a second
mouse_to() {
  local tx="${1%.*}" ty="${2%.*}" ms="${3:-700}" steps args
  steps=$((ms / 16)); [ "$steps" -lt 4 ] && steps=4
  args=$(awk -v x0="$MX" -v y0="$MY" -v x1="$tx" -v y1="$ty" -v n="$steps" 'BEGIN{for(i=1;i<=n;i++){t=i/n; e=(t<.5)?4*t*t*t:1-((-2*t+2)^3)/2; printf "m:%d,%d w:14 ", x0+(x1-x0)*e, y0+(y1-y0)*e}}')
  log "mouse -> $tx,$ty"
  [ "$DRY" = 1 ] && nap "$(awk -v m="$ms" 'BEGIN{print m/1000}')" || cliclick $args
  MX=$tx; MY=$ty
}
at_frac() { awk -v f="$1" -v s="$2" 'BEGIN{printf "%d", f*s}'; }   # at_frac 0.5 1512 -> 756
click() { log "click"; run cliclick c:.; }
rclick() { log "right-click"; run cliclick rc:.; }
# drag_to X Y [ms]: press where the mouse is, glide, release
drag_to() {
  local tx="${1%.*}" ty="${2%.*}" ms="${3:-1200}" steps args
  steps=$((ms / 16)); [ "$steps" -lt 8 ] && steps=8
  args=$(awk -v x0="$MX" -v y0="$MY" -v x1="$tx" -v y1="$ty" -v n="$steps" 'BEGIN{printf "dd:%d,%d w:120 ", x0, y0; for(i=1;i<=n;i++){t=i/n; e=(t<.5)?2*t*t:1-((-2*t+2)^2)/2; printf "dm:%d,%d w:14 ", x0+(x1-x0)*e, y0+(y1-y0)*e}; printf "w:150 du:%d,%d", x1, y1}')
  log "drag -> $tx,$ty"
  [ "$DRY" = 1 ] && nap "$(awk -v m="$ms" 'BEGIN{print (m+270)/1000}')" || cliclick $args
  MX=$tx; MY=$ty
}

# ---- apps -------------------------------------------------------------------------------------------------
app() { run open -a "$1"; }
quit_app() { osa "tell application \"$1\" to quit"; }
front() { osa "tell application \"$1\" to activate"; }
hide_front_terminal() {   # keep the terminal that runs the script out of the recording
  [ "$DRY" = 1 ] && return 0
  TERM_PROC=$(osascript -e 'tell application "System Events" to get name of first process whose frontmost is true' 2>/dev/null)
  [ -n "$TERM_PROC" ] && osascript -e "tell application \"System Events\" to set visible of process \"$TERM_PROC\" to false" 2>/dev/null
}
show_terminal() { [ "$DRY" = 1 ] || { [ -n "${TERM_PROC:-}" ] && osascript -e "tell application \"System Events\" to set visible of process \"$TERM_PROC\" to true" 2>/dev/null; }; }

# ---- recording --------------------------------------------------------------------------------------------
screen_index() {
  ffmpeg -hide_banner -f avfoundation -list_devices true -i "" 2>&1 | sed -n 's/.*\[\([0-9]*\)\] Capture screen 0.*/\1/p' | head -1
}
# scene_begin NAME: starts recording; marks are seconds since the first recorded frame
scene_begin() {
  SCENE="$1"; REC="$OUT_RAW/$SCENE.mkv"; MARKS="$OUT_RAW/$SCENE.marks"; : > "$MARKS"; rm -f "$REC"
  need_demo_user; screen_size
  log "scene $SCENE (screen ${SW}x${SH})"
  if [ "$DRY" = 1 ]; then VCLOCK=0; return 0; fi
  command -v ffmpeg >/dev/null || die "ffmpeg is missing: brew install ffmpeg"
  command -v cliclick >/dev/null || die "cliclick is missing: brew install cliclick"
  hide_front_terminal; nap 0.6
  local idx; idx=$(screen_index); [ -n "$idx" ] || die "ffmpeg cannot see a screen. Give your terminal Screen Recording permission (System Settings → Privacy & Security), then restart the terminal."
  rm -f "$OUT_RAW/$SCENE.progress"
  ffmpeg -hide_banner -loglevel error -f avfoundation -framerate "$FPS" -capture_cursor 1 -capture_mouse_clicks 1 -pixel_format uyvy422 \
    -i "${idx}:none" -c:v h264_videotoolbox -b:v "$BITRATE" -pix_fmt yuv420p -progress "$OUT_RAW/$SCENE.progress" "$REC" 2>"$OUT_RAW/$SCENE.ffmpeg.log" &
  FFPID=$!
  local n=0
  until grep -q '^frame=[1-9]' "$OUT_RAW/$SCENE.progress" 2>/dev/null; do
    sleep 0.05; n=$((n + 1)); [ "$n" -gt 300 ] && { kill "$FFPID" 2>/dev/null; die "ffmpeg did not start recording, see $OUT_RAW/$SCENE.ffmpeg.log"; }
  done
  T0=$(now); mouse_sync
}
mark() { printf '%s %s\n' "$(elapsed)" "$1" >> "$MARKS"; log "mark $1 @ $(elapsed)s"; }
scene_end() {
  if [ "$DRY" != 1 ]; then kill -INT "$FFPID" 2>/dev/null; wait "$FFPID" 2>/dev/null; show_terminal; fi
  log "saved $REC and $MARKS"
}
