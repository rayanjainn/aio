#!/bin/bash
# The Launcher: open, search, drag a widget to the other side. Run tools/calibrate.sh if the drag misses the widget.
. "$(dirname "$0")/../lib/common.sh"
scene_begin 07-launcher
front Finder; nap 0.8
mark start; nap 0.8
mark cap_open;   press l ctrl,alt; nap 2.0
mark cap_search; typeslow "note"; nap 1.8; clear_field; nap 0.5
mark cap_drag
set -- $WIDGET_FROM; mouse_to "$(at_frac "$1" "$SW")" "$(at_frac "$2" "$SH")" 800; nap 0.4
set -- $WIDGET_TO;   drag_to "$(at_frac "$1" "$SW")" "$(at_frac "$2" "$SH")" 1500; nap 2.6
press escape; nap 1.2
mark end
scene_end
