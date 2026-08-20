# App internationalization: seven languages

The app joins the site (spec: site-localization) in Simplified
Chinese, Japanese, French, German, Dutch, Spanish, and Brazilian
Portuguese. Feasibility established by the 2026-08-20 spike; Josh
committed to the full wave same day ("ship 40, then do app i18n").

## Architecture

- **`.lproj` at `loc/`, assembled by the build.** Hand-authored
  `loc/<locale>.lproj/Localizable.strings` live at the repo root —
  deliberately OUTSIDE `Sources/` so SwiftPM never buries them in the
  resource bundle (where `Bundle.main` lookup can't see them and only
  the banned `Bundle.module` could). `make-app.sh` copies them into
  `Contents/Resources/` and adds `CFBundleDevelopmentRegion` (en) +
  `CFBundleLocalizations` to the Info.plist heredoc. Locale codes:
  `zh-Hans ja fr de nl es pt-BR`.
- **`Bundle.main` everywhere.** SwiftUI literal keys resolve through
  it automatically once the `.lproj` folders exist; plain-String
  contexts use `String(localized:)`/`NSLocalizedString`.
- **The Quick Look appex** gets copies of the same `.lproj` folders
  (its two user-visible error strings), assembled the same way.
- **Rendered-page strings ride the payload.** app.js copy (~75
  strings: composer, thread chrome, section headings, the attachment
  placeholder, tooltips) can't be reached by `.strings` files. A
  `strings` dictionary joins `HTMLBuilder.RenderPayload` — resolved
  Swift-side via `Bundle.main`, consumed by a `pmString(key)` helper
  in app.js. Composed fragments ("Show " + n + " resolved…") become
  whole templated messages with placeholders.

## The verification gate (`scripts/check-strings.py`)

genstrings cannot see SwiftUI literals, and a missing key fails
SILENTLY to English — so the gate comes before the first translation:

- Inventories keys three ways: SwiftUI literal call sites
  (Text/Button/Label/.help/Picker/Toggle/TextField/Menu/Section),
  `NSLocalizedString`/`String(localized:)` sites, and the JS strings
  table's keys.
- Diffs the inventory against every locale's `.strings`; reports
  missing and orphaned keys per locale.
- Validates format specifiers match the English source (%@ vs %lld
  mismatches crash or garble at runtime).
- Wired into `make test` so a new user-facing string without seven
  translations fails loudly at development time, and re-checked by
  the release runbook.

## Code work (from the spike, ~260 touch points)

1. ~180 plain-String sites wrapped: KeyboardShortcuts action/category
   names (~80), the `lastError`/`lastNotice` channel (71 sites, 27
   interpolated — `String(localized:)` with interpolation), NSAlert
   suite (17), open/save panel messages (~6), the 2 literal NSMenu
   items, GitHub-side user-visible labels (~15).
2. The app.js strings table (~75 strings + de-concatenation).
3. Fix the 5 `.help("literal" + shortcuts.hint(...))` concatenations
   that silently select the non-localizing StringProtocol overload.
4. ~376 SwiftUI literals: no code change (LocalizedStringKey), but
   their keys enter the inventory and all seven `.strings` files.

## Translation

- English is the key (no `en.lproj` needed; base language IS the key).
- Seven **opus-pinned** agents (model-assignment razor), one per
  locale, translating the extracted key inventory with the same
  conventions as the site wave: GitHub-domain terms per GitHub's own
  localized docs, macOS UI terms per Apple's glossaries (Ajustes /
  Réglages / Einstellungen…), keycaps/format specifiers verbatim,
  polite-form ja, du-form de, tú es, você pt-BR, je nl.
- The demo fixtures, changelog, and What's New stay English.

## Verification beyond the gate

- `make app` + `-AppleLanguages '(<code>)'` launches (BARE launch —
  a document argument makes Launch Services drop the argument domain,
  see scripts/screenshots/README.md) for per-locale visual passes.
- **German width pass** specifically: nav labels, toolbar, Settings —
  German runs ~30% longer than English.
- Localized screenshots via `generate.sh --lang <code>` become
  possible after this ships; the site keeps English-UI shots until a
  deliberate refresh (own decision, not part of this wave).

## Standing tax (accepted)

Every release that adds user-facing strings owes seven translations
before it ships; the check-strings gate makes forgetting impossible
and the opus translation fan-out makes paying it minutes, not hours.

## Out of scope

- Localized changelog / release notes / What's New.
- Localized demo fixtures (screenshots stay English-fixture).
- RTL support (no RTL locale in scope).
- pt-PT, zh-Hant, and further locales — add on demand.
