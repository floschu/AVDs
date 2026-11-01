#!/bin/bash
# Records app/Resources/demo.png, the animation in the README, with sample data (AVDS_DEMO=1).
# It's an animated PNG of the panel window only, with a transparent background.
# Run it when the UI changed. It takes over mouse and keyboard for about 30 seconds.
# Needs ffmpeg, and Accessibility and Screen Recording access for the terminal.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
command -v ffmpeg >/dev/null || { echo "error: ffmpeg is missing. Install it with: brew install ffmpeg" >&2; exit 1; }

scripts/build.sh
swiftc -O -o app/build/record-demo scripts/record-demo.swift

# Swap the running AVDs, if any, for one in demo mode. Put it back at the end.
USER_APP=""
if PID=$(pgrep -x AVDs); then
  USER_APP=$(ps -o comm= -p "$PID" | sed 's|/Contents/MacOS/AVDs$||')
  osascript -e 'quit app "AVDs"'
  while pgrep -x AVDs >/dev/null; do sleep 0.1; done
fi
AVDS_DEMO=1 app/build/AVDs.app/Contents/MacOS/AVDs >/dev/null 2>&1 &
DEMO_PID=$!
cleanup() {
  kill "$DEMO_PID" 2>/dev/null || true
  if [ -n "$USER_APP" ]; then
    while kill -0 "$DEMO_PID" 2>/dev/null; do sleep 0.1; done
    open "$USER_APP"
  fi
}
trap cleanup EXIT
sleep 3

FRAMES=app/build/demo-frames
OUT=$(app/build/record-demo "$DEMO_PID" "$FRAMES")
FPS=$(echo "$OUT" | sed -n 's/^FPS //p')
read -r CROP_W CROP_H <<< "$(echo "$OUT" | sed -n 's/^CROP //p')"
[ -n "$FPS" ] && [ -n "$CROP_H" ] || { echo "error: the recording failed" >&2; exit 1; }
# Frames are in pixels. On a Retina screen that's twice the points.
SCALE=$(( $(ffprobe -v error -show_entries stream=width -of csv=p=0 "$FRAMES/frame00000.png") / (CROP_W + 200) ))

# APNG keeps soft transparent edges, and clears areas that turn transparent when the panel
# shrinks. GIF can do neither.
ffmpeg -v error -y -framerate "$FPS" -i "$FRAMES/frame%05d.png" \
  -vf "crop=$((CROP_W * SCALE)):$((CROP_H * SCALE)):0:0" -plays 0 -f apng app/Resources/demo.png
COUNT=$(ls "$FRAMES" | wc -l | tr -d ' ')
echo "wrote app/Resources/demo.png ($(du -h app/Resources/demo.png | cut -f1 | tr -d ' '), $COUNT frames at $FPS fps)"
