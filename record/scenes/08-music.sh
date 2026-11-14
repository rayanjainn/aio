#!/bin/bash
# Full-screen music player. 01-prepare.sh starts the demo track in QuickTime Player; the keys 1-5 switch styles.
. "$(dirname "$0")/../lib/common.sh"
scene_begin 08-music
front Finder; nap 0.8
mark start; nap 0.8
mark cap_play;   press p ctrl,alt; nap 2.6
mark cap_styles; for k in 2 3 4 5 1; do press "$k"; nap 1.5; done
mark cap_keys;   press space; nap 1.2; press space; nap 1.5
press escape; nap 1.2
mark end
scene_end
