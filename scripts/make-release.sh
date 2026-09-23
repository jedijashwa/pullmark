#!/bin/bash
# Cuts a signed, notarized release and updates the Homebrew cask.
#
#   ./scripts/make-release.sh "$(./scripts/make-release.sh --next-version)"
#   ./scripts/make-release.sh 2026.9.1
#   ./scripts/make-release.sh --next-version        # print the next version
#   ./scripts/make-release.sh --check-version 2026.9.1  # run only the version guards
#   ./scripts/make-release.sh --print-notes 0.45.1  # dry run: print a version's notes
#
# Versions are year.month.count from 2026.9.1 on (0.x semver before it): the
# year, the month, and which release of that month this is, counting from 1.
# --next-version derives it from today's date and the tags on origin; the
# release itself always takes the version explicitly, so a re-run after a
# partial failure ships the SAME version instead of counting up again.
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

# The next year.month.count for today: one more than the releases this month
# so far — the highest count among this month's year.month.count tags, or
# the number of release tags of ANY scheme dated this month, whichever is
# larger (the month the scheme started, September 2026, counts 0.45.0 and
# 0.45.1, so its first date version is 2026.9.3). Release tags are
# lightweight and sit on the changelog-cut commit, whose date is the
# release day.
next_version() {
  local prefix="$(date +%Y).$((10#$(date +%m)))"
  local month="$(date +%Y-%m)"
  git fetch -q --tags origin 2>/dev/null || true
  local last dated
  last=$(git tag -l "v${prefix}.*" \
         | sed -n "s/^v${prefix//./\\.}\.\([1-9][0-9]*\)\$/\1/p" | sort -n | tail -1)
  dated=$(git for-each-ref --format='%(creatordate:format:%Y-%m)' 'refs/tags/v*' | grep -c "^${month}\$" || true)
  last=${last:-0}
  (( dated > last )) && last=$dated
  echo "${prefix}.$(( last + 1 ))"
}

# Refuses anything but the next year.month.count: well-formed, exactly
# --next-version (or already cut in the changelog — a re-run that straddles
# midnight at a month's end), not yet tagged, and newer than every release
# so far. Runs before anything is touched.
validate_version() {
  local version="$1"
  if [[ "$version" == *-* ]]; then
    echo "error: ${version} looks like a prerelease — the beta channel is retired; releases are stable-only" >&2
    return 1
  fi
  if ! [[ "$version" =~ ^20[0-9]{2}\.([1-9]|1[0-2])\.[1-9][0-9]*$ ]]; then
    echo "error: ${version} isn't year.month.count (no zero padding) — the next one is $(next_version)" >&2
    return 1
  fi
  local next
  next=$(next_version)
  if [ "$version" != "$next" ] && ! grep -qE "^## ${version}([[:space:]]|\$)" "$CHANGELOG"; then
    echo "error: ${version} isn't the next release — that's ${next} (this month's next count)" >&2
    return 1
  fi
  if [ -n "$(git ls-remote --tags origin "refs/tags/v${version}")" ]; then
    echo "error: v${version} is already released — the next one is $(next_version)" >&2
    return 1
  fi
  local latest
  latest=$(git ls-remote --tags origin 'v*' | sed -n 's#.*refs/tags/v\([0-9.]*\)$#\1#p' | sort -V | tail -1)
  if [ -n "$latest" ] && [ "$(printf '%s\n%s\n' "$latest" "$version" | sort -V | tail -1)" != "$version" ]; then
    echo "error: ${version} isn't newer than the latest release (${latest}) — the next one is $(next_version)" >&2
    return 1
  fi
}

if [ "${1:-}" = "--next-version" ]; then
  next_version
  exit 0
fi

if [ "${1:-}" = "--check-version" ]; then
  validate_version "${2:?usage: make-release.sh --check-version <version>}"
  echo "${2} is a valid next release"
  exit 0
fi

if [ "${1:-}" = "--print-notes" ]; then
  extract_notes "${2:?usage: make-release.sh --print-notes <version>}"
  exit 0
fi

VERSION="${1:?usage: make-release.sh <version>}"
IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Josh Riesenbach (35F47G5Y6D)}"
PROFILE="${NOTARY_PROFILE:-pullmark-notary}"
TAP="${TAP_REPO:-jedijashwa/homebrew-tap}"

validate_version "$VERSION" || exit 1

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

# gh release create tags whatever the REMOTE default branch points at, not
# local HEAD — without this push, a changelog cut committed above (or any
# unpushed work) is left out of the tag, which is exactly what happened to
# v0.40.0 through v0.42.0. Push first, then pin the tag to the pushed sha
# so a concurrent push can't shift it either.
echo "==> Pushing main so the tag lands on the release commit"
git push origin HEAD

echo "==> Creating GitHub release v${VERSION}"
gh release create "v${VERSION}" "$ZIP" "$DMG" "$STABLE_DMG" --title "PullMark ${VERSION}" \
  --target "$(git rev-parse HEAD)" --notes "$NOTES"

echo "==> Updating cask in ${TAP}"
TAP_DIR=$(mktemp -d)
gh repo clone "$TAP" "$TAP_DIR" -- -q
sed -i '' -e "s/version \".*\"/version \"${VERSION}\"/" \
          -e "s/sha256 \".*\"/sha256 \"${SHA}\"/" "$TAP_DIR/Casks/pullmark.rb"
git -C "$TAP_DIR" commit -qam "pullmark ${VERSION}

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
git -C "$TAP_DIR" push -q
rm -rf "$TAP_DIR"

# gh created the tag on the REMOTE only; carry it into this checkout so
# verify-release.sh's tag checks see it without a manual fetch.
git fetch -q origin "refs/tags/v${VERSION}:refs/tags/v${VERSION}"

# Gatekeeper assessments REGISTER what they assess with Launch Services
# (the spctl above on dist/, and the DMG verification inside its mount)
# — scrub both so the dev copies never steal bindings from
# /Applications and the post-release stray sweep starts clean.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -u "$(pwd)/dist/PullMark.app" >/dev/null 2>&1 || true
"$LSREGISTER" -u /Volumes/PullMark/PullMark.app >/dev/null 2>&1 || true

echo "==> Released v${VERSION} (sha256 ${SHA})"
echo "    Users update with: brew upgrade --cask pullmark"
