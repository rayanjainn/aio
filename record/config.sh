#!/bin/bash
# Defaults. Put your own overrides in record/config.local.sh (it is git-ignored).
DEMO_USER="aiodemo"          # the macOS user the scenes must run as; the scripts refuse to touch any other account
FPS=60                       # screen recording frame rate
BITRATE="40M"                # hardware (VideoToolbox) H.264 bitrate
APP_PATH="/Applications/AIO.app"
VOLUME=8                     # system volume while recording (the demo track only has to be "playing")
# Mouse targets, as fractions of the screen (x y). Scenes that use the mouse read these; run tools/calibrate.sh to set them exactly.
ISLAND_TAB_Y="0.235"         # y of the Island's page tabs when the Island is open
ISLAND_TAB_XS="0.455 0.485 0.515 0.545"   # x of the tabs: home, clipboard, shelf, tools
WIDGET_FROM="0.115 0.20"     # a Launcher widget (the date card)
WIDGET_TO="0.945 0.34"       # where to drop it: the right edge
DOCK_Y_FROM_BOTTOM=48        # points above the bottom edge where the Dock icons sit
DOCK_SWEEP="0.30 0.72"       # left and right ends of the Dock sweep, as fractions of the screen width
MENU_ITEM_DY=0               # unused spare
