# Back/forward navigation

Browser-style back and forward for every window: a per-window history of
the documents the window has shown, driven from paired toolbar buttons,
a new Go menu with ⌘[ / ⌘], and the extra buttons on multi-button mice.
Press-and-hold or right-click on either button pops the history as a
menu, exactly as browsers do. Session-only, document-level, and built on
the one choke point every navigation in the app already flows through.

## Motivation

Reading in PullMark is constantly a chain: a folder's README to a doc it
links, off to a PR, into its files, back out via Open Quickly to the
local draft. Every one of those hops is one-way today — retracing means
re-finding, in the sidebar or the ⌘K palette, a document the window was
showing thirty seconds ago. Every browser, plus Finder and Xcode, solved
this the same way: Back goes to what you were just looking at, Forward
un-does the Back, and holding the button shows the trail. Windows are
independent reading contexts in PullMark, so the history is per-window.

## §1 Scope and semantics

- **Document-level entries only.** A history entry is a change of the
  window's content destination — the `selection` cases that present
  content in the detail area: `.local`, `.folder`, `.folderNode`,
  `.prOverview`, `.prFile`, `.prDoc`, `.remoteRepo`, `.remoteDoc`.
  Never recorded: `nil` (placeholder) and the selection-only rows
  `.inboxItem` / `.recentItem` — opening one of those lands as its own
  destination and records then. In-page anchor jumps (outline clicks,
  footnote links) are not history; returning to a document restores its
  saved reading position, which covers the scroll story.
- **Browser semantics.** Organic navigation pushes the new destination
  and truncates everything forward of it. Back/forward traversal moves
  the index and records nothing. Consecutive duplicates cannot occur
  (`selection.didSet` already guards equality).
- **Per-window, session-only.** The history lives in the window's
  `AppState` and dies with the window. No persistence: PullMark does
  not restore windows or their content across launches, and Recents
  already covers "yesterday's document."
- **Caps.** 100 entries (oldest dropped); the pop-up menus show the
  nearest 20 per direction.

## §2 History engine (Core)

`Sources/PullMark/Core/NavigationHistory.swift`: a pure, generic
`NavigationHistory<Destination: Equatable>` so Core stays free of app
types and the tests can run it over `Int`.

- Single-array model (WebKit's back-forward list shape): `entries` plus
  `currentIndex`, not two stacks.
- `Entry` carries the destination plus a display `title` and SF Symbol
  `systemImage` snapshotted at visit time, so menus render without any
  session lookups.
- API: `visit(_:)` (truncate forward, append, enforce the cap),
  `canGoBack` / `canGoForward`, `goBack()` / `goForward()` (move the
  index, return the new current entry), `backEntries` /
  `forwardEntries` (nearest first, for the menus), and `entry(at:)` +
  `go(to:)` for menu jumps. Entries are never removed except by the
  cap — the trail stays intact (§4).
- Full Swift Testing coverage: visit truncation, cap enforcement,
  traversal bounds, nearest-first ordering, jump-to-index semantics.

## §3 Recording

`AppState` owns `@Published private(set) var history` (published so the
toolbar buttons and menu items re-evaluate their disabled state). The
one recording site is the existing `selection.didSet`: after the
equality guard, when `isTraversingHistory` is false and the new value is
a recordable destination (§1), snapshot title and icon and
`history.visit(...)`. All current and future assignment sites are
covered without touching them; `reactToSelection` manages previews and
open-file lists and never reassigns `selection`, so there is no
feedback loop.

Title and icon snapshots, mirroring the sidebar's own vocabulary:

| Case | Title | Symbol |
|---|---|---|
| `.local(url)` | last path component | `doc.text` |
| `.folder(root)` | folder name | `folder` |
| `.folderNode(root, path)` | directory name | `folder` |
| `.prOverview(id)` | "\(repo) #\(number)" | `arrow.triangle.pull` |
| `.prFile(id, path)` | file name | `doc.text` |
| `.prDoc(id, path)` | file name | `doc.text` |
| `.remoteRepo(id)` | "owner/repo" | `book.closed` |
| `.remoteDoc(id, path)` | file name | `doc.text` |

Long titles middle-truncate at render time in the menus; the snapshot
stores the full string.

## §4 Traversal and dead entries

`AppState.goBack()` / `goForward()` / `go(to:)` always land on the
target entry — the trail is never silently skipped or pruned. The move
is applied inside a synchronous `isTraversingHistory = true` window so
§3 records nothing and the forward list survives. What landing means
depends on the entry's health:

- **Live** entries apply by assigning `selection`; the detail area
  shows the document as usual.
- **Closed but recoverable** entries are **revived** — Back means "take
  me back to what I was seeing", not "back to what happens to still be
  open". Per case:
  - `.local(url)` closed but on disk: reopened through
    `openViaLink(url:)` — selected in its tree or re-pinned.
  - `.folder` / `.folderNode` whose Location is closed but whose root
    is on disk: the Location is re-added (`add(url:)`), then the
    landed row re-selected.
  - `.prOverview` / `.prFile` / `.prDoc` whose session is closed: the
    session ID **is** the ref (`owner/repo#123`), so the pull request
    re-fetches through `addPR(id, select: false)` — `select: false`
    because the landing already sits on its destination and addPR's
    own overview-select would record a bogus entry and truncate the
    forward trail. While the fetch runs the detail area shows the
    entry's name over "Reopening…" (§4.1); on arrival the published
    session re-renders the view by itself. A `.prFile` whose file left
    the PR redirects (untracked) to the overview; its entry stays put.
  - `.remoteRepo` / `.remoteDoc` whose session is closed: the ID is
    `owner/repo@ref` — the session is re-appended the way snapshot
    restores do (unresolved; tree and documents fetch lazily when the
    views ask).
- **Dead** entries — nothing left to revive — still apply their
  `selection`, and the detail area shows the **unavailable view**
  (§4.1) in place of the anonymous placeholder. Dead means: `.local`
  gone from disk, `.folder`/`.folderNode` root gone from disk, or a PR
  revival fetch that failed (deleted on GitHub, no access, offline —
  the failure also surfaces through the normal error alert). The entry
  stays in history: Back/Forward walk past it normally, it still
  appears in the pop-up menus, and if the resource returns the same
  entry simply works again — health is judged at each landing, never
  cached. Closing a session or file does no history bookkeeping.

### §4.1 The unavailable view

The detail area's existing fallback branches (each `case` already
degrades to `placeholder` when its lookup fails) upgrade to a named
unavailable view: the entry's snapshotted SF Symbol and title, large
and centered in the placeholder's visual style, over a one-line reason
— or, while `AppState.historyRevival` matches the selection, a small
spinner with "Reopening…":

| Case | Reason line |
|---|---|
| `.local` | "This file has been moved or deleted." + abbreviated path |
| `.folder` / `.folderNode` | "This folder has been moved or deleted." + abbreviated root path |
| `.prOverview` / `.prFile` / `.prDoc` | "Couldn’t load this pull request." |
| `.remoteRepo` / `.remoteDoc` | "Couldn’t load this repository." |

Titles and icons come from the history snapshot when the current
selection matches an entry, falling back to what the selection itself
carries (path last components) — the view must render even for a dead
selection reached organically (a file deleted out from under the
window). Informational only beyond the automatic revival: no manual
reopen actions.

## §5 Toolbar control

One customizable window-level item, id `nav-history`, placement
`.navigation`, declared **first** in `AppToolbar.body` — ahead of the
review item, so navigation survives the overflow squeeze longest
(declaration order is collapse priority; the file's header already
names navigation as the thing that must survive). `showsByDefault:
true` — the deliberate, documented exception to the new-items-ship-
hidden convention, because the buttons are the feature.

- One draggable unit holding paired back/forward buttons,
  `chevron.backward` / `chevron.forward`, each disabled when its side
  of the history is empty.
- AppKit-backed (NSViewRepresentable), because one control must answer
  three gestures: click navigates; press-and-hold (~0.3 s) or
  right-click pops a native `NSMenu` built fresh at pop time (the
  SwiftUI-Menu-caches-stale-rows trap is documented in this file) from
  `backEntries` / `forwardEntries` — nearest first, ≤ 20 rows, icon +
  title per row, dead entries included (the menu answers "what was
  that doc"; choosing one lands on §4.1's unavailable view). Rows jump
  via §4's `go(to:)`.
  The exact AppKit shape (two NSButtons vs an NSSegmentedControl) is
  an implementation choice.
- Help tags: "Show the previous document — click and hold to see
  history" (+ shortcut hint), mirrored for Forward.

## §6 Go menu and shortcuts

A new **Go** menu between View and Window — where Finder and Xcode keep
navigation — holding Back (**⌘[**) and Forward (**⌘]**), each disabled
when its side is empty, routed to the focused window's `AppState`
through the same focused-value plumbing the existing menu commands use.

- Two new `ShortcutStore` actions, `goBack` and `goForward`, rebindable
  in Settings like every other action; ⌘[ / ⌘] are unclaimed today.
- ⌘← / ⌘→ (Safari's alias pair) stay deliberately unbound: edit mode
  owns them for text navigation, and anyone who wants them can rebind.

## §7 Mouse buttons

A per-window local `NSEvent` monitor for `.otherMouseUp`: button 4
(`buttonNumber` 3) → back, button 5 (`buttonNumber` 4) → forward, only
when the event's window is this window. Consumed when handled, passed
through otherwise. Installed from the window's content with a
coordinator that removes the monitor on teardown (the
`ToolbarSectionEnforcer` lifecycle pattern).

## §8 Existing PR navigation

The `pr-nav` cluster on PR file surfaces stays, with one change: the
"Back to overview" button drops `chevron.backward` (which now belongs
exclusively to global Back) for `arrow.triangle.pull` — the same glyph
the sidebar and the Open PR button already use for pull requests — with
label "PR Overview". It was always an *up* affordance, not *back*: it
remains the one-click route to the overview when the window arrived at
a file directly (Open Quickly, sidebar), where history-Back correctly
goes somewhere else. Behavior and help text keep their shape.
Previous/next file and the n-of-m jump menu are untouched; they assign
`selection`, so every step records and Back un-does it. The leading
cluster on a PR file reads: `[◀ ▶] [PR ▲ ▼ "2 of 5"]`.

## §9 Interactions with existing features

- Sidebar: traversal assigns `selection`, so the sidebar highlight
  follows automatically — same binding.
- Open Quickly, deep links (`pullmark://`), CLI opens: all assign
  `selection` and record like any navigation.
- Preview-vs-open click setting: unchanged; a previewed visit records
  like any visit.
- Reading positions: Back restores the document's saved scroll — the
  existing per-document mechanism, nothing new.
- Edit mode: no interplay; its ⌘←/⌘→ text keys are untouched (§6).
- Compare, blame, outline, zoom: per-surface state, unaffected by
  traversal.
- Toolbar customization: `nav-history` is movable/removable like any
  non-sidebar-section item; per-surface arrangements are unaffected
  (window-level id, like `open-file`).
- Multiple windows: fully independent histories; the Go menu targets
  the focused window.
- Quick Look extension: unaffected.

## §10 Out of scope

- In-page anchor history and scroll-spot entries (§1 covers why).
- Trackpad two-finger swipe (revisit if missed; must not fight
  horizontal scrolling in wide tables).
- Persisting history across launches (implies window/session
  restoration, a different feature).
- Any history search or "show all history" surface beyond the two
  pop-up menus.

## §11 Verification

- Unit tests for `NavigationHistory` (§2's list) in
  `Tests/PullMarkTests`.
- Live loop per standing practice: drive-script trials of the buttons,
  the press-and-hold and right-click menus, and mouse buttons 4/5; a
  design-review pass on the toolbar control; Josh's dist-trial before
  any release.

## §12 Implementation-time decisions

- Two NSButtons vs one NSSegmentedControl for the pair (§5) — whichever
  yields native press-and-hold menus with the least custom event code.
- Exact middle-truncation width for menu row titles (~60 characters as
  a starting point).
