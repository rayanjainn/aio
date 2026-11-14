#!/bin/bash
# Act on this: select text in the demo TextEdit window, press ⌃⌥A. Shows the action bar, runs nothing.
. "$(dirname "$0")/../lib/common.sh"
scene_begin 04-act
front TextEdit; nap 1.0
mark start; nap 1.0
mark cap_select; press a cmd; nap 1.6
mark cap_act;    press a ctrl,alt; nap 2.4
mark cap_choose; nap 2.8
press escape; nap 1.0
mark end
scene_end
