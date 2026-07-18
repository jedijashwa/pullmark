#!/bin/bash
# Cuts a signed, notarized release and updates the Homebrew cask.
#
#   ./scripts/make-release.sh 0.1.2
#
# Prerequisites (already configured on the release machine):
#   - "Developer ID Application" identity in the login keychain
#   - notarytool keychain profile named "pullmark-notary"
#   - gh authenticated with repo + workflow scopes
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: make-release.sh <version>}"
IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Josh Riesenbach (35F47G5Y6D)}"
PROFILE="${NOTARY_PROFILE:-pullmark-notary}"
TAP="${TAP_REPO:-jedijashwa/homebrew-tap}"

echo "==> Building ${VERSION} signed as ${IDENTITY}"
VERSION="$VERSION" SIGN_IDENTITY="$IDENTITY" ./scripts/make-app.sh

echo "==> Notarizing"
ZIP="/tmp/PullMark-${VERSION}.zip"
ditto -c -k --keepParent dist/PullMark.app "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait | tee /tmp/pullmark-notary.log
grep -q "status: Accepted" /tmp/pullmark-notary.log || { echo "Notarization not accepted"; exit 1; }
xcrun stapler staple dist/PullMark.app
spctl -a -vv dist/PullMark.app

echo "==> Re-zipping stapled app and creating GitHub release v${VERSION}"
ditto -c -k --keepParent dist/PullMark.app "$ZIP"
SHA=$(shasum -a 256 "$ZIP" | awk '{print $1}')
gh release create "v${VERSION}" "$ZIP" --title "PullMark ${VERSION}" \
  --notes "Signed with Developer ID and notarized by Apple."

echo "==> Updating cask in ${TAP}"
TAP_DIR=$(mktemp -d)
gh repo clone "$TAP" "$TAP_DIR" -- -q
sed -i '' -e "s/version \".*\"/version \"${VERSION}\"/" \
          -e "s/sha256 \".*\"/sha256 \"${SHA}\"/" "$TAP_DIR/Casks/pullmark.rb"
git -C "$TAP_DIR" commit -qam "pullmark ${VERSION}

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
git -C "$TAP_DIR" push -q
rm -rf "$TAP_DIR"

echo "==> Released v${VERSION} (sha256 ${SHA})"
echo "    Users update with: brew upgrade --cask pullmark"
