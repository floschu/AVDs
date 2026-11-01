#!/bin/bash
# Builds app/build/AVDs.app. With --install it also copies it to /Applications and restarts it.
set -euo pipefail
APP_DIR="$(cd "$(dirname "$0")/../app" && pwd)"
cd "$APP_DIR"

swift build -c release
APP=build/AVDs.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/AVDs" "$APP/Contents/MacOS/AVDs"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/MenuIcon.png Resources/MenuIcon@2x.png Resources/FloschLogo.png Resources/FloschLogo@2x.png \
  "$APP/Contents/Resources/"
# Compiles the Icon Composer file into Assets.car (Liquid Glass icon) and AVDs.icns (fallback).
xcrun actool Resources/AVDs.icon --compile "$APP/Contents/Resources" --app-icon AVDs \
  --platform macosx --target-device mac --minimum-deployment-target 26.0 \
  --output-partial-info-plist build/icon-partial.plist >/dev/null
codesign --force --sign - "$APP"
echo "built app/$APP"

if [ "${1:-}" = "--install" ]; then
  pkill -x AVDs 2>/dev/null || true
  # open fails with -600 while the old process is still quitting.
  while pgrep -x AVDs >/dev/null; do sleep 0.1; done
  rm -rf /Applications/AVDs.app
  cp -R "$APP" /Applications/AVDs.app
  open /Applications/AVDs.app
  echo "installed and started /Applications/AVDs.app"
fi
