#!/bin/bash
# Gets the demo account ready: light desktop, nothing but Apple's apps and AIO in the Launcher, demo windows,
# demo clipboard, a demo track playing. Safe to run again. Run it as the demo user (see README step 1).
. "$(dirname "$0")/lib/common.sh"
need_demo_user
step() { printf '\n▸ %s\n' "$*"; }

step "Light appearance, clean desktop, system Dock out of the way"
osa 'tell application "System Events" to tell appearance preferences to set dark mode to false'
osa "tell application \"System Events\" to tell every desktop to set picture to POSIX file \"$RECORD_DIR/assets/wallpaper.png\""
run defaults write com.apple.finder CreateDesktop -bool false
run defaults write com.apple.dock autohide -bool true
run killall Finder; run killall Dock
osa "set volume output volume $VOLUME"

step "Launcher shows only Apple's apps and AIO (everything else is hidden in AIO's launcher.json, nothing is uninstalled)"
quit_app AIO; nap 1.5
mkdir -p "$HOME/.cortex/native"
[ -f "$HOME/.cortex/native/launcher.json" ] && [ ! -f "$HOME/.cortex/native/launcher.json.bak" ] && cp "$HOME/.cortex/native/launcher.json" "$HOME/.cortex/native/launcher.json.bak"
hidden=""
for app in /Applications/*.app /Applications/Utilities/*.app "$HOME/Applications"/*.app; do
  [ -d "$app" ] || continue
  bid=$(defaults read "$app/Contents/Info" CFBundleIdentifier 2>/dev/null || true)
  case "$bid" in com.apple.*|dev.cortex.native) continue;; esac
  case "$app" in *'"'*|*'\'*) continue;; esac
  hidden="$hidden\"$app\","
done
hidden="${hidden%,}"
if [ "$DRY" = 1 ]; then log "[dry] would write launcher.json hiding non-Apple apps"; else printf '{"folders":[],"hidden":[%s],"names":{}}\n' "$hidden" > "$HOME/.cortex/native/launcher.json"; fi
run open "$APP_PATH"; nap 3

step "Demo windows: two TextEdit documents, Safari, Calculator"
osa 'tell application "TextEdit"
  activate
  set d1 to make new document with properties {text:"Plan for Monday" & return & return & "Select this sentence, then pick an action: translate it, summarise it or fix it." & return & return & "• Ship the update" & return & "• Reply to Sam" & return & "• Book lunch with Priya"}
  set bounds of front window to {260, 170, 1000, 640}
  set d2 to make new document with properties {text:"Ideas" & return & return & "• A launcher that is also a calculator" & return & "• Widgets on both sides"}
  set bounds of front window to {420, 250, 1160, 720}
end tell'
osa 'tell application "Safari" to activate'; nap 1.5
osa 'tell application "Calculator" to activate'; nap 1.0
osa 'tell application "TextEdit" to activate'

step "Demo clipboard history (newest last)"
for item in 'git commit -m "ship it"' '~/Documents/Q4 plan.pdf' '#0071E3' 'https://aio.raycode.tech'; do
  [ "$DRY" = 1 ] && log "[dry] pbcopy: $item" || printf '%s' "$item" | pbcopy
  nap 1.6
done

step "Demo track (silent-ish) in QuickTime Player so the Island and the player have something to show"
TRACK="$HOME/.cortex/demo/night-drive.m4a"; mkdir -p "$HOME/.cortex/demo"
if [ ! -f "$TRACK" ] && [ "$DRY" != 1 ]; then
  ffmpeg -hide_banner -loglevel error -y -f lavfi -i "sine=frequency=110:duration=240" -i "$RECORD_DIR/assets/cover.png" -map 0:a -map 1:v \
    -af volume=0.05 -c:a aac -b:a 96k -c:v mjpeg -disposition:v attached_pic \
    -metadata title="Night Drive" -metadata artist="The Example Band" -metadata album="Demo" "$TRACK" || die "ffmpeg could not make the demo track (brew install ffmpeg)"
fi
run open -a "QuickTime Player" "$TRACK"; nap 2.5
osa 'tell application "QuickTime Player" to play document 1'
osa 'tell application "System Events" to set visible of process "QuickTime Player" to false'
osa 'tell application "TextEdit" to activate'

printf '\n✓ Prepared. Look at the screen once: Launcher (⌃⌥L) should show only Apple apps and AIO; the Island should show "Night Drive".\n'
