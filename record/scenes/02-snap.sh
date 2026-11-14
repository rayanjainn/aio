#!/bin/bash
# Window snapping on the demo TextEdit window (prepared by 01-prepare.sh).
. "$(dirname "$0")/../lib/common.sh"
scene_begin 02-snap
front TextEdit; nap 0.8; press delete ctrl,alt; nap 0.9     # start from the window's normal size
mark start; nap 1.0
mark cap_left;     press left ctrl,alt;   nap 1.5
mark cap_right;    press right ctrl,alt;  nap 1.5
mark cap_quarters; press u ctrl,alt; nap 1.0; press i ctrl,alt; nap 1.0; press k ctrl,alt; nap 1.0; press j ctrl,alt; nap 1.2
mark cap_max;      press return ctrl,alt; nap 1.6
mark cap_restore;  press delete ctrl,alt; nap 1.6
mark end
scene_end
