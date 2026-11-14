#!/bin/bash
# Records the mouse targets the scenes need into record/config.local.sh. Open AIO's Island and Launcher first when asked.
. "$(dirname "$0")/../lib/common.sh"; screen_size
frac() { mouse_sync; awk -v a="$MX" -v b="$SW" -v c="$MY" -v d="$SH" 'BEGIN{printf "%.3f %.3f", a/b, c/d}'; }
ask() { printf '\n%s\n  Put the mouse there, then press Return here... ' "$1" >&2; read -r _; frac; }
OUT="$RECORD_DIR/config.local.sh"; { echo "# written by tools/calibrate.sh"; } > "$OUT"
echo "Hover the notch so the Island is open (⌃⌥Space also opens it). Keep it open while you answer." >&2
set -- $(ask "Island tab 1 of 4 (home)");        X1=$1; Y=$2
set -- $(ask "Island tab 2 (clipboard)");        X2=$1
set -- $(ask "Island tab 3 (shelf)");            X3=$1
set -- $(ask "Island tab 4 (tools)");            X4=$1
echo "ISLAND_TAB_Y=\"$Y\"" >> "$OUT"; echo "ISLAND_TAB_XS=\"$X1 $X2 $X3 $X4\"" >> "$OUT"
echo "Now open the Launcher (⌃⌥L)." >&2
echo "WIDGET_FROM=\"$(ask 'The date widget (top-left card)')\"" >> "$OUT"
echo "WIDGET_TO=\"$(ask 'The right edge, where the widget should be dropped')\"" >> "$OUT"
echo; echo "Saved to $OUT:"; cat "$OUT"
