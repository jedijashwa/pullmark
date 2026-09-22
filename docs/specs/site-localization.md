# Site localization: seven languages

pullmark.app gains translated variants of its content pages in
Simplified Chinese, Japanese, French, German, Dutch, Spanish, and
Brazilian Portuguese. Scope and shape settled with Josh 2026-08-20.

## Scope

Twelve pages per language — the landing page, `/uses/agents/`, and the
ten `/docs/` pages (overview, features, sidebar, toolbar, settings,
shortcuts, cli, troubleshooting, experimental, experimental/margin-notes).
`/privacy/` and `/licenses/` stay English only (legal-ish copy where
translation nuance drifts worst).

Locales and paths:

| Locale | Path prefix | Language name (shown in switcher) |
|---|---|---|
| `zh-Hans` | `/zh/` | 中文 |
| `ja` | `/ja/` | 日本語 |
| `fr` | `/fr/` | Français |
| `de` | `/de/` | Deutsch |
| `nl` | `/nl/` | Nederlands |
| `es` | `/es/` | Español |
| `pt-BR` | `/pt/` | Português |

Portuguese ships as pt-BR (the larger audience; pt-PT can follow on
demand). Spanish is generic `es`.

## Addressing: distinct URLs, suggest, redirect only on an explicit pick

Every variant is its own page at a mirror path (`/ja/docs/shortcuts/`).
No server-side language negotiation and no automatic redirects — Josh's
call: "different pages with the address but then we show switcher and
suggest switching in the detected language if it's supported."

Amended 2026-09-22: still no server-side negotiation, and still nothing
automatic for a visitor who has not chosen. A reader who *has* picked a
language is redirected client-side to it — see **Language preference**
below for why and what it costs.

- **hreflang matrix**: every page (English included) carries
  `<link rel="alternate" hreflang="…">` for all eight variants plus
  `x-default` pointing at the English page. Canonical is per-variant.
- **Language switcher**: a footer row on every page listing every
  language by its own name, linking to the same page in that locale.
  Present tense, no flags (flags ≠ languages).
- **Suggestion banner**: shared `site/i18n.js`. Reads
  `navigator.languages` — and nothing else; when the page's language
  differs from the visitor's best supported match, shows a dismissible
  top bar written in the *target* language offering that locale's
  version of the same page. Dismissal persists in `localStorage`
  (`pm-lang-suggest`); the banner never nags after a dismissal, and
  never fires when the languages already match.
- **Language preference**: picking a language — in the footer switcher
  or by taking the banner's offer — writes it to `localStorage`
  (`pm-lang`). A tiny script inlined in every variant's `<head>`, ahead
  of `theme.js`, reads it and `location.replace()`s to that variant
  before first paint. Only an explicit pick sets it; only another pick
  changes it.

  Amended 2026-09-22, reversing the "no automatic redirects" line
  above for readers who have chosen. Original shape: a switcher click
  was remembered and fed the *banner*, which then offered the chosen
  language from English pages. That misfired badly — an English reader
  who had once clicked 中文 to look at it got a bar of Chinese on every
  English page afterwards, which reads as a broken site, and one click
  is indistinguishable from sampling a translation. Rather than weaken
  the signal, the preference was promoted: an explicit pick now takes
  you there instead of offering.

  What holds the design together:

  - **The preference drives the redirect; the browser drives the
    banner.** They are never crossed. On a variant you were sent to,
    detection offers your browser's language as the way back — one
    click, which is also how you change the preference.
  - **No preference, no redirect.** A first-time visitor, and every
    crawler (no `localStorage`), gets exactly the URL it asked for, so
    the hreflang matrix keeps doing the routing it was built for.
  - **`location.replace`, not an assignment.** The requested URL never
    enters history, so Back leaves the site instead of bouncing.
  - **Inline and pre-paint**, so there is no flash of the wrong
    language. It is duplicated on all 96 pages by necessity;
    `check-site-i18n.py` holds every copy byte-identical and restamps
    them with `--fix-redirect`.
  - **No cookie, no Function.** The preference stays in
    `localStorage`, which keeps `/privacy/`'s "no cookies" accurate,
    keeps `_redirects` working (Pages ignores it for any path a
    Function serves), and keeps the site on Pages' free unlimited
    static requests.

  Accepted cost: while you hold a preference you cannot open another
  language's page by URL — a link to `/zh/docs/cli/` sent to a reader
  whose preference is English lands them on `/docs/cli/`. The switcher
  still works (it sets the preference before navigating), and the
  banner is the one-click way back. Josh's call 2026-09-22, over the
  alternative of leaving it a suggestion.

## Typography and correctness details

- Each variant sets `<html lang="…">` (`zh-Hans` pages use
  `lang="zh-Hans"`) — load-bearing for Han-unification glyph selection;
  a `/ja/` page without `lang="ja"` renders Japanese text with Chinese
  glyph variants for some codepoints.
- Font stacks: per-language overrides in the shared styles extend
  `--sans`/`--serif` with CJK families (PingFang SC / Hiragino Sans,
  Songti/Mincho for serif, Noto fallbacks for non-Apple platforms).
  Latin-script locales ride the existing stacks.
- CJK copy avoids italics (emphasis via bold or 「」), handled in
  translation.
- German runs ~30% longer than English — nav and card layouts get a
  visual pass at desktop and narrow widths.

## Translation conventions

- Code blocks, CLI commands, key caps (⌘⇧O), file names, and product
  names stay verbatim.
- The app's UI is English: docs reference UI elements by their English
  names, with a translation in parentheses on first use per page where
  it aids comprehension ("Open Files（開いているファイル）").
- Meta titles/descriptions and OG tags are translated; OG images stay
  the shared English screenshots. The landing page's JSON-LD gains
  `inLanguage` and the variant URL.
- Screenshots remain English-UI until app i18n ships (its own wave).
  When it does, localized screenshots come from the scene-scripted
  screenshot generator (Josh 2026-08-20: a committed, replayable
  capture script à la Playwright — built in the dark-mode wave, rerun
  per locale via `-AppleLanguages` flags), so no per-language capture
  session is ever hand-driven.

## Link and asset rules for locale pages

- Shared assets by absolute path (`/img/…`, `/docs/docs.css`) — locale
  directories carry no asset copies.
- Cross-page links stay in-locale (`/ja/docs/features/`).
- Links to untranslated pages (privacy, licenses, GitHub) go to their
  only version.

## Plumbing

- `sitemap.xml` regenerated: 96 URLs (12 pages × 8 variants), each
  entry carrying its full `xhtml:link` alternate set.
- `scripts/check-site-i18n.py`: verifies every locale has all twelve
  pages; every page has the right `lang`, canonical, full hreflang
  matrix, switcher, and banner include; locale pages contain no
  relative asset references; sitemap covers exactly the shipped URL
  set. Run before any site deploy — translated variants fail silently
  (missing page = 404, wrong lang = wrong glyphs) without it.

## Standing tax (accepted)

Every edit to a scoped English page ripples to seven variants. The
check script catches missing pages, not stale prose — keeping variants
current is a per-change discipline. Josh accepted this with the wider
language list; model translation makes the marginal cost minutes per
change.

## Out of scope

- App internationalization (its own wave; spike verdict in the
  2026-08-20 session: viable, ~630 strings, ~260 code-touch points,
  extraction script required first).
- `/privacy/`, `/licenses/`, `llms.txt`, RSS/blog (none exists).
- pt-PT, zh-Hant, and further locales — add on demand.
