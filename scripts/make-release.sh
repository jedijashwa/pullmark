#!/bin/bash
# Cuts a signed, notarized release and updates the Homebrew cask.
#
#   ./scripts/make-release.sh 0.1.2
#   ./scripts/make-release.sh --beta 0.28.0-beta.1
#   ./scripts/make-release.sh --print-notes 0.1.1   # dry run: print a version's notes
#
# Release notes come from the "## <version>" section of CHANGELOG.md. If that
# section doesn't exist yet, "## Unreleased" is renamed to it (dated today) and
# committed first, so the notes that shipped stay reproducible from history.
# The release FAILS if no non-empty notes section can be found. (Promoting a
# beta line to stable after its notes were cut as "## X.Y.Z-beta.N" sections:
# write the combined "## X.Y.Z" section by hand first.)
#
# --beta marks the GitHub release as a prerelease (so `releases/latest` — the
# stable channel — never sees it), regenerates only the pullmark@beta cask,
# and leaves the website's versionless PullMark.dmg untouched. Stable
# releases update BOTH casks, so beta installs converge on the next stable.
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

# Writes the pullmark@beta cask (whole file — deterministic, no sed drift).
write_beta_cask() {
  local path="$1" version="$2" sha="$3"
  cat > "$path" <<CASK
cask "pullmark@beta" do
  version "${version}"
  sha256 "${sha}"

  url "https://github.com/jedijashwa/pullmark/releases/download/v#{version}/PullMark-#{version}.zip"
  name "PullMark Beta"
  desc "Markdown viewer and rendered-diff reviewer for documentation-heavy GitHub PRs (beta channel)"
  homepage "https://github.com/jedijashwa/pullmark"

  depends_on macos: ">= :ventura"
  conflicts_with cask: "pullmark"

  app "PullMark.app"
  # The pullmark shell command ships inside the bundle (0.25.0+).
  binary "#{appdir}/PullMark.app/Contents/Resources/pullmark"

  # Re-register the app and its Quick Look extension after every install and
  # upgrade: the delete-and-replace swap can drop the pluginkit registration,
  # leaving space-bar previews showing raw text until the app is launched.
  postflight do
    system_command "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
                   args: ["-f", "#{appdir}/PullMark.app"]
    system_command "/usr/bin/pluginkit",
                   args: ["-a", "#{appdir}/PullMark.app/Contents/PlugIns/PullMarkQuickLook.appex"]
  end

  zap trash: "~/Library/Preferences/app.pullmark.PullMark.plist"
end
CASK
}

if [ "${1:-}" = "--print-notes" ]; then
  extract_notes "${2:?usage: make-release.sh --print-notes <version>}"
  exit 0
fi

BETA=0
if [ "${1:-}" = "--beta" ]; then
  BETA=1
  shift
fi

VERSION="${1:?usage: make-release.sh [--beta] <version>}"
IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Josh Riesenbach (35F47G5Y6D)}"
PROFILE="${NOTARY_PROFILE:-pullmark-notary}"
TAP="${TAP_REPO:-jedijashwa/homebrew-tap}"

if [ "$BETA" = 1 ] && ! [[ "$VERSION" == *-* ]]; then
  echo "error: --beta releases need a prerelease version (e.g. 0.28.0-beta.1)" >&2
  exit 1
fi
if [ "$BETA" = 0 ] && [[ "$VERSION" == *-* ]]; then
  echo "error: ${VERSION} is a prerelease version — pass --beta" >&2
  exit 1
fi

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

RELEASE_ASSETS=("$ZIP" "$DMG")
FLAGS=()
if [ "$BETA" = 1 ]; then
  FLAGS+=(--prerelease)
else
  # The website's Download button points at the version-less asset name, which
  # is the only way to get a stable releases/latest/download URL. Same bytes,
  # uploaded under both names. Betas never touch it.
  STABLE_DMG="dist/PullMark.dmg"
  cp -f "$DMG" "$STABLE_DMG"
  RELEASE_ASSETS+=("$STABLE_DMG")
fi

echo "==> Creating GitHub release v${VERSION}"
gh release create "v${VERSION}" "${RELEASE_ASSETS[@]}" --title "PullMark ${VERSION}" \
  --notes "$NOTES" "${FLAGS[@]}"

echo "==> Updating cask(s) in ${TAP}"
TAP_DIR=$(mktemp -d)
gh repo clone "$TAP" "$TAP_DIR" -- -q
if [ "$BETA" = 0 ]; then
  sed -i '' -e "s/version \".*\"/version \"${VERSION}\"/" \
            -e "s/sha256 \".*\"/sha256 \"${SHA}\"/" "$TAP_DIR/Casks/pullmark.rb"
fi
# The beta cask always points at the newest release of either kind, so beta
# installs pick up stable promotions through plain `brew upgrade`.
write_beta_cask "$TAP_DIR/Casks/pullmark@beta.rb" "$VERSION" "$SHA"
git -C "$TAP_DIR" add -A
git -C "$TAP_DIR" commit -qm "pullmark ${VERSION}

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
git -C "$TAP_DIR" push -q
rm -rf "$TAP_DIR"

echo "==> Released v${VERSION} (sha256 ${SHA})"
if [ "$BETA" = 1 ]; then
  echo "    Beta users update with: brew upgrade --cask pullmark@beta"
else
  echo "    Users update with: brew upgrade --cask pullmark"
fi
