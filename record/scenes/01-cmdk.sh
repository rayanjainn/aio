#!/bin/bash
# ⌘K: the main feature. Keyboard only. Needs network for the currency line.
. "$(dirname "$0")/../lib/common.sh"
scene_begin 01-cmdk
front Finder; nap 0.8
mark start; nap 1.2
mark cap_press;    press k cmd;                 nap 1.6
mark cap_maths;    typeslow "12*(3+4)";         nap 2.3; clear_field
mark cap_units;    typeslow "10 km to mi";      nap 2.4; clear_field
mark cap_currency; typeslow "100 usd to eur";   nap 3.0; clear_field
mark cap_event;    typeslow "event lunch tomorrow 1pm"; nap 2.8; clear_field
mark cap_emoji;    typeslow "heart";            nap 2.5; clear_field
mark cap_apps;     typeslow "note";             nap 2.5; clear_field
press escape; nap 1.3
mark end
scene_end
