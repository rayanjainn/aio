#!/bin/bash
# Checks tools and permissions before you spend time on a take.
. "$(dirname "$0")/lib/common.sh"
ok=1; bad() { printf '  ✗ %s\n' "$*"; ok=0; }; good() { printf '  ✓ %s\n' "$*"; }
[ "$(uname)" = Darwin ] || { echo "This only runs on a Mac."; exit 1; }
echo "Tools"; for t in ffmpeg cliclick osascript perl; do command -v $t >/dev/null && good "$t" || bad "$t missing$( [ $t = ffmpeg -o $t = cliclick ] && echo " (brew install $t)")"; done
[ -d "$APP_PATH" ] && good "AIO is installed" || bad "AIO is not in $APP_PATH"
pgrep -x AIO >/dev/null && good "AIO is running" || bad "AIO is not running (open it once)"
echo "User"; [ "$(id -un)" = "$DEMO_USER" ] && good "running as $DEMO_USER" || bad "running as $(id -un), not $DEMO_USER (set FORCE=1 to override at your own risk)"
echo "Permissions (your terminal needs all three)"
osascript -e 'tell application "System Events" to key code 56' >/dev/null 2>&1 && good "Accessibility: can send keys" || bad "Accessibility: System Settings → Privacy & Security → Accessibility → turn on your terminal"
cliclick m:200,200 >/dev/null 2>&1 && good "cliclick can move the mouse" || bad "cliclick cannot move the mouse (same Accessibility switch)"
osascript -e 'tell application "Finder" to get bounds of window of desktop' >/dev/null 2>&1 && good "Automation: can control Finder" || bad "Automation: allow your terminal to control Finder and System Events when macOS asks"
idx=$(screen_index); [ -n "$idx" ] && good "ffmpeg sees screen $idx" || bad "ffmpeg cannot see a screen: Privacy & Security → Screen Recording → turn on your terminal, then restart it"
if [ -n "$idx" ]; then
  T=/tmp/aio-record-test.mkv; rm -f $T
  ffmpeg -hide_banner -loglevel error -f avfoundation -framerate 30 -capture_cursor 1 -pixel_format uyvy422 -t 2 -i "${idx}:none" -c:v h264_videotoolbox -b:v 8M -pix_fmt yuv420p $T 2>/dev/null
  [ -s $T ] && good "2-second test recording worked ($(du -h $T | cut -f1))" || bad "test recording failed"
fi
[ $ok = 1 ] && echo "All good. Run ./run-all.sh" || { echo "Fix the ✗ lines, then run this again."; exit 1; }
