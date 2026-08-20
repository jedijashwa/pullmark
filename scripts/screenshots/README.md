# Screenshot generator

Replayable captures of the site's app screenshots — the committed
alternative to hand-driven capture sessions (spec:
`docs/specs/site-dark-mode.md`; localized/background/parallel rework
in the localized-screenshots PR).

## Run

    make app
    scripts/screenshots/generate.sh all --appearance both --lang all

That is the full site matrix: 8 scenes × light/dark × English + 7
locales, 128 captures. Languages run in PARALLEL (one instance per
language on cascaded window frames) and instances stay BACKGROUNDED
throughout — no focus steal, no cursor, no clipboard — so the whole
matrix lands in roughly one language's wall clock (~5 minutes) while
the machine stays usable. Don't minimize or close the capture windows
while a run is live; occluding them with other windows is fine.

Narrower runs compose the same flags: `generate.sh diff --appearance
dark`, `generate.sh pr --lang ja`, `generate.sh all --appearance both`
(English only).

Outputs land in `out/` (gitignored): English at the top level,
localized captures in `out/<site-code>/` (zh, ja, fr, de, nl, es,
pt) with the same basenames — mirroring `site/img/`. Review, then
promote:

    rsync -a scripts/screenshots/out/ site/img/ --include='*/' \
      --include='app-*.png' --exclude='*'

and bump the `?v=` cache-busters on the pages.
`scripts/check-site-i18n.py` verifies every page references its own
language's screenshots and that all referenced files exist.

## How instances are driven (all pid-targeted, all background-safe)

- **Delivery**: the demo Location and pullmark:// capture URLs arrive
  as pid-addressed AppleEvents (`aeopen.swift`, `aeurl.swift`) — never
  `open`/`open -a`, which resolve through Launch Services by bundle id
  and have handed documents to a freshly spawned third instance when
  /Applications and dist were both alive. Delivery is VERIFIED via AX
  before any scene runs; a launch whose Location never arrives fails
  that scene loudly instead of capturing a wrong window.
- **Sidebar rows**: `ax.swift select-row` / `disclose` (AX selection on
  the backing outline; SwiftUI rows discard posted clicks and carry no
  AXPress). Rows are matched by fixture filenames — data, so language-
  independent; an ordinal disambiguates duplicates
  (`select-row 2 calibration.md`).
- **App controls**: AX press by localized title, resolved at run time
  through `loc-lookup.py` from `loc/<lang>.lproj` (the same files the
  app renders — scenes can't drift from the UI) and, for the system
  sidebar toggle, from SwiftUI's own Localizable.loctable. System menu
  items (Settings ⌘, · Quit ⌘Q) go by keyboard equivalent
  (`ax.swift menukey`), which no language changes.
- **Keys and typing**: `pkey.swift` / `ptype.swift` post to the pid;
  `-pm.captureChrome` nominates a key window so a background instance
  routes them (AppKit drops key events for never-activated apps
  otherwise). Typing never touches the shared clipboard.
- **Page interactions with no AX/keyboard path** (the edit scene's
  block reveal — the page's click listener is delegated, so blocks
  aren't individually pressable): `pullmark://capture/…` URLs, a drive
  channel the app only routes when launched with `-pm.captureChrome`.
- **Active-looking chrome**: `-pm.captureChrome` draws colored traffic
  lights and accent selection without focus (CaptureChrome.swift), so
  captures are pixel-identical to a frontmost window's.

## Prereqs and rules

- The terminal needs the Screen Recording permission (captures come
  back empty otherwise) and the Accessibility permission (drive kit).
- Captures wear the classic Mac BLUE accent via argument-domain
  flags. This only works because instances launch BARE: a document
  argument at launch makes Launch Services respawn the process, which
  keeps the environment but silently drops the argument domain (that
  is how a green-accent generation once escaped).
- `--lang` pairs `-AppleLanguages` with `-AppleLocale` so dates and
  numbers render natively, not just translated labels.
- The demo fixtures live in `~/Code/meridian-docs` (fictional origin,
  deliberately kept) and the app's built-in PM_DEMO session. Never
  point scenes at real repos or documents.
- The window is pinned at 1052×784 logical points per instance
  (cascaded origins in parallel runs). Scenes carry no screen
  coordinates — targets are named, not pointed at — so cascading
  can't break them.

## Cleanup

The generator quits each instance itself and sweeps stragglers on
exit; nothing is registered with Launch Services, so there is nothing
to unregister. After a session that launched `dist/PullMark.app` any
OTHER way (e.g. `open dist/PullMark.app` for a trial), the standing
`make unregister-dist` rule still applies.
