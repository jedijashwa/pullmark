#!/bin/zsh
# Scene-scripted screenshot generator (spec: site-dark-mode; background/
# parallel rework in the localized-screenshots PR).
#
#   scripts/screenshots/generate.sh <scene|all> [--appearance light|dark|both] [--lang <code>|all]
#
# Replays committed scenes against dist/PullMark.app in demo mode and
# captures the window — the replacement for hand-driven capture
# sessions. Build first: `make app`. See README.md for the runbook.
#
# Instances run BACKGROUNDED and never take focus, the cursor, or the
# clipboard: scenes drive through pid-targeted channels only, and the
# -pm.captureChrome flag makes windows draw active chrome (colored
# traffic lights, accent selection) without being key. Languages run
# in PARALLEL — one instance per language on cascaded window frames —
# so `all --appearance both --lang all` (8 scenes × light/dark ×
# English + 7 locales, 128 captures) fits in roughly one language's
# wall clock, with the machine usable throughout.
#
# English lands in out/ (matching site/img/), localized captures in
# out/<site-code>/ (zh, ja, fr, de, nl, es, pt — matching
# site/img/<code>/), same basenames throughout.

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
rm -f $OUT/.status-*(N)

# dist shares the real defaults domain, and the blame scene writes the
# sticky pm.blame flag there — snapshot it and put it back so capture
# runs never change what the human's own app shows next launch.
blame_before=$(defaults read app.pullmark.PullMark pm.blame 2>/dev/null || echo ABSENT)
restore_blame() {
  if [[ $blame_before == ABSENT ]]; then
    defaults delete app.pullmark.PullMark pm.blame 2>/dev/null || true
  else
    defaults write app.pullmark.PullMark pm.blame "$blame_before"
  fi
}

# The EXIT trap reaps stray capture instances and restores the shared
# flag — no Launch Services registration exists to undo (delivery is
# pid-addressed).
trap 'pkill -f "$PWD/dist/PullMark.app/Contents/MacOS/PullMark" 2>/dev/null || true; restore_blame' EXIT

launch() { # $1 = appearance, $2 = window x, $3 = window y
  # Published screenshots wear the classic Mac BLUE accent (Josh's
  # standing rule) — forced via the argument domain so captures are
  # machine-independent. -pm.captureChrome draws active window chrome
  # without focus and suppresses the launch activation; the flags only
  # survive because the launch is BARE (a document argument makes
  # Launch Services respawn the app and drop the argument domain).
  local flags=(-AppleAccentColor 4 -AppleHighlightColor "0.698039 0.843137 1.000000 Blue"
               -pm.appearance $1 -pm.captureChrome 1)
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
  PM_DEMO=1 $APP $flags &
  APP_PID=$!
  CAPTURE_ID=""
  for _ in {1..50}; do
    swift $DRIVE/winid.swift $APP_PID >/dev/null 2>&1 && break
    sleep 0.2
  done
  sleep 1
  # Deliver the demo Location by pid-addressed AppleEvent — NEVER
  # `open -a`: with several same-bundle-id copies alive, Launch
  # Services sometimes spawns yet another instance for the document
  # and the scene captures a folderless window.
  swift $DRIVE/aeopen.swift $APP_PID ~/Code/meridian-docs >/dev/null
  sleep 2.5
  set_sidebar visible   # location_present needs the headings on screen
  if ! location_present; then
    echo "launch: demo Location missing — retrying delivery" >&2
    swift $DRIVE/aeopen.swift $APP_PID ~/Code/meridian-docs >/dev/null
    sleep 2.5
    location_present || { echo "launch: demo Location never arrived" >&2; return 1; }
  fi
  swift $DRIVE/winframe.swift $APP_PID 1052 784 $2 $3 >/dev/null
  sleep 1
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
  # Under parallel load WebKit occasionally hasn't painted a
  # backgrounded page at capture time — detect a uniform content
  # region and retry rather than shipping an empty pane.
  for attempt in 1 2 3; do
    screencapture -x -o -l $id "$OUT/$1.png"
    swift $DRIVE/blankcheck.swift "$OUT/$1.png" >/dev/null && break
    if (( attempt == 3 )); then
      echo "capture $1: content pane still blank after retries" >&2
      return 1
    fi
    echo "capture $1: blank content pane — waiting for render" >&2
    sleep 2.5
  done
  echo "captured $OUT/$1.png"
}

quit_app() {
  # By keyboard equivalent (⌘Q), not menu title — titles are localized
  # under --lang. Kills only THIS worker's instance: other languages'
  # instances are alive in parallel.
  if [[ -n $APP_PID ]]; then
    swift $DRIVE/ax.swift $APP_PID menukey q cmd >/dev/null 2>&1 || kill $APP_PID 2>/dev/null || true
    for _ in {1..25}; do kill -0 $APP_PID 2>/dev/null || break; sleep 0.2; done
    kill -0 $APP_PID 2>/dev/null && kill -9 $APP_PID 2>/dev/null || true
  fi
  APP_PID=""
}

# One worker = one language, scenes sequential within it. Runs as a
# subshell so APP_PID/CAPTURE_ID/lang stay private to the worker.
run_language() { # $1 = lang, $2 = worker index
  lang=$1
  local index=$2 failures=0
  local subdir=$(site_dir "$lang")
  # Cascaded frames keep every window fully on screen (occluded is
  # fine — the window server keeps backing stores current — but
  # offscreen regions would capture stale).
  local x=$((120 + index * 56)) y=$((48 + index * 36))
  mkdir -p "$OUT${subdir:+/$subdir}"
  for mode in $appearances; do
    for name in $scenes; do
      suffix=""
      [[ $mode == dark ]] && suffix="-dark"
      echo "── scene $name ($mode${lang:+, $lang})"
      if ! { launch $mode $x $y && scene_$name \
             && capture "${subdir:+$subdir/}app-$name$suffix"; }; then
        echo "scene $name FAILED${lang:+ ($lang)}" >&2
        failures=$((failures + 1))
      fi
      quit_app
    done
  done
  echo $failures > "$OUT/.status-${subdir:-en}"
}

# Stagger worker starts so eight cold WebKit launches don't collide.
index=0
for worker_lang in "${langs[@]}"; do
  if (( ${#langs[@]} > 1 )); then
    ( run_language "$worker_lang" $index ) &
    sleep 2
  else
    run_language "$worker_lang" $index
  fi
  index=$((index + 1))
done
wait

failures=0
for status_file in $OUT/.status-*(N); do
  failures=$((failures + $(cat "$status_file")))
done
rm -f $OUT/.status-*
if (( failures > 0 )); then
  echo "done with $failures FAILED scene(s) — fix and rerun those." >&2
  exit 1
fi
echo "done — review the results in $OUT before promoting to site/img."
