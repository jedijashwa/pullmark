# Drive scripts

Small standalone Swift scripts for driving a running app with real
input events and capturing its windows — used by verification agents
(see `.claude/agents/verifier.md`) to review actual rendered
interactions, not just code. Run with `swift <script> <args>`; they
need no build step.

- `winlist.swift <pid>` — prints `id x y w h layer` for each on-screen
  window owned by the pid. Menus, tooltips, and popovers are separate
  windows (layer 101/103); screenshot any of them with
  `screencapture -o -l <id> out.png`.
- `winid.swift <pid>` — prints the id of the pid's main-sized window.
- `click.swift <x> <y>` — left click at a global screen point.
- `hover.swift <x> <y>` — move the mouse (menus track hover).
- `key.swift <keycode> [cmd]` — press a key, optionally with ⌘.
- `drag.swift <x1> <y1> <x2> <y2>` — press-drag-release across apps.
- `gscroll.swift` — scroll-wheel events.

Notes that save hours:
- Events post to `.cghidEventTap` with modifier flags cleared —
  nil-source CGEvents otherwise inherit live hardware modifiers, and
  `NSApp.sendEvent` never reaches NSEvent local monitors at all.
- Clicks land on whatever is frontmost at the point; raise your target
  window first and avoid coordinates covered by unrelated windows.
- Screen captures require the Screen Recording permission for whatever
  process runs `screencapture`.
- Window bounds are in points; captures are Retina pixels (usually 2×).
