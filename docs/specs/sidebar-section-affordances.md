# Sidebar section affordances

Visible, hover-revealed actions on the sidebar's section headers: a
Close All ✕ on Open Files, and a "+" on Locations and Pull Requests
that works even when the section already has content. Grounded in a
Mac-conventions research pass (Mail and Photos are the only first-party
apps with header actions, and both put a hover-revealed glyph beside
the label); one third of the original ask — per-row remove buttons —
already shipped and needs nothing.

## Motivation

Josh (2026-08-20): "it's annoying there is no close all in open files,
no plus button to add a location or PR when there is already a location
or PR open." Today the big Open Folder…/Open Pull Request… buttons
exist only in EMPTY sections; once a section has content, adding
another means the File menu or toolbar. And Close All exists only as a
right-click on the Open Files header — an affordance nobody finds.

## Research summary

Full report in the session record (2026-08-20). Load-bearing findings:

- **Header actions are hover-revealed and sit beside the label**, not
  at the trailing edge: Mail's Favorites "+", Photos' My Albums "+".
  The trailing edge belongs to the system collapse chevron (macOS 14's
  `Section(isExpanded:)` draws it) and to this app's badge.
- Apple never puts bulk/destructive actions in headers; the only
  close-all-in-header precedent is VS Code's Open Editors — the direct
  ancestor of this sidebar's Open Files section, a legitimate borrow
  if kept visually quiet.
- **No confirmations** (HIG: no alerts for common undoable actions):
  Close All touches nothing on disk and closed files resurface in
  Recents; removing a Location just unlists it; removing a PR keeps
  the pending review server-side and queued comments on disk.
- Per-row remove buttons (hover ✕ + ⌫ + context menus) already ship on
  every removable row class; Recents is deliberately menu-only, like
  Mail/Safari history.
- HIG warns against bottom-of-sidebar buttons (windows get resized
  over them) — the Notes/Reminders pattern is out.

## §1 Close All — Open Files header

- A hover-revealed button after the "Open Files" label:
  `xmark.circle.fill`, the exact `HoverRemoveButton` recipe
  (ChromeFonts caption size, `.secondary`, `.buttonStyle(.plain)`) so
  the section-level ✕ rhymes with the row-level ✕ it aggregates.
- `.help("Close All")`, accessibility label "Close All Open Files".
- Action: the existing `closeAllOpenFiles()` — pinned files plus the
  preview slot. No confirmation.
- Rendered only while the section has content (same condition as the
  existing header context-menu item, which stays).
- **Menu parity:** File → Close All Files, a new
  `ShortcutAction.closeAllFiles` ("Close All Files", File category,
  ships unbound — deliberately NOT ⌥⌘W, which is the system's Close
  All windows), disabled when nothing is open.

## §2 "+" — Locations and Pull Requests headers

- A hover-revealed bare `plus` (Mail/Photos' plain glyph, no circle),
  same sizing recipe, after the label.
- Locations: `openFolderPanel()`, `.help("Open Folder…")`.
- Pull Requests: `showAddPR = true`, `.help("Open Pull Request…")`.
- The empty-state big buttons stay — a hover-only control can't be a
  first-time user's only path, and Mail keeps both too.
- **No "+" on Open Files:** ⌘O, the toolbar, and the empty state cover
  opening, and no Apple header carries two custom glyphs plus the
  chevron.
- Menu parity already exists (File → Open…, File → Open Pull
  Request…); the headers are pointers at those commands.

## §3 Mechanics

- `CollapsibleSection` generalizes: alongside `headerMenu`, a list of
  header actions (symbol, help, accessibility label, visibility,
  action). The header HStack tracks hover with the same plain
  `@State`/.onHover approach `RemovableRow` uses (its stale-latch
  edge cases are accepted there; consistency beats new tracking-area
  machinery), and renders the buttons between the title and the
  `Spacer()` while hovered.
- Buttons size via `ChromeFonts(zoom:)` — headers follow the zoom with
  their rows, and the buttons must too.
- Buttons work while the section is collapsed (the header is always
  visible; adding to a collapsed section is fine — the section's own
  expansion state is untouched).
- macOS 13 renders sections without the collapse chevron; the hover
  buttons become the header's only affordance there, which is fine.

## §4 Known risks (live-trial checks)

- **Header click hit-testing:** on some macOS versions header clicks
  participate in section expand/collapse. `.buttonStyle(.plain)` +
  `.contentShape(Rectangle())` on the buttons, and the dist trial
  verifies a button click doesn't also toggle the section. Escape
  hatch if SwiftUI double-handles: an AppKit overlay claiming the
  click first (the RowClickCatcher / DoubleClickCatcher pattern).
- **Chevron/badge collision:** actions sit leading-side, so none is
  expected; the trial glances at the badge case (Review Requests
  count) anyway.

## §5 Interactions with existing features

- Existing header context menu (Close All) and empty-state buttons:
  unchanged.
- Per-row hover ✕, ⌫ removal, context menus: untouched.
- Zoom: buttons scale with ChromeFonts like the header text.
- VoiceOver / Full Keyboard Access: hover-revealed buttons are
  invisible to them — the menu-parity commands (§1, §2) are the
  accessible path, per HIG.
- Recents: no changes.

## §6 Out of scope

- Confirmations or undo for any of these actions.
- A "+" on Open Files.
- Changes to Recents row affordances.
- Surfacing offline-queued comments when removing a PR (research
  flagged it as a future nicety, not this wave).

## §7 Verification

- Unit: `closeAllOpenFiles` behavior is already covered by existing
  state logic; the new surface is UI-only.
- Live drive loop: hover-reveal screenshots per section, click each
  button and verify the action (files close / panels open) WITHOUT the
  section toggling, collapsed-section behavior, zoom rendering, and
  the File-menu parity item's enablement. Screenshot review for Josh
  per current practice.
