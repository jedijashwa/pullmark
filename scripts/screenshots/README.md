# Screenshot generator

Replayable captures of the site's app screenshots — the committed
alternative to hand-driven capture sessions (spec:
`docs/specs/site-dark-mode.md`).

## Run

    make app
    scripts/screenshots/generate.sh all --appearance both

Single scene / appearance: `generate.sh diff --appearance dark`.
Future locales (once app-i18n ships): `--lang ja` adds
`-AppleLanguages` to the launch and a `-ja` suffix to outputs.

Outputs land in `out/` (gitignored). Review them, then promote to
`site/img/` and bump the `?v=` cache-busters on the pages.

## Prereqs and rules

- The terminal needs the Screen Recording permission (captures come
  back empty otherwise) and the Accessibility permission (drive kit).
- Scenes use global mouse events: **hands off the machine** during a
  run (~5 min for all 16).
- Captures wear the classic Mac BLUE accent via argument-domain
  flags. This only works because scenes launch the app BARE: a
  document argument at launch makes Launch Services respawn the
  process, which keeps the environment but silently drops the
  argument domain (that is how a green-accent generation once
  escaped). The demo Location is handed to the running instance via
  `open -a` afterwards.
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
