#!/bin/zsh
# Scene-scripted screenshot generator (spec: site-dark-mode).
#
#   scripts/screenshots/generate.sh <scene|all> [--appearance light|dark|both] [--lang <code>]
#
# Replays committed scenes against dist/PullMark.app in demo mode and
# captures the main window — the replacement for hand-driven capture
# sessions. Build first: `make app`. See README.md for the runbook,
# including the mandatory cleanup (`make unregister-dist`).

set -euo pipefail
cd "$(dirname "$0")/../.."

APP=dist/PullMark.app/Contents/MacOS/PullMark
DRIVE=scripts/drive
OUT=scripts/screenshots/out
SCENES_ALL=(doc notes pr diff blame edit remote themes)

[[ -x $APP ]] || { echo "error: dist/PullMark.app missing — run 'make app' first" >&2; exit 1; }

scene=${1:-}; shift || true
appearance=light
lang=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --appearance) appearance=$2; shift 2 ;;
    --lang) lang=$2; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ -n $scene ]] || { echo "usage: generate.sh <scene|all> [--appearance light|dark|both] [--lang <code>]" >&2; exit 2; }

case $appearance in
  light|dark) appearances=($appearance) ;;
  both) appearances=(light dark) ;;
  *) echo "error: --appearance must be light, dark, or both" >&2; exit 2 ;;
esac
if [[ $scene == all ]]; then scenes=($SCENES_ALL); else scenes=($scene); fi

source scripts/screenshots/scenes.sh
mkdir -p $OUT

APP_PID=""
failures=0

launch() { # $1 = appearance
  # Published screenshots wear the classic Mac BLUE accent (Josh's
  # standing rule) — forced via the argument domain so captures are
  # machine-independent. These flags only survive because the launch
  # is BARE (see below): a document argument at launch makes Launch
  # Services respawn the app and silently drop the argument domain,
  # which is how a green-accent generation of captures once escaped.
  local flags=(-AppleAccentColor 4 -AppleHighlightColor "0.698039 0.843137 1.000000 Blue"
               -pm.appearance $1)
  [[ -n $lang ]] && flags+=(-AppleLanguages "($lang)")
  # Launch BARE (no document argument): opening a document at launch
  # makes Launch Services respawn the process, which keeps the
  # environment but silently drops the argument domain — the
  # appearance flag never applied that way. The demo Location is
  # handed to the running instance afterwards instead.
  PM_DEMO=1 $APP $flags &
  APP_PID=$!
  CAPTURE_ID=""
  for _ in {1..50}; do
    swift $DRIVE/winid.swift $APP_PID >/dev/null 2>&1 && break
    sleep 0.2
  done
  open -a "$PWD/dist/PullMark.app" ~/Code/meridian-docs
  sleep 2
  swift $DRIVE/winframe.swift $APP_PID 1052 784 >/dev/null
  sleep 1
}

capture() { # $1 = output basename (no extension)
  local id
  id=${CAPTURE_ID:-$(swift $DRIVE/winid.swift $APP_PID | head -1)}
  screencapture -x -o -l $id "$OUT/$1.png"
  echo "captured $OUT/$1.png"
}

quit_app() {
  swift $DRIVE/ax.swift $APP_PID menu PullMark "Quit PullMark" >/dev/null 2>&1 || kill $APP_PID 2>/dev/null || true
  for _ in {1..25}; do kill -0 $APP_PID 2>/dev/null || break; sleep 0.2; done
  kill -0 $APP_PID 2>/dev/null && kill -9 $APP_PID 2>/dev/null || true
  APP_PID=""
}
trap 'if [[ -n "$APP_PID" ]]; then kill "$APP_PID" 2>/dev/null || true; fi' EXIT

for mode in $appearances; do
  for name in $scenes; do
    suffix=""
    [[ $mode == dark ]] && suffix="-dark"
    [[ -n $lang ]] && suffix="$suffix-$lang"
    echo "── scene $name ($mode${lang:+, $lang})"
    launch $mode
    if scene_$name; then
      capture "app-$name$suffix"
    else
      echo "scene $name FAILED — skipping capture" >&2
      failures=$((failures + 1))
    fi
    quit_app
  done
done
if (( failures > 0 )); then
  echo "done with $failures FAILED scene(s) — fix and rerun those." >&2
  exit 1
fi
echo "done — review the results in $OUT before promoting to site/img."
