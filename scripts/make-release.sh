#!/bin/bash
# Cuts a signed, notarized release and updates the Homebrew cask.
#
#   ./scripts/make-release.sh 0.1.2
#   ./scripts/make-release.sh --print-notes 0.1.1   # dry run: print a version's notes
#
# Release notes come from the "## <version>" section of CHANGELOG.md. If that
# section doesn't exist yet, "## Unreleased" is renamed to it (dated today) and
# committed first, so the notes that shipped stay reproducible from history.
# The release FAILS if no non-empty notes section can be found.
#
# Prerequisites (already configured on the release machine):
#   - "Developer ID Application" identity in the login keychain
#   - notarytool keychain profile named "pullmark-notary"
#   - gh authenticated with repo + workflow scopes
set -euo pipefail
cd "$(dirname "$0")/.."

CHANGELOG="CHANGELOG.md"

# Prints the body of the "## <version>" (or "## Unreleased") section of
# CHANGELOG.md; empty output if the section is missing.
extract_notes() {
  awk -v ver="$1" '
    /^## / { if (found) exit; found = ($2 == ver); next }
    found { print }
  ' "$CHANGELOG"
}

if [ "${1:-}" = "--print-notes" ]; then
  extract_notes "${2:?usage: make-release.sh --print-notes <version>}"
  exit 0
fi

VERSION="${1:?usage: make-release.sh <version>}"
IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Josh Riesenbach (35F47G5Y6D)}"
PROFILE="${NOTARY_PROFILE:-pullmark-notary}"
TAP="${TAP_REPO:-jedijashwa/homebrew-tap}"

# No explicit section for this version yet: promote "## Unreleased" and commit
# so the released notes are pinned in history.
if ! grep -qE "^## ${VERSION}([[:space:]]|\$)" "$CHANGELOG"; then
  if ! grep -q '^## Unreleased' "$CHANGELOG"; then
    echo "error: ${CHANGELOG} has neither a '## ${VERSION}' nor an '## Unreleased' section" >&2
    exit 1
  fi
  echo "==> Promoting '## Unreleased' to '## ${VERSION}' in ${CHANGELOG}"
  sed -i '' "s/^## Unreleased.*/## ${VERSION} - $(date +%Y-%m-%d)/" "$CHANGELOG"
  git add "$CHANGELOG"
  git commit -m "Changelog: cut ${VERSION}

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
fi

NOTES="$(extract_notes "$VERSION")"
if [ -z "$(printf '%s' "$NOTES" | tr -d '[:space:]')" ]; then
  echo "error: no release notes for ${VERSION} in ${CHANGELOG} — fill in its section before releasing" >&2
  exit 1
fi

echo "==> Building ${VERSION} signed as ${IDENTITY}"
VERSION="$VERSION" SIGN_IDENTITY="$IDENTITY" ./scripts/make-app.sh

echo "==> Notarizing"
ZIP="/tmp/PullMark-${VERSION}.zip"
ditto -c -k --keepParent dist/PullMark.app "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait | tee /tmp/pullmark-notary.log
grep -q "status: Accepted" /tmp/pullmark-notary.log || { echo "Notarization not accepted"; exit 1; }
xcrun stapler staple dist/PullMark.app
spctl -a -vv dist/PullMark.app

echo "==> Re-zipping stapled app"
ditto -c -k --keepParent dist/PullMark.app "$ZIP"
SHA=$(shasum -a 256 "$ZIP" | awk '{print $1}')

echo "==> Building drag-to-install DMG"
SIGN_IDENTITY="$IDENTITY" NOTARY_PROFILE="$PROFILE" ./scripts/make-dmg.sh "$VERSION"
DMG="dist/PullMark-${VERSION}.dmg"

# The website's Download button points at the version-less asset name, which
# is the only way to get a stable releases/latest/download URL. Same bytes,
# uploaded under both names.
STABLE_DMG="dist/PullMark.dmg"
cp -f "$DMG" "$STABLE_DMG"

echo "==> Creating GitHub release v${VERSION}"
gh release create "v${VERSION}" "$ZIP" "$DMG" "$STABLE_DMG" --title "PullMark ${VERSION}" \
  --notes "$NOTES"

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
