# Sidebar navigator

Make the navigation panel's interactions first class: real folder
trees, closeable items, honest recents, and native-grade polish.

## Motivation

The sidebar is the app's front door, and today it undercuts everything
behind it:

- Opening a folder recursively scans and dumps every Markdown file
  from all subdirectories as a flat list into "Local Files". The
  folder itself is not an entity in the model — nothing to close,
  refresh, or persist. Session restore snapshots the expanded file
  list, so files added to the folder later never appear on relaunch.
- Removal is one-at-a-time via context menu. There is no close-folder
  gesture, no hover affordance, no keyboard removal.
- A file's location is invisible — no path display, and Reveal in
  Finder / Copy Path don't exist anywhere.
- PR file lists are flat full-path rows, head-truncated, unsorted.
- Recent items pointing at missing files are discovered only by
  clicking: the app shows an error alert and silently drops the entry
  — precisely wrong for the common causes (git branch switches,
  unmounted volumes) where the file comes back.
- Recent and Review Request rows are plain buttons outside the list
  selection model, so they neither highlight nor participate in
  keyboard navigation like other rows.

The requester's summary: "make the navigation panel interactions feel
first class primo great," with an explicit invitation to follow best
practices over their own sketches and permission for a full
information-architecture rethink.

## Research summary

Feature-researcher survey, July 2026, across VS Code, GitHub's PR
file tree, Finder, Apple HIG commentary, Notion, iA Writer, Obsidian,
and Xcode. Highlights:

- **"Things you opened" vs "places you're browsing"** is the cleanest
  articulation of a mixed sidebar — iA Writer's Locations (folder
  roots you add) vs Favorites, VS Code's Open Editors working set
  above the workspace tree ([iA Writer
  Library](https://ia.net/writer/support/library/organize), [VS Code
  UI](https://code.visualstudio.com/docs/getstarted/userinterface)).
- **Trees won.** GitHub made the tree the default PR "Files changed"
  view in 2022 and doubled down in its 2025–26 revamp, adding
  per-file comment indicators in the tree ([2022
  changelog](https://github.blog/changelog/2022-03-16-pull-request-file-tree-beta/),
  [2026
  rollout](https://github.blog/changelog/2026-01-22-improved-pull-request-files-changed-page-on-by-default/)).
  Obsidian's explorer is a Markdown-only tree, folders first
  ([docs](https://obsidian.md/help/plugins/file-explorer)); every
  project editor (VS Code, Xcode, Nova) agrees.
- **Hover-revealed controls are established but scoped**: VS Code's
  Open Editors ✕, Safari's hover ✕, Notion's hover ⋯/+ — always on
  top-level working-set rows, never scattered across tree contents.
  Finder reserves in-row hover glyphs for volumes' eject; removal
  lives in the context menu ("Remove from Sidebar") — the verb this
  spec adopts ([Finder
  sidebar](https://support.apple.com/guide/mac-help/customize-the-finder-sidebar-on-mac-mchl83c9e8b8/mac),
  [Notion sidebar](https://www.notion.com/help/navigate-with-the-sidebar)).
- **Path disclosure on demand**: VS Code shows a dimmed parent-folder
  suffix only when two open items share a name; tooltips carry full
  paths ([labelFormat](https://github.com/Microsoft/vscode/issues/69718)).
  Always-on paths double row height for zero information in the
  common case.
- **Dead recents have no good prior art.** macOS Recent Items fail on
  click; VS Code's purge behavior is undocumented (community cleanup
  scripts exist because stale entries linger). No surveyed app
  dims-and-revives — the recommendation below stands on its own
  reasoning, and PullMark already has a precedent in PR recents,
  which mark deleted PRs rather than dropping them.
- **Reorderability**: Finder favorites and Notion drag-reorder;
  Obsidian keeps tree contents sorted (manual order inside trees is a
  plugin-grade minority need). SwiftUI's `onMove` cannot combine with
  hierarchical lists — top-level-only manual order is both the right
  design and the feasible one ([Apple
  forums](https://developer.apple.com/forums/thread/744173)).
- HIG guidance: sidebars present app-level collections; keep
  hierarchy shallow-feeling; filter fields belong at the bottom
  (Xcode's navigator filter); width 225–275 pt
  ([HIG](https://developer.apple.com/design/human-interface-guidelines/sidebars),
  [Guzman
  guidelines](https://marioaguzman.github.io/design/sidebarguidelines/)).

## The design

### 1. Information architecture: five sections

| Section | Contents |
|---|---|
| **Files** | Individually opened documents (ad-hoc opens) |
| **Folders** | Each opened folder as a closeable root node with a tree |
| **Pull Requests** | PR groups, file lists upgraded to trees |
| **Review Requests** | The inbox, unchanged in role |
| **Recents** | Recent files, folders, and PRs, with new lifecycle rules |

"Local Files" retires: **Files** and **Folders** communicate the
opened-vs-browsing split ("Local" earned nothing once PRs had their
own sections). "Recent" becomes **Recents** (Finder's noun; the menu
stays "Open Recent" per macOS convention). Section headers use
HIG title-style capitalization.

The model gains a folder entity — `LocalFolder { rootURL, tree,
expandedPaths, viewMode }` — alongside `LocalFile`. Opening a second
folder adds a second root; roots never merge. Recent and Review
Request rows become real selectable list rows so every section
participates in selection and keyboard navigation.

### 2. Folder trees

- **Tree by default** under each folder root: Markdown files only
  (current scan filter and skip-list retained), empty directories
  pruned, folders before files, case-insensitive name sort.
- **Single-child chains compress** into one node (`docs/en/guide`) to
  keep depth honest, GitHub-style.
- **Expanded state persists per root** in the session snapshot; the
  snapshot stores the folder root (not the expanded file list), so
  reopening picks up files added since.
- **Scanning is lazy per disclosure**: directories scan when
  expanded. The 500-file cap retires for tree mode; the flat view
  keeps a cap with its existing truncation notice.
- **"View as List" survives as a per-root alternative** (context
  menu: View as Tree / View as List; default Tree). The flat view
  keeps today's root-relative labels — genuinely better for small,
  shallow doc repos.
- A refresh happens automatically on window activation and via
  context menu **Refresh Folder**.

### 3. PR file trees

- Each PR's Markdown file list renders as the same tree (nested by
  path, same sort, same compression), with per-file status icons
  retained and **unresolved-comment count badges** on file nodes once
  the review-conversations work (#29) lands — matching GitHub's
  2025 tree.
- The PR group header gains a changed-file count, and the "N other
  files not shown" honesty line (today only in the overview) is
  echoed as a quiet final row in the group.
- View as List remains available per PR group; browsed repo docs
  (`browsedDocs`) stay a flat run below the tree.

### 4. Item lifecycle

- **Hover ✕ on top-level removable rows only** — Files rows, folder
  roots, PR group headers, Recents rows. Never on tree children:
  they are contents of a place, not removable items. The ✕ performs
  the same non-destructive "Remove from Sidebar" / "Remove from
  Recents" as the context menu (nothing touches disk; no
  confirmation, per HIG).
- **⌫ (the standard delete key, present on every Mac keyboard)
  removes the selected removable item.** ⌘W remains Close Window —
  no surveyed app overloads it by sidebar focus, and the shortcut
  conflict table already reserves it.
- Context menus grow to first-class: **Remove from Sidebar / Remove
  from Recents, Reveal in Finder, Copy Path, Refresh Folder, View as
  Tree / View as List, Clear Recents** (section header). Review
  Request rows gain a context menu with Open and Reveal on GitHub.
- Closing a folder root removes the root and its tree in one
  gesture — the missing "close the whole folder" operation.

### 5. Path disclosure

- Tree nodes show no path — the tree is the path.
- **Files and Recents rows show a dimmed abbreviated parent path as a
  second line only when two visible rows share a display name**
  (VS Code's rule), using the existing `PathAbbreviator` and the
  two-line row pattern the inbox already renders.
- Every local row carries a full abbreviated-path tooltip and Reveal
  in Finder.

### 6. Recents that tell the truth

- **Validate on render**: a cheap existence check for the ≤12
  file/folder entries at window open and app activation (no
  watchers).
- **Dim, don't delete**: missing entries render in secondary color
  with tooltip "File not found — last seen at ~/…". They **revive
  automatically** when the file reappears — built for git branch
  switches and unmounted volumes. (No surveyed app does this; PR
  recents already mark deleted PRs rather than dropping them, so the
  pattern is native to the app.)
- **Clicking a dead entry no longer errors-and-purges**: it shows a
  quiet notice with a Remove from Recents action. Hover ✕ and ⌫ also
  work on dead entries.
- PR recents keep their live status decoration; file recents keep
  feeding the system Open Recent menu.

### 7. Reorderability

- **Manual drag-reorder for top-level items**: Files rows, folder
  roots, PR groups. Order persists in the session snapshot.
- Never inside trees (contents stay sorted; SwiftUI `onMove` cannot
  combine with hierarchical lists anyway) and not Recents or Review
  Requests — chronology and priority are their meaning.
- No drag-to-nest; nesting has no meaning here.
- If the drag recognizer measurably degrades row click feel, the
  fallback is context-menu Move Up / Move Down — decided during
  implementation, not after ship.

### 8. Polish

Ranked; all in scope for this spec:

1. **←/→ collapse/expand** on tree nodes, ⌥-click for deep expand,
   arrow navigation across all sections (all rows now selectable).
2. **Space → Quick Look** on local rows — the app ships a Quick Look
   extension; previewing your own render from the sidebar is a
   signature move.
3. **Filter field at the bottom of the sidebar** (Xcode position),
   filtering all sections live; Open Quickly (⌘K) remains the
   keyboard path.
4. **Empty-state buttons**: empty Files/Folders sections show "Open
   File…" / "Open Folder…" buttons instead of hint text; empty Pull
   Requests shows "Open Pull Request…".
5. Type-to-select in the list.
6. Selecting a folder-tree file no longer depends on scan order;
   opening a folder selects nothing until the user picks a file
   (today the last-enumerated file wins).

## Interactions with existing features

- **Session restore**: snapshot format changes to folder roots +
  expanded paths + manual order + view modes; migration reconstructs
  roots from the old flat list via the `resourceRoot` heuristic, else
  files land in Files.
- **Open Quickly (⌘K)**: enumerates folder trees lazily-scanned or
  not — the palette triggers a full scan of unexpanded roots so
  results stay complete.
- **Search All Files (⇧⌘F)**: same completeness rule as ⌘K.
- **Drag and drop**: the window-wide file-URL drop target must not
  swallow internal reorder drags; drops onto the sidebar add items
  as today.
- **File watching**: the existing watcher keeps refreshing open
  documents; folder trees refresh on activation, not via new
  watchers.
- **Zoom**: sidebar chrome fonts already scale; hover ✕ and badges
  scale with them and keep adequate hit targets.
- **Review conversations (#29)**: comment-count badges on PR file
  nodes come from that spec's per-path thread data; this spec
  provides the tree nodes they attach to.
- **Inbox settings**: "Show review requests in the sidebar" and the
  Markdown-only filter are unchanged; inbox rows joining the
  selection model changes no polling behavior.
- **Quick Look extension**: unchanged; Space-preview uses the
  standard QL panel on the file URL.
- **Menus and shortcuts**: new commands (Reveal in Finder, Copy
  Path, Refresh Folder, Clear Recents, filter focus) get menu items
  and appear in Settings ▸ Keyboard as rebindable, per convention.
- **Multi-window**: sidebar contents remain per-window state;
  manual order and view modes persist per window via the session
  snapshot, section collapse stays per-window `@SceneStorage`.
- **Theming/exports/editing/blame**: untouched — the sidebar is
  native chrome, not rendered content.
- **README/CHANGELOG**: folder-opening and sidebar descriptions
  need updating at implementation time.

## Out of scope

- File management operations: New File/Folder, Rename, Duplicate,
  Delete/Move to Trash. PullMark is a reader/reviewer; Reveal in
  Finder delegates honestly.
- Single-click-preview vs pinned-open semantics (no tab bar exists;
  every open is lightweight).
- Drag-to-nest, favorites/pinning, smart folders, tags.
- Showing non-Markdown files in trees.
- A global always-visible path bar or breadcrumbs in the detail view.
- Changes to the window/tab model.

## Open questions for implementation time

- Verify GitHub's single-child folder-chain compression behavior in
  the wild before adopting its exact display form (primary-source
  check was inconclusive).
- SwiftUI: hierarchical `List` + hover-revealed trailing buttons +
  top-level `onMove` in one list is the riskiest combination —
  prototype first; macOS 13 fallbacks (the `CollapsibleSection`
  pattern) must be preserved.
- Lazy-scan interaction with the ⌘K/⇧⌘F completeness rule: scan on
  first palette invocation may need a progress affordance for huge
  roots.
- Exact dimmed-dead-recent visual across themes and both appearances
  (design-reviewer pass).
- Whether the filter field ships in this wave or trails: it is the
  most severable piece if the wave needs trimming.
- Hit-target size for hover ✕ at the smallest chrome-font zoom step.

## Verification notes

The implementing PR should demonstrate live: opening a nested docs
folder produces a tree (not a flat dump) with the folder as a
closeable root; a second folder adds a second root; View as List
round-trips; hover ✕ and ⌫ remove items; a recent whose file is
deleted dims with the tooltip, revives when the file returns (test
via git branch switch), and offers removal on click; PR files render
as a tree with status icons; reorder persists across relaunch; ←/→
and Space behave; session restore reconstructs roots including files
added while the app was closed.

The implementing PR should say "Closes #ISSUE" (issue number filled
in once the issue exists).
