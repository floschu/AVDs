#!/bin/bash
# Records the demo: app/Resources/demo.webp, the animation in the README, and
# app/Resources/demo.mp4, the same at full size for X and other posts. Both come from one
# recording, so they stay in sync. AVDs launches a real emulator,
# mirrors a connected phone, opens the New Emulator screen, then stops both, so it loops.
#
# It runs in real mode. It creates a throwaway AVD "Pixel 10" (Pixel_10), boots it
# once so Launch quick-boots it on camera, records, then stops and deletes it. Your own AVDs stay
# untouched, but they show up in the panel. Connect and unlock a phone to show mirroring.
# Run it when the UI changed. After a boot of about a minute it takes over mouse and keyboard
# for about 20 seconds.
# Needs ffmpeg, img2webp (brew install webp), scrcpy for mirroring, and Accessibility and
# Screen Recording access for the terminal.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
command -v ffmpeg >/dev/null || { echo "error: ffmpeg is missing. Install it with: brew install ffmpeg" >&2; exit 1; }
command -v img2webp >/dev/null || { echo "error: img2webp is missing. Install it with: brew install webp" >&2; exit 1; }

AVD_ID=Pixel_10 # shows in the emulator's title bar
AVD_NAME="Pixel 10"
DEVICE=pixel_10
SCALE=0.3 # emulator window scale, about 730 points tall for a Pixel 10
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
AVD_HOME="${ANDROID_AVD_HOME:-$HOME/.android/avd}"
AVD_DIR="$AVD_HOME/$AVD_ID.avd"
LOG_DIR="$HOME/.android/$AVD_ID" # the android CLI puts the emulator log here
MP4=app/Resources/demo.mp4
WEBP=app/Resources/demo.webp
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$SDK/platform-tools:$PATH"
export ANDROID_HOME="$SDK"
command -v android >/dev/null || { echo "error: the android CLI is missing" >&2; exit 1; }
AVDMANAGER="$SDK/cmdline-tools/latest/bin/avdmanager"
[ -x "$AVDMANAGER" ] || { echo "error: avdmanager is missing. Install the SDK Command-line Tools." >&2; exit 1; }
if [ -z "${JAVA_HOME:-}" ]; then export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"; fi
[ -e "$LOG_DIR" ] && KEEP_LOG=1 || KEEP_LOG=""
[ -e "$AVD_DIR" ] && { echo "error: $AVD_DIR exists. The script needs that name for its throwaway AVD. Rename yours, or let a previous run finish." >&2; exit 1; }

# The newest installed phone image, Google Play first. Wear, TV, Automotive and XR images don't fit.
IMAGE=$(cd "$SDK" && ls -d system-images/*/*/arm64-v8a 2>/dev/null \
  | grep -vE 'wear|tv|automotive|xr|desktop' \
  | awk -F/ '{ rank = ($3 ~ /playstore/) ? 2 : ($3 ~ /google_apis/) ? 1 : 0; print rank "\t" $2 "\t" $0 }' \
  | sort -t$'\t' -k2,2V -k1,1n | tail -1 | cut -f3 | tr / ';')
[ -n "$IMAGE" ] || { echo "error: no phone system image installed. Install one in AVDs first." >&2; exit 1; }

scripts/build.sh
swiftc -O -o app/build/record-demo scripts/record-demo.swift

running() { pgrep -f "qemu-system.*@$AVD_ID" >/dev/null; }
serial() { android emulator list --long 2>/dev/null | awk -v id="$AVD_ID" '$1 == id { print $NF }' | grep emulator- || true; }

USER_APP=""
APP_PID=""
cleanup() {
  [ -n "$APP_PID" ] && kill "$APP_PID" 2>/dev/null || true
  if running; then
    local s
    s=$(serial)
    android emulator stop "${s:-$AVD_ID}" >/dev/null 2>&1 || true
    while running; do sleep 0.5; done
  fi
  if [ -e "$AVD_DIR" ]; then
    android emulator remove "$AVD_ID" >/dev/null 2>&1 || "$AVDMANAGER" delete avd -n "$AVD_ID" >/dev/null 2>&1 || true
  fi
  [ -z "$KEEP_LOG" ] && rm -rf "$LOG_DIR"
  if [ -n "$USER_APP" ]; then
    [ -n "$APP_PID" ] && while kill -0 "$APP_PID" 2>/dev/null; do sleep 0.1; done
    open "$USER_APP"
  fi
}
trap cleanup EXIT

echo "creating $AVD_ID from $IMAGE"
echo no | "$AVDMANAGER" create avd -n "$AVD_ID" -k "$IMAGE" -d "$DEVICE" >/dev/null
# Like AVDManager.create in the app: Play Store, keyboard and GPU on, and a readable name.
# No device frame: at this size its edges look rough. The window is the plain screen.
CONFIG="$AVD_DIR/config.ini"
sed -i '' -e '/^PlayStore.enabled=/d' -e '/^hw.keyboard=/d' -e '/^hw.gpu.enabled=/d' \
  -e '/^avd.ini.displayname=/d' -e '/^showDeviceFrame=/d' -e '/^skin\./d' "$CONFIG"
PLAY=no; [[ "$IMAGE" == *playstore* ]] && PLAY=yes
printf 'PlayStore.enabled=%s\nhw.keyboard=yes\nhw.gpu.enabled=yes\navd.ini.displayname=%s\nshowDeviceFrame=no\n' \
  "$PLAY" "$AVD_NAME" >> "$CONFIG"
printf 'window.scale = %s\n' "$SCALE" > "$AVD_DIR/emulator-user.ini"

# The first boot is a cold boot of about a minute. Stopping saves the snapshot that Launch uses.
echo "booting $AVD_ID once, so it quick-boots in the recording"
android emulator start "$AVD_ID" >/dev/null
sleep 8 # let the launcher settle, so the snapshot shows the home screen
read -r EMU_W EMU_H <<< "$(app/build/record-demo measure | sed -n 's/^EMULATOR //p')"
android emulator stop "$(serial)" >/dev/null
while running; do sleep 0.5; done
# The emulator writes its window settings back on exit.
sed -i '' '/^window.scale/d' "$AVD_DIR/emulator-user.ini"
printf 'window.scale = %s\n' "$SCALE" >> "$AVD_DIR/emulator-user.ini"
# Don't save the state again when it stops in the recording. That takes about 12 seconds.
# 1 is Never. The snapshot from the boot above stays.
printf '[perAvd]\nset\\saveSnapshotOnExit=1\n' > "$AVD_DIR/AVD.conf"

# Swap the running AVDs, if any, for the fresh build. Put it back at the end.
if PID=$(pgrep -x AVDs); then
  USER_APP=$(ps -o comm= -p "$PID" | sed 's|/Contents/MacOS/AVDs$||')
  osascript -e 'quit app "AVDs"'
  while pgrep -x AVDs >/dev/null; do sleep 0.1; done
fi
app/build/AVDs.app/Contents/MacOS/AVDs >/dev/null 2>&1 &
APP_PID=$!
sleep 4

MAIN=app/build/demo-main.mov
BAR=app/build/demo-bar.mov
RESULT=$(app/build/record-demo "$APP_PID" "$MAIN" "$BAR" "$AVD_DIR" "$AVD_NAME" "$EMU_W" "$EMU_H")
read -r _ _ W H <<< "$(echo "$RESULT" | sed -n 's/^AREA //p')"
read -r BX BY <<< "$(echo "$RESULT" | sed -n 's/^BAR //p')"
read -r FROM TO <<< "$(echo "$RESULT" | sed -n 's/^HIDE //p')"
[ -n "$H" ] && [ -n "$BY" ] && [ -n "$TO" ] && [ -s "$MAIN" ] && [ -s "$BAR" ] || { echo "error: the recording failed" >&2; exit 1; }

# The main recording leaves out the menu bar. Lay the recorded menu bar over it, without the
# items of other apps between the app's icon and Apple's items. The numbers are in points, the
# recordings in pixels.
P=$(( $(ffprobe -v error -show_entries stream=width -of csv=p=0 "$MAIN") / W ))
IFS=x read -r BW BH <<< "$(ffprobe -v error -show_entries stream=width,height -of csv=s=x:p=0 "$BAR")"
even() { echo $(( ($1 * P) / 2 * 2 )); }
if [ "$TO" -gt "$FROM" ]; then
  L=$(even "$FROM"); R=$(even "$TO")
  BAR_FILTER="[1]split[a][b];[a]crop=$L:$BH:0:0[left];[b]crop=$((BW - R)):$BH:$R:0[right];\
[0][left]overlay=$(even "$BX"):$(even "$BY"):eof_action=repeat[t];\
[t][right]overlay=$(( $(even "$BX") + R )):$(even "$BY"):eof_action=repeat"
else
  BAR_FILTER="[0][1]overlay=$(even "$BX"):$(even "$BY"):eof_action=repeat"
fi
# Then scale 1.5x with Lanczos, so the 1x capture holds up against the compression of social sites.
ffmpeg -v error -y -i "$MAIN" -i "$BAR" -filter_complex \
  "$BAR_FILTER,scale=$((W * 3 / 2)):$((H * 3 / 2)):flags=lanczos,format=yuv420p" \
  -c:v libx264 -preset slow -crf 16 -r 60 -movflags +faststart -an "$MP4"
rm -f "$MAIN" "$BAR"

# The README gets an animated WebP. GitHub shows those inline, unlike MP4 files in the repo.
# It keeps the recorded size, 1x, so text stays sharp. About 4 MB at quality 88.
FRAMES=app/build/demo-frames
rm -rf "$FRAMES" && mkdir -p "$FRAMES"
ffmpeg -v error -i "$MP4" -vf "fps=15,scale=$W:-1:flags=lanczos" "$FRAMES/%05d.png"
img2webp -loop 0 -lossy -q 88 -m 4 -d 67 "$FRAMES"/*.png -o "$WEBP" >/dev/null
rm -rf "$FRAMES"
echo "wrote $MP4 ($(du -h "$MP4" | cut -f1 | tr -d ' ')) and $WEBP ($(du -h "$WEBP" | cut -f1 | tr -d ' '))"
