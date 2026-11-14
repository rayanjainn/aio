#!/bin/bash
# One landscape YouTube video (1920x1080) from the scenes: title card, every scene with its captions, end card with the URL.
# Prints the chapter list for the description. Env: MUSIC, MUSIC_VOL, OFFSET as in make-reels.sh.
cd "$(dirname "$0")" || exit 1
HERE=$(pwd); ROOT=$(cd .. && pwd); A="$HERE/assets"
RAW="${RAW:-$ROOT/out/raw}"; OUT="${OUT:-$ROOT/out/youtube}"; mkdir -p "$OUT/seg"; rm -f "$OUT/seg"/*.mp4
. ./reels.conf
OFFSET="${OFFSET:-0}"
mark_at() { awk -v l="$2" '$2==l{print $1; exit}' "$1"; }
ENC="-r 30 -c:v libx264 -crf 18 -preset medium -pix_fmt yuv420p -video_track_timescale 30000 -an"
ORDER="cmdk snap switch act launcher dock notch music"
TITLE=3.2; ENDD=6.0
ffmpeg -hide_banner -loglevel error -y -loop 1 -framerate 30 -t $TITLE -i "$A/hook-wide.png" -vf "fade=t=in:st=0:d=0.4,fade=t=out:st=$(awk -v t=$TITLE 'BEGIN{print t-.4}'):d=0.4,format=yuv420p" $ENC "$OUT/seg/00-title.mp4" || exit 1
list="$OUT/seg/00-title.mp4"; t=$TITLE; chapters="0:00 Intro"; n=1
fmt() { awk -v s="$1" 'BEGIN{printf "%d:%02d", s/60, s%60}'; }
names_cmdk="One bar for your whole Mac (⌘K)"; names_snap="Snap windows"; names_switch="Switch windows"; names_act="Act on any text"
names_launcher="The Launcher and its widgets"; names_dock="The Dock"; names_notch="The notch (Island)"; names_music="Full-screen music"
for id in $ORDER; do
  v="reel_${id}_scene"; scene="${!v}"; v="reel_${id}_caps"; caps="${!v}"; raw="$RAW/$scene.mkv"; marks="$RAW/$scene.marks"
  { [ -f "$raw" ] && [ -f "$marks" ]; } || { echo "skip $id: no recording"; continue; }
  st=$(mark_at "$marks" start); en=$(mark_at "$marks" end); { [ -n "$st" ] && [ -n "$en" ]; } || continue
  S=$(awk -v a="$st" 'BEGIN{s=a-0.5; if(s<0)s=0; printf "%.2f", s}'); D=$(awk -v a="$st" -v b="$en" 'BEGIN{printf "%.2f", (b-a)+1.3}')
  inputs="-f lavfi -t $D -i color=c=0xf2f3f6:s=1920x1080:r=30 -ss $S -t $D -i $raw"
  fc="[1:v]scale=1600:930:force_original_aspect_ratio=decrease,fps=30,setsar=1[scr];[0:v][scr]overlay=(W-w)/2:24:shortest=1[a0];"
  last=a0; k=0; idx=2; set -- $(for item in $caps; do m="${item%%:*}"; png="${item#*:}"; tt=$(mark_at "$marks" "$m"); [ -n "$tt" ] && echo "$tt:$png"; done)
  while [ $# -gt 0 ]; do
    cur="$1"; shift; tt="${cur%%:*}"; png="${cur#*:}"
    cs=$(awk -v t="$tt" -v s="$S" -v o="$OFFSET" 'BEGIN{x=t-s+o+0.1; if(x<0.1)x=0.1; printf "%.2f", x}')
    if [ $# -gt 0 ]; then nt="${1%%:*}"; ce=$(awk -v t="$nt" -v s="$S" -v o="$OFFSET" 'BEGIN{printf "%.2f", t-s+o-0.05}'); else ce=$(awk -v d="$D" 'BEGIN{printf "%.2f", d-0.35}'); fi
    ce=$(awk -v a="$cs" -v b="$ce" 'BEGIN{if(b<a+1.2)b=a+1.2; printf "%.2f", b}'); co=$(awk -v e="$ce" 'BEGIN{printf "%.2f", e-0.25}')
    inputs="$inputs -loop 1 -framerate 30 -t $D -i $A/$png"
    fc="$fc[$idx:v]format=rgba,fade=t=in:st=$cs:d=0.25:alpha=1,fade=t=out:st=$co:d=0.25:alpha=1[c$k];[$last][c$k]overlay=420:925:shortest=1[a$((k + 1))];"
    last="a$((k + 1))"; k=$((k + 1)); idx=$((idx + 1))
  done
  fo=$(awk -v d="$D" 'BEGIN{printf "%.2f", d-0.3}')
  fc="$fc[$last]format=yuv420p,fade=t=in:st=0:d=0.3,fade=t=out:st=$fo:d=0.3[v]"
  f="$OUT/seg/$(printf '%02d' $n)-$id.mp4"
  ffmpeg -hide_banner -loglevel error -y $inputs -filter_complex "$fc" -map "[v]" -t "$D" $ENC "$f" || { echo "✗ $id failed"; continue; }
  v="names_$id"; chapters="$chapters
$(fmt "$t") ${!v}"
  list="$list $f"; t=$(awk -v a="$t" -v b="$D" 'BEGIN{print a+b}'); n=$((n + 1))
done
ffmpeg -hide_banner -loglevel error -y -loop 1 -framerate 30 -t $ENDD -i "$A/end-wide.png" -vf "fade=t=in:st=0:d=0.5,format=yuv420p" $ENC "$OUT/seg/99-end.mp4" || exit 1
list="$list $OUT/seg/99-end.mp4"; chapters="$chapters
$(fmt "$t") Get AIO (free)"
: > "$OUT/seg/list.txt"; for f in $list; do echo "file '$f'" >> "$OUT/seg/list.txt"; done
TOTAL=$(awk -v a="$t" -v b="$ENDD" 'BEGIN{print a+b}')
if [ -n "${MUSIC:-}" ] && [ -f "$MUSIC" ]; then
  ffmpeg -hide_banner -loglevel error -y -f concat -safe 0 -i "$OUT/seg/list.txt" -i "$MUSIC" -filter_complex "[1:a]atrim=0:$TOTAL,asetpts=PTS-STARTPTS,afade=t=in:d=0.8,afade=t=out:st=$(awk -v t=$TOTAL 'BEGIN{print t-2}'):d=2,volume=${MUSIC_VOL:-0.6}[a]" -map 0:v -map "[a]" -c:v copy -c:a aac -b:a 192k -movflags +faststart -t "$TOTAL" "$OUT/aio-youtube.mp4"
else
  ffmpeg -hide_banner -loglevel error -y -f concat -safe 0 -i "$OUT/seg/list.txt" -c copy -movflags +faststart "$OUT/aio-youtube.mp4"
fi
echo; echo "✓ $OUT/aio-youtube.mp4 ($(awk -v t=$TOTAL 'BEGIN{printf "%d:%02d", t/60, t%60}'))"; echo; echo "Chapters for the description (YouTube needs each chapter >= 10 s; merge short ones):"; echo "$chapters"
cp "$ROOT/../social/shots/desktop.png" "$OUT/" 2>/dev/null; true
