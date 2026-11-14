#!/usr/bin/env bash
# Cuts the vertical film into one short clip per feature (for Reels / Shorts / TikTok teasers).
# Beat grid of the film's music: 0.46511 s per beat, first beat at 0.2 s.  Run from the repo root.
set -euo pipefail
SRC="${1:-film/aio-film-vertical.mp4}"; OUT="${2:-social/clips}"; B=0.46511; T=0.2
mkdir -p "$OUT"
cut() {  # name first-beat last-beat
  python3 - "$1" "$2" "$3" "$SRC" "$OUT" "$B" "$T" <<'PY'
import subprocess, sys
n, a, z, src, out, B, T = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), sys.argv[4], sys.argv[5], float(sys.argv[6]), float(sys.argv[7])
s = round(T + a * B - 0.5, 2); d = round(T + z * B + 0.8 - s, 2)
subprocess.run(["ffmpeg", "-v", "error", "-y", "-ss", f"{s:.2f}", "-t", f"{d:.2f}", "-i", src,
  "-vf", f"fade=t=in:d=0.25,fade=t=out:st={d-0.3:.2f}:d=0.3", "-af", f"afade=t=in:d=0.2,afade=t=out:st={d-0.5:.2f}:d=0.5",
  "-c:v", "libx264", "-crf", "20", "-preset", "medium", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "160k", "-movflags", "+faststart", f"{out}/{n}.mp4"], check=True)
PY
}
cut 01-notch 8 17.4; cut 02-dock-presets 18.2 26.6; cut 03-launcher-widgets 27.4 37.6; cut 04-command-bar 39 47.4
cut 05-window-snapping 48.4 53.2; cut 06-act-on-this 56.8 62.8; cut 07-music 64 72; cut 08-desktop-widgets 73 77.4
