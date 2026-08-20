#!/bin/zsh
# Scene-scripted screenshot generator (spec: site-dark-mode).
#
#   scripts/screenshots/generate.sh <scene|all> [--appearance light|dark|both] [--lang <code>|all]
#
# Replays committed scenes against dist/PullMark.app in demo mode and
# captures the main window — the replacement for hand-driven capture
# sessions. Build first: `make app`. See README.md for the runbook,
# including the mandatory cleanup (`make unregister-dist`).
#
# `all --appearance both --lang all` is the full site matrix: 8 scenes
# × light/dark × English + 7 locales. English lands in out/ (matching
# site/img/), localized captures in out/<site-code>/ (zh, ja, fr, de,
# nl, es, pt — matching site/img/<code>/), same basenames throughout.

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
[[ -n $scene ]] || { echo "usage: generate.sh <scene|all> [--appearance light|dark|both] [--lang <code>|all]" >&2; exit 2; }

case $appearance in
  light|dark) appearances=($appearance) ;;
  both) appearances=(light dark) ;;
  *) echo "error: --appearance must be light, dark, or both" >&2; exit 2 ;;
esac
if [[ $scene == all ]]; then scenes=($SCENES_ALL); else scenes=($scene); fi

# Empty string = English (no language override; keys ARE the English
# strings). The list mirrors loc/*.lproj.
if [[ $lang == all ]]; then
  langs=("" zh-Hans ja fr de nl es pt-BR)
else
  langs=("$lang")
fi

site_dir() { # locale code → site directory name ('' for English)
  case $1 in
    zh-Hans) echo zh ;; pt-BR) echo pt ;; *) echo $1 ;;
  esac
}

source scripts/screenshots/scenes.sh
mkdir -p $OUT

# Launch Services must know this bundle or document delivery (the demo
# Location via `open -a`) silently routes to Finder — and the standing
# cleanup rule unregisters dist after every trial, so register fresh
# per run and unregister again on exit.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -f "$PWD/dist/PullMark.app"
trap '"$LSREGISTER" -u "$PWD/dist/PullMark.app" >/dev/null 2>&1 || true; if [[ -n "$APP_PID" ]]; then kill "$APP_PID" 2>/dev/null || true; fi' EXIT

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
  if [[ -n $lang ]]; then
    # Language AND locale: language alone leaves US date/number formats.
    local region
    case $lang in
      ja) region=ja_JP ;; de) region=de_DE ;; fr) region=fr_FR ;;
      nl) region=nl_NL ;; es) region=es_ES ;; pt-BR) region=pt_BR ;;
      zh-Hans) region=zh_CN ;; *) region=en_US ;;
    esac
    flags+=(-AppleLanguages "($lang)" -AppleLocale "$region")
  fi
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
  sleep 1
  # Deliver the demo Location through the app's own Open panel with
  # pid-targeted keys (⌘O, ⇧⌘G, path, Return, Return) — NEVER
  # `open -a`: with two same-bundle-id copies alive (/Applications +
  # dist), Launch Services sometimes spawns a THIRD instance for the
  # document instead of delivering here, and the scene then captures
  # a folderless window. Keycodes and the panel flow are
  # language-independent.
  osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $APP_PID) to true" >/dev/null 2>&1 || true
  deliver_location
  set_sidebar visible   # location_present needs the headings on screen
  if ! location_present; then
    echo "launch: demo Location missing — retrying delivery" >&2
    deliver_location
    location_present || { echo "launch: demo Location never arrived" >&2; return 1; }
  fi
  swift $DRIVE/winframe.swift $APP_PID 1052 784 >/dev/null
  sleep 1
}

deliver_location() {
  swift $DRIVE/pkey.swift $APP_PID 31 cmd       # ⌘O Open…
  sleep 1.2
  swift $DRIVE/pkey.swift $APP_PID 5 cmd shift  # ⇧⌘G go-to-path bar
  sleep 0.8
  printf '%s' "$HOME/Code/meridian-docs" | pbcopy
  swift $DRIVE/pkey.swift $APP_PID 9 cmd        # paste path (live-navigates)
  sleep 0.5
  swift $DRIVE/pkey.swift $APP_PID 36           # Return — close the bar
  sleep 0.8
  # Plain Return never reaches the panel's bridged content — confirm
  # via the Open button's stable identifier instead.
  swift $DRIVE/ax.swift $APP_PID id OKButton >/dev/null 2>&1 || true
  sleep 2
}

# The folder Location is in place when the sidebar shows TWO plain
# meridian-docs headings (folder + demo remote repo; the closing quote
# in the pattern excludes the "meridian-docs #128" PR row). Folder
# names are fixture data, so this is locale-proof.
location_present() {
  for _ in {1..8}; do
    local count
    count=$(swift $DRIVE/ax.swift $APP_PID list 10 2>/dev/null \
      | grep -Fc 'AXHeading "meridian-docs"') || count=0
    (( count >= 2 )) && return 0
    sleep 0.8
  done
  return 1
}

capture() { # $1 = output basename (no extension)
  local id
  id=${CAPTURE_ID:-$(swift $DRIVE/winid.swift $APP_PID | head -1)}
  screencapture -x -o -l $id "$OUT/$1.png"
  echo "captured $OUT/$1.png"
}

quit_app() {
  # By keyboard equivalent (⌘Q), not menu title — titles are localized
  # under --lang.
  if [[ -n $APP_PID ]]; then
    swift $DRIVE/ax.swift $APP_PID menukey q cmd >/dev/null 2>&1 || kill $APP_PID 2>/dev/null || true
    for _ in {1..25}; do kill -0 $APP_PID 2>/dev/null || break; sleep 0.2; done
    kill -0 $APP_PID 2>/dev/null && kill -9 $APP_PID 2>/dev/null || true
  fi
  APP_PID=""
  # Sweep stray DIST instances (Launch Services has spawned surprise
  # copies for document opens before). Matches the dist path only —
  # never the installed /Applications app.
  pkill -f "$PWD/dist/PullMark.app/Contents/MacOS/PullMark" 2>/dev/null || true
}

for lang in "${langs[@]}"; do
  subdir=$(site_dir "$lang")
  mkdir -p "$OUT${subdir:+/$subdir}"
  for mode in $appearances; do
    for name in $scenes; do
      suffix=""
      [[ $mode == dark ]] && suffix="-dark"
      echo "── scene $name ($mode${lang:+, $lang})"
      if launch $mode && scene_$name; then
        capture "${subdir:+$subdir/}app-$name$suffix"
      else
        echo "scene $name FAILED${lang:+ ($lang)} — skipping capture" >&2
        failures=$((failures + 1))
      fi
      quit_app
    done
  done
done
if (( failures > 0 )); then
  echo "done with $failures FAILED scene(s) — fix and rerun those." >&2
  exit 1
fi
echo "done — review the results in $OUT before promoting to site/img."
