#!/bin/bash
# ./run-all.sh            prepare the demo account, then record every scene
# ./run-all.sh 01 05      only scenes whose file name starts with 01 or 05 (no prepare unless PREPARE=1)
cd "$(dirname "$0")"; . lib/common.sh
need_demo_user
if [ $# -eq 0 ]; then PREPARE=1; set -- 01 02 03 04 05 06 07 08; fi
[ "${PREPARE:-0}" = 1 ] && [ "${SKIP_PREPARE:-0}" != 1 ] && { ./01-prepare.sh || exit 1; }
echo; echo "Recording starts in 5 seconds. Hands off the mouse and keyboard until it says done. (Ctrl-C to stop.)"
for i in 5 4 3 2 1; do printf ' %s' $i; nap 1; done; echo
for n in "$@"; do
  f=$(ls scenes/${n}*.sh 2>/dev/null | head -1); [ -n "$f" ] || { echo "no scene $n"; continue; }
  echo; echo "=== $f"; bash "$f" || { echo "scene failed: $f"; exit 1; }
  nap 1.5
done
echo; echo "Done. Raw footage is in record/out/raw/. Look at it, redo a scene with ./run-all.sh 05, then edit/make-reels.sh"
