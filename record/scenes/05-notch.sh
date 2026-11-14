#!/bin/bash
# The Island. Hovering opens it; the page tabs are clicked with the mouse, so run tools/calibrate.sh if the clicks miss.
. "$(dirname "$0")/../lib/common.sh"
scene_begin 05-notch
mouse_to "$(at_frac 0.5 "$SW")" "$(at_frac 0.5 "$SH")" 600; nap 0.8
mark start; nap 0.8
mark cap_hover; mouse_to "$(at_frac 0.5 "$SW")" 3 900; nap 2.2
TY=$(awk -v f="$ISLAND_TAB_Y" -v s="$SH" 'BEGIN{printf "%d", f*s}')
set -- $ISLAND_TAB_XS
for pair in "cap_clip $2" "cap_shelf $3" "cap_tools $4"; do
  set -- $pair; mark "$1"; mouse_to "$(at_frac "$2" "$SW")" "$TY" 700; nap 0.25; click; nap 2.2
done
mouse_to "$(at_frac 0.5 "$SW")" "$(at_frac 0.5 "$SH")" 800; nap 1.0
mark cap_volume; press f12; nap 0.5; press f12; nap 0.5; press f12; nap 1.8
mark end
scene_end
