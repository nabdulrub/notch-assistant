#!/bin/bash
# Builds a release: the disk image, signed for the updater, and the feed that
# tells every installed copy it is out. Nothing is uploaded; the last line
# printed is the command that publishes it.
#
# Every copy of the app only installs an update signed with the private half
# of Resources/update-key.pub. That half lives in the login keychain of the Mac
# releases are made on (account "notch-assistant", put there by Sparkle's
# generate_keys). Keep a copy somewhere safe:
#   .build/artifacts/sparkle/Sparkle/bin/generate_keys --account notch-assistant -x private-key-file
# Without it no update can be signed, and copies already installed will never
# accept one signed with another key.
#
# The first time, macOS asks whether sign_update may use the key: say Always
# Allow. Somewhere with no keychain, KEY_FILE points at the exported key instead.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="${APP_NAME:-Notch Assistant}"
REPO="${REPO:-nabdulrub/notch-assistant}"
KEY_ACCOUNT="${KEY_ACCOUNT:-notch-assistant}"
VERSION="${VERSION:-$(tr -d '[:space:]' < "$ROOT/VERSION")}"
DIST="$ROOT/dist"
DMG="$DIST/${APP_NAME// /}-$VERSION.dmg"
# Where the disk image will be once the release is published.
DOWNLOAD_URL="${DOWNLOAD_URL:-https://github.com/$REPO/releases/download/v$VERSION/$(basename "$DMG")}"

cd "$ROOT"
# Versions are compared by how many commits a build is made from. That number
# only means something on main, so a release is built there.
BRANCH="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)"
if [[ "$BRANCH" != main && -z "${ANY_BRANCH:-}" ]]; then
  echo "releases are built from main, and this is $BRANCH. Set ANY_BRANCH=1 to build one anyway." >&2
  exit 1
fi
VERSION="$VERSION" APP_NAME="$APP_NAME" "$ROOT/scripts/dist.sh"

SIGN_UPDATE="$ROOT/.build/artifacts/sparkle/Sparkle/bin/sign_update"
[[ -x "$SIGN_UPDATE" ]] || { echo "Sparkle's sign_update is missing; run swift build first" >&2; exit 1; }
KEY=(--account "$KEY_ACCOUNT")
[[ -n "${KEY_FILE:-}" ]] && KEY=(--ed-key-file "$KEY_FILE")
SIGNED="$("$SIGN_UPDATE" "${KEY[@]}" "$DMG")"

APP="$ROOT/build/$APP_NAME.app"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
"$APP/Contents/MacOS/Assistant" --appcast --name "$APP_NAME" --version "$VERSION" --build "$BUILD_NUMBER" \
  --url "$DOWNLOAD_URL" --signed "$SIGNED" > "$DIST/appcast.xml"

# The key the image was just signed with has to be the one the app carries.
"$SIGN_UPDATE" "${KEY[@]}" --verify "$DMG" "$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' <<< "$SIGNED")" >/dev/null \
  || { echo "the signature does not check out against the key it was made with" >&2; exit 1; }

echo "made $DIST/appcast.xml for $VERSION (build $BUILD_NUMBER)"
echo "to publish:"
echo "  gh release create v$VERSION --repo $REPO --title \"$APP_NAME $VERSION\" --generate-notes \"$DMG\" \"$DIST/appcast.xml\""
