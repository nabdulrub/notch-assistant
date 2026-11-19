#!/bin/bash
# Builds the app bundle. No Xcode project: SwiftPM produces the binary and this
# script wraps it in the layout macOS expects for a menu bar app.
#
# APP_NAME is what the bundle and its permission prompts are called. The name the
# assistant answers to is a runtime setting and does not need a rebuild.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="${APP_NAME:-Jarvis}"
CONFIG="${CONFIG:-release}"
BUILD="$ROOT/build"
APP="$BUILD/$APP_NAME.app"
BUNDLE_ID="com.naderabdulrub.notchassistant"

cd "$ROOT"
swift build -c "$CONFIG" --product Assistant
swift build -c "$CONFIG" --product AssistantChannel
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

mkdir -p "$BUILD"
rm -rf "${APP:?}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Assistant" "$APP/Contents/MacOS/Assistant"
cp "$BIN_DIR/AssistantChannel" "$APP/Contents/MacOS/assistant-channel"
sed "s/__APP_NAME__/$APP_NAME/g" "$ROOT/Resources/Info.plist" > "$APP/Contents/Info.plist"
# The bridge to the voice model that runs on this Mac. It is run with that model's own Python.
cp "$ROOT/Resources/sophon_bridge.py" "$APP/Contents/Resources/sophon_bridge.py"

# The icon is drawn by the app itself, so it always matches the eyes in the notch.
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
if "$APP/Contents/MacOS/Assistant" --icon "$ICONSET/base.png" >/dev/null 2>&1; then
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ICONSET/base.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z "$((size * 2))" "$((size * 2))" "$ICONSET/base.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  rm -f "$ICONSET/base.png"
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" || echo "warning: could not build the icon"
else
  echo "warning: could not draw the icon"
fi

# Signed ad hoc with a fixed identifier. That is enough to run locally; macOS may
# ask for the microphone again after a rebuild until a real signing identity is
# set up.
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP" >/dev/null 2>&1 \
  || echo "warning: could not sign the bundle; permissions may be asked for again on each build"

echo "built $APP"
