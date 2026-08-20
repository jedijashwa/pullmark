# Drive scripts

Small standalone Swift scripts for driving a running app and capturing
its windows — used by verification agents (see
`.claude/agents/verifier.md`) to review actual rendered interactions,
not just code. Run with `swift <script> <args>`; they need no build
step.

## Which tier to use

1. **Accessibility first (`ax.swift`)** — semantic, works with the app
   fully backgrounded, never touches the real cursor or the human's
   focus. Use it for menus, buttons, checkboxes, links: anything with a
   name and an AXPress action. This is the default for everything it
   can express.
2. **Pid-targeted raw events (`pclick.swift`, `pkey.swift`)** — CGEvents
   delivered straight to a pid with `CGEvent.postToPid`. The visible
   cursor never moves, but see the residue below: a fully inactive app
   discards them, so they only help when the target app is already
   active and you need a raw event AX can't express (exact-coordinate
   clicks, key events with modifiers).
3. **Global HID events (`click.swift`, `key.swift`, `drag.swift`,
   `hover.swift`, `gscroll.swift`) — last resort.** They move the real
   cursor and land on whatever is frontmost, locking the human out
   while they run. Reserve them for what genuinely needs the real
   cursor (hover states, cursor-shape checks, real drags), batch them,
   and warn the human first.

## Discovery and capture

- `winlist.swift <pid>` — prints `id x y w h layer` for each on-screen
  window owned by the pid. Menus, tooltips, and popovers are separate
  windows (layer 101/103); screenshot any of them with
  `screencapture -x -o -l <id> out.png` (always `-x`: silent shutter).
- `winid.swift <pid>` — prints the id of the pid's main-sized window.
- `ax.swift <pid> list [<depth>]` — dumps every element with an AXPress
  action as `role "title" x y w h` (global points), searching each
  window breadth-first to the given depth (default 8). Use it to
  discover targets; it sees both SwiftUI chrome and WKWebView content.

## Background tier (app can stay backgrounded)

- `ax.swift <pid> menu <Menu> <Item> [<Subitem>]` — walk the app's menu
  bar and AXPress the item (case-insensitive; a wrong name prints the
  items actually available at that level, which doubles as menu
  discovery). No coordinates, no menu windows to chase.
- `ax.swift <pid> press <title>` — breadth-first search of the app's
  windows for a pressable element whose AXTitle/AXDescription matches
  (exact match preferred, substring accepted) and AXPress it. Reaches
  SwiftUI toolbar buttons and web-content links/checkboxes alike.
- `ax.swift <pid> menuitem <title>` — like `menu`, but finds the item
  anywhere in the menu bar (Apple menu excluded). For localized runs:
  top-level menu names are system-localized, item titles resolve from
  `loc/` — so the caller passes just the item.
- `ax.swift <pid> menukey <char> <modifiers>` — AXPress the menu item
  carrying that keyboard equivalent (`menukey , cmd` = Settings…,
  `menukey q cmd` = Quit). Language-independent; the way to hit
  system-titled items no `.strings` file covers.
- `ax.swift <pid> sidebar-state` — prints `visible` or `hidden`: is
  there a native list outside the web area? Lets scenes toggle the
  sidebar deterministically instead of blind-pressing.
- `ax.swift <pid> menulist` — every menu item with its keyboard
  equivalent as `[modifier-mask+char]`; discovery for `menukey`.
- All check `AXIsProcessTrusted()` and fail with a one-line error if
  the Accessibility permission is missing.

## Pid-targeted raw events

- `pclick.swift <pid> <x> <y>` — mouse down/up posted to the pid. The
  location is still a global screen point (the app resolves which of
  its windows is hit) but the visible cursor does not move.
- `pkey.swift <pid> <keycode> [cmd]` — key press posted to the pid,
  flags cleared unless `cmd` is given.

## Global HID events (real cursor)

- `click.swift <x> <y>` — left click at a global screen point.
- `hover.swift <x> <y>` — move the mouse (menus track hover).
- `key.swift <keycode> [cmd]` — press a key, optionally with ⌘.
- `drag.swift <x1> <y1> <x2> <y2>` — press-drag-release across apps.
- `gscroll.swift <x> <y> <dy> [cmd]` — scroll-wheel events at a point,
  optionally with ⌘ held (the app treats ⌘-scroll as zoom).
- `gmouse.swift <x> <y> <right|hold|button4|button5>` — the gestures
  the plain click can't express: right-click, press-and-hold (0.6 s,
  e.g. the back/forward history menus), and mouse buttons 4/5. Global
  by necessity: pid-targeted mouse events never reach NSToolbar
  buttons even in the active app (verified live).

## Honest residue — what backgrounding cannot fake

- Hover states, cursor-shape checks, tooltips, and real drags are
  driven by the window server's actual cursor position; there is no
  per-process cursor, so only the global HID tier can exercise them.
- AppKit discards HID-class input (mouse, keyboard, even scroll) sent
  to an app that is not active: verified against PullMark, `postToPid`
  clicks/keys/scrolls to the fully backgrounded app were silently
  dropped — SwiftUI toolbar, sidebar list, WKWebView content, and ⌘
  key equivalents all ignored them, while `ax.swift` reached the same
  controls. Treat tier 2 as "no cursor movement", not "works while
  backgrounded".
- First clicks on an inactive window are swallowed by
  `acceptsFirstMouse` even for real input; synthetic events never
  activate the app, so there is no second chance. AXPress has neither
  problem.

## Notes that save hours

- Global-tier events post to `.cghidEventTap` with modifier flags
  cleared — nil-source CGEvents otherwise inherit live hardware
  modifiers, and `NSApp.sendEvent` never reaches NSEvent local
  monitors at all.
- Global-tier clicks land on whatever is frontmost at the point; raise
  your target window first and avoid coordinates covered by unrelated
  windows. Background-tier tools have no such constraint.
- Screen captures require the Screen Recording permission for whatever
  process runs `screencapture`; always pass `-x` so scripted captures
  stay silent. `-l <windowID>` captures a window even when it is
  behind other windows.
- Window bounds are in points; captures are Retina pixels (usually 2×).
- `ax.swift list` frames for scrolled-out web content are page
  coordinates that extend past the window; on-screen chrome frames are
  real global points.
