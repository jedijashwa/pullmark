# Screenshot generator

Replayable captures of the site's app screenshots — the committed
alternative to hand-driven capture sessions (spec:
`docs/specs/site-dark-mode.md`).

## Run

    make app
    scripts/screenshots/generate.sh all --appearance both --lang all

That is the full site matrix: 8 scenes × light/dark × English + 7
locales, ~128 captures, roughly an hour hands-off. Narrower runs
compose the same flags: `generate.sh diff --appearance dark`,
`generate.sh pr --lang ja`, `generate.sh all --appearance both`
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

## Localized driving

Scenes act on controls by ACCESSIBILITY TITLE, and titles follow the
launch language. `scenes.sh` resolves app-owned titles through
`loc-lookup.py` from `loc/<lang>.lproj` (the same files the app
renders — scenes can't drift from the UI), and the system sidebar
toggle from SwiftUI's own Localizable.loctable. System menu items
(Settings, Quit) are pressed by keyboard equivalent (`ax.swift
menukey`), which no language changes. `--lang` also sets
`-AppleLocale` so dates and numbers render natively, not just
translated labels.

## Prereqs and rules

- The terminal needs the Screen Recording permission (captures come
  back empty otherwise) and the Accessibility permission (drive kit).
- Scenes use global mouse events: **hands off the machine** during a
  run (~5 min for the 16 English captures, ~an hour for the full
  language matrix).
- Captures wear the classic Mac BLUE accent via argument-domain
  flags. This only works because scenes launch the app BARE: a
  document argument at launch makes Launch Services respawn the
  process, which keeps the environment but silently drops the
  argument domain (that is how a green-accent generation once
  escaped). The demo Location is delivered through the app's own Open
  panel with pid-targeted keys (⌘O → ⇧⌘G → path) and VERIFIED via AX
  before any scene runs — never `open -a`: with the installed copy
  and dist both alive under one bundle id, Launch Services sometimes
  hands the folder to a freshly spawned third instance instead.
- The demo fixtures live in `~/Code/meridian-docs` (fictional origin,
  deliberately kept) and the app's built-in PM_DEMO session. Never
  point scenes at real repos or documents.
- Window geometry is pinned at 1052×784 logical points at (160, 60);
  scene coordinates in `scenes.sh` are global screen points derived
  from that frame. If a scene drifts (app UI changed), re-derive
  coordinates from a fresh screenshot before editing them.

## Cleanup (mandatory)

The generator quits each instance itself. After a session that
launched `dist/PullMark.app` in any other way:

    make unregister-dist

and relaunch /Applications/PullMark.app if it was displaced.
