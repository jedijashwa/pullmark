#!/bin/bash
# Post-release verification: every mechanical check the release runbook
# runs after make-release.sh, in one pass. Prints a PASS/FAIL table and
# exits nonzero if anything failed. Judgment stays with the operator:
# screenshot-surface review and failure recovery are NOT here.
#
#   ./scripts/verify-release.sh 0.43.0
#
# Never installs anything: the cask artifact is fetched and inspected in
# a scratch directory, unregistered from Launch Services, and deleted.
# /Applications/PullMark.app is read, never touched.
set -uo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: verify-release.sh <version>}"
TAG="v${VERSION}"
REPO="jedijashwa/pullmark"
TAP="jedijashwa/homebrew-tap"

SCRATCH=$(mktemp -d)
EXTRACTED=""
cleanup() {
  if [ -n "$EXTRACTED" ] && [ -d "$EXTRACTED" ]; then
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
      -u "$EXTRACTED" >/dev/null 2>&1 || true
  fi
  rm -rf "$SCRATCH"
}
trap cleanup EXIT

FAILURES=0
declare -a REPORT=()
check() {  # check <name> <ok:0|1> <detail>
  local mark="PASS"
  if [ "$2" != 0 ]; then mark="FAIL"; FAILURES=$((FAILURES + 1)); fi
  REPORT+=("$(printf '%-4s %-22s %s' "$mark" "$1" "$3")")
}

# ---- Tag: local, remote, and the release's target must be one commit,
# and that commit must be the changelog cut (the make-release.sh
# ordering fix asserts this holds on every release from 0.43.0 on).
LOCAL_SHA=$(git rev-parse "${TAG}^{commit}" 2>/dev/null || echo "MISSING")
REMOTE_SHA=$(git ls-remote --tags origin "$TAG" | awk '{print $1}')
REMOTE_SHA=${REMOTE_SHA:-MISSING}
RELEASE_JSON=$(gh api "repos/${REPO}/releases/tags/${TAG}" 2>/dev/null || echo "{}")
TARGET_SHA=$(printf '%s' "$RELEASE_JSON" | jq -r '.target_commitish // "MISSING"')
[ "$LOCAL_SHA" = "$REMOTE_SHA" ] && [ "$LOCAL_SHA" = "$TARGET_SHA" ] && [ "$LOCAL_SHA" != "MISSING" ]
check "tag-consistency" $? "local=$LOCAL_SHA remote=$REMOTE_SHA target=$TARGET_SHA"

SUBJECT=$(git log -1 --format=%s "$LOCAL_SHA" 2>/dev/null || echo "")
[ "$SUBJECT" = "Changelog: cut ${VERSION}" ]
check "tag-on-changelog-cut" $? "tag commit: \"$SUBJECT\""

# ---- Release state and assets.
DRAFT=$(printf '%s' "$RELEASE_JSON" | jq -r '.draft')
PRE=$(printf '%s' "$RELEASE_JSON" | jq -r '.prerelease')
[ "$DRAFT" = "false" ] && [ "$PRE" = "false" ]
check "release-published" $? "draft=$DRAFT prerelease=$PRE"

LATEST=$(gh api "repos/${REPO}/releases/latest" --jq '.tag_name')
[ "$LATEST" = "$TAG" ]
check "release-is-latest" $? "latest=$LATEST"

ASSETS=$(printf '%s' "$RELEASE_JSON" | jq -r '.assets[].name' | sort | tr '\n' ' ')
[ "$ASSETS" = "PullMark-${VERSION}.dmg PullMark-${VERSION}.zip PullMark.dmg " ]
check "assets" $? "$ASSETS"

STABLE_CODE=$(curl -sIL -o /dev/null -w '%{http_code}' \
  "https://github.com/${REPO}/releases/latest/download/PullMark.dmg")
[ "$STABLE_CODE" = "200" ]
check "stable-download-url" $? "HTTP $STABLE_CODE"

# ---- Release notes must be the changelog section, byte-for-byte
# modulo trailing whitespace.
gh release view "$TAG" --json body --jq .body | sed -e 's/[[:space:]]*$//' \
  > "$SCRATCH/notes-published"
./scripts/make-release.sh --print-notes "$VERSION" | sed -e 's/[[:space:]]*$//' \
  > "$SCRATCH/notes-changelog"
# The changelog section ends with blank separator lines the release drops.
diff <(sed -e :a -e '/^\s*$/{$d;N;ba' -e '}' "$SCRATCH/notes-published") \
     <(sed -e :a -e '/^\s*$/{$d;N;ba' -e '}' "$SCRATCH/notes-changelog") >/dev/null
check "notes-match-changelog" $? "gh release body == CHANGELOG section"

# ---- Cask: version and sha, then the artifact itself via brew's own
# fetch path (tap-scoped pull, no global brew update).
CASK=$(gh api "repos/${TAP}/contents/Casks/pullmark.rb" --jq '.content' | base64 -d)
CASK_VERSION=$(printf '%s' "$CASK" | awk -F'"' '/^  version /{print $2}')
CASK_SHA=$(printf '%s' "$CASK" | awk -F'"' '/^  sha256 /{print $2}')
[ "$CASK_VERSION" = "$VERSION" ]
check "cask-version" $? "tap says $CASK_VERSION"

TAP_DIR=$(brew --repository "$TAP" 2>/dev/null)
if [ -d "$TAP_DIR" ]; then git -C "$TAP_DIR" pull -q 2>/dev/null; fi
# brew's summary output doesn't name the file — ask the cache directly.
brew fetch --cask pullmark --force >/dev/null 2>&1
FETCHED=$(brew --cache --cask pullmark 2>/dev/null)
if [ -f "$FETCHED" ]; then
  ZIP_SHA=$(shasum -a 256 "$FETCHED" | awk '{print $1}')
  [ "$ZIP_SHA" = "$CASK_SHA" ]
  check "cask-sha" $? "fetched zip sha == cask sha ($ZIP_SHA)"
  ditto -xk "$FETCHED" "$SCRATCH/app" 2>/dev/null
  EXTRACTED="$SCRATCH/app/PullMark.app"
  BUNDLE_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
    "$EXTRACTED/Contents/Info.plist" 2>/dev/null || echo "MISSING")
  [ "$BUNDLE_VERSION" = "$VERSION" ]
  check "bundle-version" $? "CFBundleShortVersionString=$BUNDLE_VERSION"
  SPCTL=$(spctl -a -vv "$EXTRACTED" 2>&1)
  printf '%s' "$SPCTL" | grep -q "Notarized Developer ID"
  check "app-notarized" $? "$(printf '%s' "$SPCTL" | tr '\n' ' ' | cut -c1-80)"
  xcrun stapler validate "$EXTRACTED" >/dev/null 2>&1
  check "app-stapled" $? "stapler validate (app)"
  # The Gatekeeper assessment registers the extracted copy with Launch
  # Services — unregister and delete it NOW, before the stray sweep,
  # or the verification pollutes its own registration check.
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -u "$EXTRACTED" >/dev/null 2>&1 || true
  rm -rf "$SCRATCH/app"
  EXTRACTED=""
else
  check "cask-sha" 1 "brew fetch produced no file"
fi

# ---- The DMG is a separate notarization — validate its staple too.
gh release download "$TAG" -p "PullMark-${VERSION}.dmg" -D "$SCRATCH" 2>/dev/null
xcrun stapler validate "$SCRATCH/PullMark-${VERSION}.dmg" >/dev/null 2>&1
check "dmg-stapled" $? "stapler validate (dmg)"

# ---- Local hygiene: Josh's app untouched (report only), no stray
# Launch Services registrations, tree clean and level with origin.
INSTALLED=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
  "/Applications/PullMark.app/Contents/Info.plist" 2>/dev/null || echo "none")
check "installed-app" 0 "/Applications is $INSTALLED (read-only; in-app updater is Josh's)"

STRAYS=$(/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -dump 2>/dev/null | grep -o "path:.*PullMark.app" | awk '{print $2}' | sort -u \
  | grep -v "^/Applications/PullMark.app$" || true)
[ -z "$STRAYS" ]
check "ls-registrations" $? "${STRAYS:-only /Applications registered}"

git fetch -q origin main
[ -z "$(git status --porcelain)" ] && [ "$(git rev-parse main)" = "$(git rev-parse origin/main)" ]
check "git-clean" $? "tree clean, main == origin/main"

echo
printf '%s\n' "${REPORT[@]}"
echo
if [ "$FAILURES" = 0 ]; then
  echo "verify-release: all checks passed for ${TAG}"
else
  echo "verify-release: ${FAILURES} check(s) FAILED for ${TAG}"
  exit 1
fi
