#!/bin/zsh
# Scene definitions for the screenshot generator (spec: site-dark-mode;
# background/parallel rework: spec follows the localized-screenshots PR).
#
# Every scene starts from a FRESH demo launch with ~/Code/meridian-docs
# delivered as a Location (generate.sh sends it by pid-addressed
# AppleEvent), the sidebar visible, the PR overview selected, and the
# window pinned by winframe. Scenes drive the app ENTIRELY through
# pid-targeted channels — AX row selection, AX presses, pid-posted
# keys, capture URLs — so instances run backgrounded and in parallel
# without ever taking the cursor, the keyboard focus, or the clipboard.
# The -pm.captureChrome flag makes windows draw active chrome anyway.
#
# Scene inventory mirrors the site: doc notes pr diff blame edit
# remote themes.

drive() { swift scripts/drive/"$@"; }

# Localized titles for AX driving ($lang comes from generate.sh; empty
# means English). App-owned controls resolve from loc/, the system
# sidebar toggle from SwiftUI's own loctable — see loc-lookup.py.
t() { scripts/screenshots/loc-lookup.py app "$lang" "$1"; }
t_sys() { scripts/screenshots/loc-lookup.py system "$lang" "$1"; }

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
# preview entry — "folders come in as living trees". Row titles are
# fixture filenames (data), so selection is language-independent.
scene_doc() {
  drive ax.swift $APP_PID disclose guides >/dev/null
  sleep 1
  drive ax.swift $APP_PID select-row quick-start.md >/dev/null
  sleep 2.5
}

# The margin-notes fixture: three signed notes rendered in place.
# ⌘K Open Quickly + typed query — pid-posted keys reach the panel
# because captureChrome nominates a key window for the instance.
scene_notes() {
  drive pkey.swift $APP_PID 40 cmd            # ⌘K Open Quickly
  sleep 1
  drive ptype.swift $APP_PID wind-gust        # typed, never the clipboard
  sleep 1
  drive pkey.swift $APP_PID 36                # Return
  sleep 2.5
}

# PR overview: description, cockpit chrome, conversation with the
# rendered table. Selected at launch — just focus the content.
scene_pr() {
  hide_sidebar
  drive pkey.swift $APP_PID 121               # Page Down
  sleep 2
}

# Rendered diff: word-level highlights + the added mermaid flowchart.
# `2 calibration.md` = second matching row: Open Files has the local
# calibration.md, the PR file row follows it.
scene_diff() {
  show_sidebar
  drive ax.swift $APP_PID select-row 2 calibration.md >/dev/null
  sleep 3
}

# Result view with the blame gutter — avatars per run of blocks.
scene_blame() {
  show_sidebar
  # Toggle blame from the remote doc, where the checkbox is inline at
  # capture width (the PR-file view's mode picker pushes it into
  # overflow). The toggle is sticky, so the PR file picks it up.
  drive ax.swift $APP_PID select-row docs/getting-started.md >/dev/null
  sleep 2.5
  drive ax.swift $APP_PID press "$(t Blame)" >/dev/null
  sleep 1
  drive ax.swift $APP_PID select-row 2 getting-started.md >/dev/null
  sleep 2.5
  # menuitem, not `menu View …`: the top-level View menu's own title is
  # system-localized, but the item title is ours to resolve.
  drive ax.swift $APP_PID menuitem "$(t Result)" >/dev/null
  sleep 2.5
}

# Edit mode: the active block shows its source, the rest stays
# rendered. Block activation goes through the capture URL channel —
# the page's click targets aren't reachable from the accessibility
# tree (the listener is delegated), and that channel exists for
# exactly this. Line 9 = the "When to calibrate" paragraph.
scene_edit() {
  drive ax.swift $APP_PID select-row calibration.md >/dev/null
  sleep 2
  drive ax.swift $APP_PID menuitem "$(t "Edit Mode")" >/dev/null
  sleep 1.5
  drive aeurl.swift $APP_PID "pullmark://capture/reveal?line=9" >/dev/null
  sleep 1.5
}

# Browsed-from-GitHub doc with the provenance bar (demo remote session).
scene_remote() {
  drive ax.swift $APP_PID select-row docs/getting-started.md >/dev/null
  sleep 2.5
  hide_sidebar
}

# Settings → Appearance: the three live theme cards. Captures the
# settings window, not the main one. ⌘, is system-titled — pressed by
# keyboard equivalent, which no language changes.
scene_themes() {
  drive ax.swift $APP_PID menukey , cmd >/dev/null
  sleep 2
  drive ax.swift $APP_PID press "$(t Appearance)" >/dev/null
  sleep 1.5
  CAPTURE_ID=$(drive winlist.swift $APP_PID | awk '$4 != 1052 {print $1}' | head -1)
}
