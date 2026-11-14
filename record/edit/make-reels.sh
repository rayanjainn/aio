#!/bin/bash
# Turns the raw scenes into finished vertical Reels (1080x1920): a 2.6 s hook card, the screen inside a device
# frame with captions timed from the scene's marks, and an end card with the site URL.
#   ./make-reels.sh            every Reel that has a recording
#   ./make-reels.sh cmdk dock  only these
# Env: MUSIC=/path/track.mp3 (optional)  MUSIC_VOL=0.9  OFFSET=0 (seconds; captions come later if positive, earlier if negative)
cd "$(dirname "$0")" || exit 1
HERE=$(pwd); ROOT=$(cd .. && pwd); A="$HERE/assets"
RAW="${RAW:-$ROOT/out/raw}"; OUT="${OUT:-$ROOT/out/reels}"; mkdir -p "$OUT"
. ./reels.conf
OFFSET="${OFFSET:-0}"; HOOKD=2.6; ENDD=3.8
mark_at() { awk -v l="$2" '$2==l{print $1; exit}' "$1"; }
ids="$*"; [ -z "$ids" ] && ids="$REELS"
for id in $ids; do
  v="reel_${id}_scene"; scene="${!v}"; v="reel_${id}_hook"; hook="${!v}"; v="reel_${id}_crop"; crop="${!v}"; v="reel_${id}_caps"; caps="${!v}"
  raw="$RAW/$scene.mkv"; marks="$RAW/$scene.marks"
  { [ -f "$raw" ] && [ -f "$marks" ]; } || { echo "skip $id: no recording of $scene"; continue; }
  set -- $crop; Z=$1; FX=$2; FY=$3
  st=$(mark_at "$marks" start); en=$(mark_at "$marks" end)
  { [ -n "$st" ] && [ -n "$en" ]; } || { echo "skip $id: the start/end marks are missing in $marks"; continue; }
  S=$(awk -v a="$st" 'BEGIN{s=a-0.5; if(s<0)s=0; printf "%.2f", s}')
  D=$(awk -v a="$st" -v b="$en" 'BEGIN{printf "%.2f", (b-a)+1.3}')
  T=$(awk -v a="$HOOKD" -v b="$D" -v c="$ENDD" 'BEGIN{printf "%.2f", a+b+c}')
  inputs="-loop 1 -framerate 30 -t $HOOKD -i $A/$hook -loop 1 -framerate 30 -t $ENDD -i $A/end.png -loop 1 -framerate 30 -t $D -i $A/bg.png -ss $S -t $D -i $raw -loop 1 -framerate 30 -t $D -i $A/bezel.png"
  # captions: each one starts at its mark and stays until the next one starts
  list=""; for item in $caps; do m="${item%%:*}"; png="${item#*:}"; t=$(mark_at "$marks" "$m"); [ -n "$t" ] && list="$list $t:$png"; done
  fc="[3:v]crop=w=iw/$Z:h=ih/$Z:x=max(0\,min(iw-ow\,iw*$FX-ow/2)):y=max(0\,min(ih-oh\,ih*$FY-oh/2)),scale=1000:625:force_original_aspect_ratio=increase,crop=1000:625,fps=30,setsar=1[scr];"
  fc="$fc[2:v]fps=30,setsar=1[bgv];[bgv][scr]overlay=40:600:shortest=1[a0];[a0][4:v]overlay=0:0:shortest=1[a1];"
  last="a1"; k=0; idx=5; set -- $list
  while [ $# -gt 0 ]; do
    cur="$1"; shift; t="${cur%%:*}"; png="${cur#*:}"
    cs=$(awk -v t="$t" -v s="$S" -v o="$OFFSET" 'BEGIN{x=t-s+o+0.1; if(x<0.1)x=0.1; printf "%.2f", x}')
    if [ $# -gt 0 ]; then nt="${1%%:*}"; ce=$(awk -v t="$nt" -v s="$S" -v o="$OFFSET" 'BEGIN{printf "%.2f", t-s+o-0.05}'); else ce=$(awk -v d="$D" 'BEGIN{printf "%.2f", d-0.35}'); fi
    ce=$(awk -v a="$cs" -v b="$ce" 'BEGIN{if(b<a+1.2)b=a+1.2; printf "%.2f", b}')
    inputs="$inputs -loop 1 -framerate 30 -t $D -i $A/$png"
    co=$(awk -v e="$ce" 'BEGIN{printf "%.2f", e-0.25}')
    fc="$fc[$idx:v]format=rgba,fade=t=in:st=$cs:d=0.25:alpha=1,fade=t=out:st=$co:d=0.25:alpha=1[c$k];[$last][c$k]overlay=0:1310:shortest=1[a$((k + 2))];"
    last="a$((k + 2))"; k=$((k + 1)); idx=$((idx + 1))
  done
  hf=$(awk -v h="$HOOKD" 'BEGIN{printf "%.2f", h-0.3}')
  fc="$fc[$last]format=yuv420p,setsar=1[mainv];[0:v]fps=30,format=yuv420p,setsar=1,fade=t=in:st=0:d=0.3,fade=t=out:st=$hf:d=0.3[hv];[1:v]fps=30,format=yuv420p,setsar=1,fade=t=in:st=0:d=0.4[ev];[hv][mainv][ev]concat=n=3:v=1:a=0[v]"
  maps="-map [v]"; if [ -n "${MUSIC:-}" ] && [ -f "$MUSIC" ]; then
    inputs="$inputs -i $MUSIC"; fo=$(awk -v t="$T" 'BEGIN{printf "%.2f", t-1.4}')
    fc="$fc;[$idx:a]atrim=0:$T,asetpts=PTS-STARTPTS,afade=t=in:d=0.6,afade=t=out:st=$fo:d=1.4,volume=${MUSIC_VOL:-0.9}[am]"; maps="-map [v] -map [am]"
  fi
  out="$OUT/aio-$id.mp4"
  echo "▸ $id  ($scene, $T s, ${k} captions)"
  ffmpeg -hide_banner -loglevel error -y $inputs -filter_complex "$fc" $maps -t "$T" -r 30 -c:v libx264 -crf 18 -preset medium -pix_fmt yuv420p -c:a aac -b:a 192k -movflags +faststart "$out" || { echo "  ✗ ffmpeg failed for $id"; continue; }
  cp "$ROOT/../social/covers/$id.png" "$OUT/aio-$id-cover.png" 2>/dev/null
  echo "  ✓ $out"
done
