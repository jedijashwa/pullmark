#!/bin/zsh
# Scene definitions for the screenshot generator (spec: site-dark-mode).
#
# Every scene starts from a FRESH demo launch with ~/Code/meridian-docs
# opened as a Location (generate.sh passes it as a CLI argument), the
# sidebar visible, the PR overview selected, and the window pinned at
# 1052x784 logical points at (160, 60). All coordinates below are
# GLOBAL screen points derived from that layout — pinned geometry is
# what makes them replayable. Rows aren't reachable by AXPress and
# pid-posted clicks are discarded by SwiftUI lists, so scenes use the
# global-event tier (click.swift): hands off the machine during a run.
#
# Scene inventory mirrors the site: doc notes pr diff blame edit
# remote themes.

drive() { swift scripts/drive/"$@"; }

# Localized titles for AX driving ($lang comes from generate.sh; empty
# means English). App-owned controls resolve from loc/, the system
# sidebar toggle from SwiftUI's own loctable — see loc-lookup.py.
t() { scripts/screenshots/loc-lookup.py app "$lang" "$1"; }
t_sys() { scripts/screenshots/loc-lookup.py system "$lang" "$1"; }

activate() {
  osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $APP_PID) to true" >/dev/null 2>&1 || true
  sleep 0.5
}

# Sidebar visibility is not deterministic across launches — force it.
# State comes from AX (sidebar-state: is there a native list outside
# the web area?), the toggle from its localized toolbar title.
set_sidebar() { # $1 = visible|hidden
  local want=$1 verb=Show
  [[ $want == hidden ]] && verb=Hide
  for _ in 1 2; do
    [[ $(drive ax.swift $APP_PID sidebar-state) == $want ]] && return 0
    drive ax.swift $APP_PID press "$(t_sys "$verb Sidebar")" >/dev/null
    sleep 1
  done
  [[ $(drive ax.swift $APP_PID sidebar-state) == $want ]] || {
    echo "set_sidebar: still not $want" >&2; return 1
  }
}
show_sidebar() { set_sidebar visible; }
hide_sidebar() { set_sidebar hidden; }

# Folder tree browsing: expanded guides, quick-start as an italic
# preview entry — "folders come in as living trees".
scene_doc() {
  activate
  show_sidebar
  drive click.swift 199 339   # guides disclosure
  sleep 1
  drive click.swift 291 371   # quick-start.md → preview
  sleep 2.5
}

# The margin-notes fixture: three signed notes rendered in place.
scene_notes() {
  activate
  show_sidebar
  drive pkey.swift $APP_PID 40 cmd            # ⌘K Open Quickly
  sleep 1
  printf 'wind-gust' | pbcopy
  drive pkey.swift $APP_PID 9 cmd             # paste query
  sleep 1
  drive pkey.swift $APP_PID 36                # Return
  sleep 2.5
}

# PR overview: description, cockpit chrome, conversation with the
# rendered table. Selected at launch — just focus the content.
scene_pr() {
  activate
  hide_sidebar
  drive pkey.swift $APP_PID 121               # Page Down
  sleep 2
}

# Rendered diff: word-level highlights + the added mermaid flowchart.
scene_diff() {
  activate
  show_sidebar
  drive click.swift 289 659   # PR file calibration.md
  sleep 3
}

# Result view with the blame gutter — avatars per run of blocks.
scene_blame() {
  activate
  show_sidebar
  # Toggle blame from the remote doc's toolbar, where the checkbox is
  # inline at capture width (the PR-file view's mode picker pushes it
  # into unreachable overflow). The toggle is sticky, so the PR file
  # picks it up.
  drive click.swift 308 499   # remote docs/getting-started.md
  sleep 2.5
  drive ax.swift $APP_PID press "$(t Blame)" >/dev/null
  sleep 1
  drive click.swift 289 723   # PR file getting-started.md
  sleep 2.5
  # menuitem, not `menu View …`: the top-level View menu's own title is
  # system-localized, but the item title is ours to resolve.
  drive ax.swift $APP_PID menuitem "$(t Result)" >/dev/null
  sleep 2.5
}

# Edit mode: the active block shows its source, the rest stays rendered.
scene_edit() {
  activate
  show_sidebar
  drive click.swift 280 179   # local calibration.md
  sleep 2
  drive ax.swift $APP_PID menuitem "$(t "Edit Mode")" >/dev/null
  sleep 1
  drive click.swift 791 354   # activate the "When to calibrate" paragraph
  sleep 1.5
}

# Browsed-from-GitHub doc with the provenance bar (demo remote session).
scene_remote() {
  activate
  drive click.swift 308 499   # remote docs/getting-started.md
  sleep 2.5
  drive ax.swift $APP_PID press "Hide Sidebar" >/dev/null
  sleep 1
}

# Settings → Appearance: the three live theme cards. Captures the
# settings window, not the main one.
scene_themes() {
  activate
  drive ax.swift $APP_PID menukey , cmd >/dev/null   # Settings… (system-titled)
  sleep 2
  drive ax.swift $APP_PID press "$(t Appearance)" >/dev/null
  sleep 1.5
  CAPTURE_ID=$(drive winlist.swift $APP_PID | awk '$4 != 1052 {print $1}' | head -1)
}
