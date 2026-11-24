#!/bin/bash
# Builds the app bundle. No Xcode project: SwiftPM produces the binary and this
# script wraps it in the layout macOS expects for a menu bar app.
#
# APP_NAME is what the bundle and its permission prompts are called. The name the
# assistant answers to is a runtime setting and does not need a rebuild.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="${APP_NAME:-Notch Assistant}"
CONFIG="${CONFIG:-release}"
BUILD="$ROOT/build"
APP="$BUILD/$APP_NAME.app"
BUNDLE_ID="${BUNDLE_ID:-com.naderabdulrub.notchassistant}"
# What people call this version, and the number versions are compared by: how
# many commits it is built from, which only ever grows on main.
VERSION="${VERSION:-$(tr -d '[:space:]' < "$ROOT/VERSION")}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)}"
# Where a copy looks for a newer one, and the key every update must be signed
# with. A build made to be worked on has no feed and never replaces itself;
# scripts/dist.sh gives the ones that are handed out theirs.
FEED_URL="${FEED_URL:-}"
UPDATE_KEY="${UPDATE_KEY:-$(tr -d '[:space:]' < "$ROOT/Resources/update-key.pub")}"

cd "$ROOT"
swift build -c "$CONFIG" --product Assistant
swift build -c "$CONFIG" --product AssistantChannel
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

mkdir -p "$BUILD"
rm -rf "${APP:?}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/Assistant" "$APP/Contents/MacOS/Assistant"
cp "$BIN_DIR/AssistantChannel" "$APP/Contents/MacOS/assistant-channel"
sed -e "s/__APP_NAME__/$APP_NAME/g" -e "s/__BUNDLE_ID__/$BUNDLE_ID/g" -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD_NUMBER/g" \
    -e "s|__FEED_URL__|$FEED_URL|g" -e "s|__UPDATE_KEY__|$UPDATE_KEY|g" \
    "$ROOT/Resources/Info.plist" > "$APP/Contents/Info.plist"
# Sparkle, which fetches and installs new versions. The binary looks for it
# here, and its licence travels with it.
cp -R "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/"
cp "$ROOT/.build/artifacts/sparkle/Sparkle/LICENSE" "$APP/Contents/Resources/Sparkle-LICENSE.txt"
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
codesign --force --deep --sign - "$APP/Contents/Frameworks/Sparkle.framework" >/dev/null 2>&1 \
  || echo "warning: could not sign the update framework"
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP" >/dev/null 2>&1 \
  || echo "warning: could not sign the bundle; permissions may be asked for again on each build"

echo "built $APP ($VERSION, build $BUILD_NUMBER)"
