#!/bin/bash
# Builds a disk image to hand to someone else: the app, a shortcut to
# Applications, and a short read-me.
#
# With no signing identity the app is signed ad hoc, and macOS will refuse to
# open a downloaded copy until its quarantine flag is cleared; the read-me says
# how. To ship one that just opens, set both of these:
#   SIGN_IDENTITY   a "Developer ID Application: ..." identity in the keychain
#   NOTARY_PROFILE  a profile saved with `xcrun notarytool store-credentials`
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="${APP_NAME:-Notch Assistant}"
APP="$ROOT/build/$APP_NAME.app"
DIST="$ROOT/dist"
BUNDLE_ID="${BUNDLE_ID:-com.naderabdulrub.notchassistant}"
REPO="${REPO:-nabdulrub/notch-assistant}"
# A copy that is handed out looks here for the next one.
FEED_URL="${FEED_URL:-https://github.com/$REPO/releases/latest/download/appcast.xml}"

cd "$ROOT"
CONFIG=release APP_NAME="$APP_NAME" BUNDLE_ID="$BUNDLE_ID" FEED_URL="$FEED_URL" "$ROOT/scripts/bundle.sh"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$DIST/${APP_NAME// /}-$VERSION.dmg"

SIGNED=no
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  # Sparkle's own helpers are signed from the inside out, as its documentation asks.
  SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$SPARKLE/XPCServices/Installer.xpc"
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" --preserve-metadata=entitlements "$SPARKLE/XPCServices/Downloader.xpc"
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$SPARKLE/Autoupdate"
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$SPARKLE/Updater.app"
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP/Contents/Frameworks/Sparkle.framework"
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" \
    --identifier "$BUNDLE_ID.channel" "$APP/Contents/MacOS/assistant-channel"
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" \
    --identifier "$BUNDLE_ID" --entitlements "$ROOT/Resources/NotchAssistant.entitlements" "$APP"
  SIGNED=yes
fi

STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
{
  echo "$APP_NAME is a voice in the notch that runs your Claude Code agents."
  echo
  echo "You need"
  echo "  - an Apple Silicon Mac on macOS 26 or later"
  echo "  - Claude Code, installed and signed in"
  echo "  - for the live voice, your own OpenAI API key that can use gpt-live-1"
  echo "  - or no key at all: pick \"On this Mac\" during setup and install the"
  echo "    open Sophon model it points you to (16 GB of memory or more)"
  echo "  - or no voice at all: pick \"Text\" during setup. It needs neither"
  echo
  echo "Install"
  echo "  1. Drag $APP_NAME onto Applications."
  if [[ "$SIGNED" == yes && -n "${NOTARY_PROFILE:-}" ]]; then
    echo "  2. Open it. Setup starts by itself and walks you through the rest."
  else
    echo "  2. This build is not signed with Apple yet, so macOS will not open it"
    echo "     by double-click the first time. Open Terminal and run:"
    echo
    echo "       xattr -dr com.apple.quarantine \"/Applications/$APP_NAME.app\" && open \"/Applications/$APP_NAME.app\""
    echo
    echo "  3. Setup starts by itself and walks you through the rest."
  fi
  echo
  echo "After that, say its name (Jarvis, unless you changed it) and talk. Setup and Quit are under the eyes icon"
  echo "in the menu bar."
} > "$STAGE/Read me.txt"

mkdir -p "$DIST"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "${STAGE:?}"

if [[ "$SIGNED" == yes && -n "${NOTARY_PROFILE:-}" ]]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  echo "signed and notarized"
elif [[ "$SIGNED" == yes ]]; then
  echo "signed, not notarized: set NOTARY_PROFILE to finish the job"
else
  echo "not signed with Apple: the read-me in the image tells people how to open it"
fi
echo "made $DMG"
