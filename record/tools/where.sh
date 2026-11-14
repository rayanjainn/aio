#!/bin/bash
# Prints the mouse position as points and as fractions of the screen, every half second. Ctrl-C to stop.
. "$(dirname "$0")/../lib/common.sh"; screen_size
while true; do mouse_sync; printf '\rx=%s y=%s   fraction: %s %s     ' "$MX" "$MY" "$(awk -v a="$MX" -v b="$SW" 'BEGIN{printf "%.3f", a/b}')" "$(awk -v a="$MY" -v b="$SH" 'BEGIN{printf "%.3f", a/b}')"; sleep 0.5; done
