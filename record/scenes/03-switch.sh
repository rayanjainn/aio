#!/bin/bash
# ⌥⇥ window switcher. Prepare opens Safari, two TextEdit windows and Calculator.
. "$(dirname "$0")/../lib/common.sh"
scene_begin 03-switch
front TextEdit; nap 1.0
mark start; nap 1.0
mark cap_hold;  alt_tab 3; nap 1.3
mark cap_every; alt_tab 2; nap 1.5
mark end
scene_end
