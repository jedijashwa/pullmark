# Dark-mode site + the scene-scripted screenshot generator

Two halves, one wave (Josh, 2026-08-20): the site's screenshots become
appearance-aware, and the captures that feed them stop being hand-driven
token-burning sessions — a committed generator replays them like a
Playwright script.

## Motivation

The site's chrome already follows `prefers-color-scheme`, but all eight
app screenshots are light-only — a dark-mode visitor gets a dark page
with eight glowing light rectangles. The shots also predate the 0.37
back/forward toolbar (a debt Josh accepted when deferring the refresh
to this wave), so every shot needs retaking anyway. And app-i18n is
coming: screenshots will eventually need retaking per locale, which is
untenable by hand — Josh: "building a screenshot generator that has a
script to run through (like we would in playwright for a web app) is a
good idea so that we don't spend a shit ton of tokens on it each time."

## The generator (`scripts/screenshots/`)

- `generate.sh <scene|all> [--appearance light|dark|both] [--lang <code>]`
  — builds nothing itself; expects `dist/PullMark.app` (run `make app`
  first). For each requested scene × appearance it: launches the dist
  app fresh (`PM_DEMO=1`, `-pm.appearance <mode>`, and
  `-AppleLanguages (<code>)` when `--lang` is given, plus the standing
  blue-accent flags `-AppleAccentColor 4 -AppleHighlightColor …Blue`
  so captures match the published look on any machine — note the
  launch must be BARE: a document argument makes Launch Services
  respawn the app and drop the argument domain, so the demo Location
  is handed to the running instance via `open -a` instead), drives the scene with the `scripts/drive/` kit,
  captures the main window with `screencapture -x -o -l`, and quits the
  instance. Output: `out/app-<scene>[-dark][-<lang>].png`.
- Scenes are shell functions in `scenes.sh` — each one a deterministic
  sequence (open fixture, arrange view, wait for render, capture).
  Window geometry is pinned (1052×784 logical) by setting the frame
  via AX before capture, so every rerun is pixel-comparable.
- The eight committed scenes mirror the site: `doc`, `notes`, `pr`,
  `diff`, `blame`, `edit`, `remote`, `themes`.
- `README.md` in the same directory is the capture runbook: prereqs
  (Screen Recording permission, `make app`), the one command, the
  mandatory cleanup (`make unregister-dist`, relaunch /Applications if
  displaced) — so any future agent replays instead of re-deriving.
- Demo mode keeps everything fixture-only and offline; the demo
  defaults suite is wiped per launch, so runs don't contaminate each
  other or Josh's real domain.

## Site changes

- **`<picture>` everywhere a screenshot appears** (landing ×8 slots,
  agents ×2 — locale pages inherit via the same absolute `/img/` URLs;
  their local `<img>` markup gets the same wrapper by scripted
  transform, preserving translated alt text):

      <picture>
        <source srcset="/img/app-doc-dark.png?v=1"
                media="(prefers-color-scheme: dark)">
        <img src="/img/app-doc.png?v=9" …>
      </picture>

- **Appearance toggle**: a small sun/moon control injected by a new
  `site/theme.js` into the nav of every page (no markup edits across
  98 files; no-JS visitors keep the automatic behavior, which is the
  correct fallback). Three states: auto → light → dark, persisted as
  `pm-theme` in localStorage, applied as `data-theme` on `<html>`
  before first paint (script loads non-deferred and tiny to avoid a
  flash). Labels localized from a small table keyed off the page lang.
- **Token plumbing**: every page's dark token block moves to the
  three-state pattern — the `prefers-color-scheme` block guarded with
  `:root:not([data-theme="light"])`, plus a duplicate block under
  `:root[data-theme="dark"]`. Applied by scripted transform to the
  inline styles (landing + agents × 8 locales each) and the shared
  stylesheets; `i18n.css` consumes tokens only and needs nothing.
- **Toggle × pictures**: on an explicit choice, `theme.js` rewrites
  each `<source media>` so the picture matches the forced theme
  (`media="all"` / `media="not all"`); auto restores the original
  query. The `theme-color` metas get the same treatment.

## Out of scope

- OG cards stay single-appearance (no dark-variant mechanism in
  scrapers).
- Localized screenshots — the generator takes `--lang` from day one,
  but shots wait for app-i18n to ship.
- Site copy changes of any kind.

## Standing effect

Future screenshot refreshes (new features, app-i18n locales) are one
`make app && scripts/screenshots/generate.sh all --appearance both`
away, plus a human eyeball pass — no hand-driving, no re-derivation.
