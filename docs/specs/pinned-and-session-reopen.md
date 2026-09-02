# Pinned, aliases, and session reopen

A Pinned section above Locations for the folders and files you keep
coming back to, each optionally renamed, with the true path shown
beneath when the name alone is ambiguous or invented. Alongside it, a
setting for whether the previous session reopens at launch (off by
default — pinned things always come back) and a Chrome-style offer to
restore after an unclean exit.

Josh (2026-08-28): "pin folders with aliases that then show their true
path as subtext … if I have deeply nested folders that I go into often
I can get to them easily"; pinned "separate or at least at the top";
"pinning should put it at the bottom of the list of pinned ones";
files pinnable too; "a setting for whether or not PRs, files, and
folders reopen when relaunching … Off by default where only pinned
things stay"; "detect when we didn't close correctly and offer to
restore (like Chrome)".

## §1 The Pinned section

- A new sidebar section, **Pinned**, directly above Locations (Finder's
  Favorites idiom). Own collapse state (`pm.sidebarPinnedExpanded`),
  own drag order, hidden while empty.
- Entries are either a **folder root** — an independent Location with
  its own tree, scan, and watcher, exactly like a Locations root, just
  living here — or a **file** — a single bookmark row (doc icon) that
  opens the file on click with the usual single-click-preview /
  double-click-keep-open behavior. A pinned file is pinned whether or
  not it is open; Open Files remains the working set, and its label
  "Keep Open" is untouched so the two ideas don't collide.
- A new pin lands at the bottom of Pinned.

## §2 Aliases and the path line

- `alias: String?` on a pinned entry AND on any Locations root. Title
  shown = alias, else the folder/file name.
- **Inline rename**, Finder-style: "Rename…" in the row's context menu
  or Return on the selected row turns the title into a text field in
  place; Return commits, Escape cancels, an emptied field clears the
  alias.
- The **path line** (secondary text, `PathAbbreviator` form
  `~/Code/…/deep/folder`) appears under the title when the entry is
  aliased OR another entry in the same section shares its title
  (case-insensitive). Twins always disambiguate; a unique, un-aliased
  root stays one line as today.

## §3 Pin and Unpin

- Folder rows inside a tree and file rows (in trees and in Open Files)
  get **Pin…**: creates the pinned entry and drops straight into
  rename with the current name pre-filled.
- Locations roots get **Pin** (moves the root into Pinned, bottom);
  pinned roots get **Unpin** (moves it to the bottom of Locations).
  Pinned files get **Unpin** (removes the bookmark; an open file stays
  open).
- Remove from Sidebar, reordering, view mode, and expansion
  persistence behave as for any root.

## §4 Persistence

- Pinned entries persist in their own defaults key
  (`pm.pinnedEntries`: path, kind, alias, viewMode, expanded), NOT in
  the session snapshot — they are a preference and always restore.
- Locations roots keep their alias inside the session snapshot's
  folder record (`alias` optional; older snapshots decode nil).

## §5 Session reopen setting

- Settings › General › **Reopen previous session at launch**
  (`pm.restoreSession`), **off by default**. Off: only Pinned comes
  back. On: files, folders, pull requests, browsed repos, and the
  preview restore as today.
- Migration: a user who already has a session snapshot and never set
  the key is migrated to ON at first launch of this version, so a
  default change never empties anyone's window. Fresh installs start
  off.
- Snapshots keep being written after every change regardless of the
  setting (0.44.2's coalesced writes), so an unclean exit always
  leaves a fresh one to offer.

## §6 Unclean-exit detection and the restore offer

- A marker (`pm.sessionOpen`) is set at launch and cleared in the
  normal quit path (`applicationWillTerminate`). Marker already present
  at launch ⇒ crash, force-quit, or power loss.
- With the setting OFF: a slim non-modal **banner** across the top of
  the window — "PullMark didn't quit normally. Restore the previous
  session?" with **Restore** and **Not Now**. Restore performs the
  normal snapshot restore; either button, or opening anything
  yourself, dismisses it. With the setting ON the session restores
  silently as always. Never a modal: nothing has been lost yet.

## §7 Out of scope

- Pinning remote docs or pull requests.
- Nested pinned folders inheriting a parent's git identity — each
  pinned root scans and probes git independently.

## §8 Verification

- Pure tests: title/path-line rule over a set of entries; pinned-entry
  round-trip; snapshot decode with and without alias; migration rule
  for `pm.restoreSession`.
- Live (demo mode): pin a deep folder, rename, twin-name path lines,
  unpin ordering, banner after a `kill -9`, Return-to-rename.
  Persistence needs a demo suite that survives relaunch:
  `PM_DEMO=1 PM_DEMO_SUITE=<name>` keeps a named suite (not wiped, not
  swept) and runs the launch-time persistence paths the per-pid demo
  skips. Verified 2026-08-28: pin + inline rename, path lines, Unpin to
  the bottom of Locations, Return-to-rename, file pin surviving a clean
  quit with the session dropped (setting off), and the banner after
  SIGKILL restoring the killed session on Restore.
