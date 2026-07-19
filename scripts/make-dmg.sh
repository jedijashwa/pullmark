#!/bin/bash
# Builds a signed, notarized, stapled drag-to-install DMG from dist/PullMark.app.
#
#   ./scripts/make-dmg.sh 0.4.0    ->  dist/PullMark-0.4.0.dmg
#
# The app in dist/ must already be the release build (Developer ID signed and
# notarized — make-release.sh staples it before calling this). The DMG itself
# is codesigned, notarized (which also covers the enclosed app), and stapled.
#
# Prerequisites: same as make-release.sh (Developer ID identity in the login
# keychain, notarytool keychain profile "pullmark-notary").
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: make-dmg.sh <version>}"
IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Josh Riesenbach (35F47G5Y6D)}"
PROFILE="${NOTARY_PROFILE:-pullmark-notary}"
VOLNAME="PullMark"
APP="dist/PullMark.app"
DMG="dist/PullMark-${VERSION}.dmg"

if [ ! -d "$APP" ]; then
  echo "error: $APP not found — build the release app first (make-app.sh)" >&2
  exit 1
fi

STAGING="$(mktemp -d -t pullmark-dmg)"
RW_DMG="$(mktemp -t pullmark-dmg).dmg"
MOUNT_POINT=""
cleanup() {
  [ -n "$MOUNT_POINT" ] && hdiutil detach "$MOUNT_POINT" -force >/dev/null 2>&1 || true
  rm -rf "$STAGING" "$RW_DMG"
}
trap cleanup EXIT

echo "==> Staging DMG contents"
cp -R "$APP" "$STAGING/PullMark.app"
ln -s /Applications "$STAGING/Applications"
mkdir "$STAGING/.background"
cp assets/dmg-background.png "$STAGING/.background/background.png"

echo "==> Creating read-write image"
rm -f "$RW_DMG"
hdiutil create -srcfolder "$STAGING" -volname "$VOLNAME" -fs HFS+ \
  -format UDRW -size 200m "$RW_DMG" >/dev/null

echo "==> Mounting and applying Finder layout"
ATTACH_OUT="$(hdiutil attach -readwrite -noverify -noautoopen "$RW_DMG")"
MOUNT_POINT="$(printf '%s\n' "$ATTACH_OUT" | awk -F'\t' '/\/Volumes\//{print $NF; exit}')"
[ -d "$MOUNT_POINT" ] || { echo "error: failed to mount $RW_DMG" >&2; exit 1; }

osascript <<EOF
tell application "Finder"
  tell disk "$VOLNAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 548}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 100
    set text size of opts to 13
    set background picture of opts to file ".background:background.png"
    set position of item "PullMark.app" of container window to {165, 200}
    set position of item "Applications" of container window to {495, 200}
    close
    open
    update without registering applications
    delay 2
    close
  end tell
end tell
EOF
sync

hdiutil detach "$MOUNT_POINT" >/dev/null
MOUNT_POINT=""

echo "==> Converting to compressed read-only image"
rm -f "$DMG"
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null

echo "==> Signing $DMG"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"

echo "==> Notarizing $DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait \
  | tee /tmp/pullmark-dmg-notary.log
grep -q "status: Accepted" /tmp/pullmark-dmg-notary.log \
  || { echo "DMG notarization not accepted"; exit 1; }
xcrun stapler staple "$DMG"
spctl -a -t open --context context:primary-signature -vv "$DMG"

echo "Built $DMG"
