#!/bin/bash
# The Dock: magnification sweep, the live widgets, then the right-click menu (presets live there).
. "$(dirname "$0")/../lib/common.sh"
scene_begin 06-dock
DY=$((SH - DOCK_Y_FROM_BOTTOM)); set -- $DOCK_SWEEP; X1=$(at_frac "$1" "$SW"); X2=$(at_frac "$2" "$SW"); XM=$(at_frac 0.5 "$SW")
mouse_to "$XM" "$((SH / 2))" 600; nap 0.8
mark start; nap 0.8
mark cap_magnify;  mouse_to "$X1" "$DY" 900; nap 0.3; mouse_to "$X2" "$DY" 3200; nap 0.6
mark cap_widgets;  mouse_to "$(at_frac 0.62 "$SW")" "$DY" 900; nap 2.2
mark cap_presets;  mouse_to "$XM" "$DY" 700; nap 0.3; rclick; nap 3.0
press escape; nap 0.6; mouse_to "$XM" "$((SH / 2))" 800; nap 1.0
mark end
scene_end
