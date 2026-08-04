# Line numbers in rendered views

An off-by-default setting that shows each block's source line number in
the left margin of the rendered views — document, Result, and the
rendered diffs. The raw source view already has real per-line numbers;
this setting is about giving the *rendered* presentation an honest way
to answer "where is this in the file?"

## Motivation

A rendered Markdown view deliberately hides the source's line
structure: one paragraph may be one source line or fifty, and a
wrapped rendered line has no line number of its own. But readers still
need source coordinates — to cite a location in a comment or issue, to
jump there in an editor, or to orient inside a diff. The app already
tracks exactly this mapping (every top-level rendered element carries
`data-pm-lines="start-end"`, and diff segments carry
`lineStart`/`lineEnd`/`side`), so the feature is display, not new
bookkeeping.

Per-rendered-line numbering is rejected on principle: source lines and
rendered lines don't correspond, and any gutter that pretends they do
is fiction. Numbering is per *block*, which is the truth the app can
tell.

## 1. Setting

- A toggle in Settings alongside Content Width, labeled to make clear
  it applies to the rendered presentation (the source view already has
  line numbers): **"Line numbers in rendered views"**, with a short
  descriptor in the Content Width style, e.g. "Show each block's
  source line in the margin".
- Off by default. Stored in `UserDefaults.pullmark` under
  `"pm.lineNumbers"` via a small `LineNumbers`-style helper mirroring
  `ContentWidth` (current value, defaults key).
- Applied to the page as a root class `pm-line-numbers`:
  - Initial state: `HTMLBuilder` includes it the way `data-width` is
    included.
  - Live updates: a `WebViewProxy.setLineNumbers(_:)` toggling the
    class, driven from the same `@AppStorage`-observation pattern as
    `setContentWidth` — flipping the setting updates every open
    window immediately, no reload.

## 2. Presentation (document and Result views)

- Each top-level element with `data-pm-lines` gets one label: its
  **start line only**, small, dimmed, tabular numerals, right-aligned
  against the content's left edge with a fixed inset.
- Tooltip on the label shows the full range: "Lines 7–10" (or
  "Line 7" for a single-line block).
- Labels live in an absolutely positioned annotation layer over the
  content (the blame-gutter pattern), built by JS from the
  `data-pm-lines` annotations — never inside blocks, so wide content
  that scrolls (tables, code) is unaffected.
- Each label is anchored to the **first line of visible content** in
  its block, not the block's box — the same anchoring the comment rail
  uses, so a heading's top margin cannot float the number away from
  the text the reader sees.
- Elements without annotations (the TOC nav, injected layers) get no
  label.
- Room is reserved by the root class:
  `:root.pm-line-numbers .markdown-body` gains left padding (~48px,
  sized for 5-digit files plus inset) with per-theme `max-width`
  compensation, exactly the way `pm-blame-on` does it. Numbers occupy
  padding, so nothing reflows inside the content column.

## 3. Diff views

Numbers answer "where in the file after this change" by default;
old-side truth stays available where it exists.

- **Inline view**: added, modified, and moved blocks show their
  new-side start line. Removed blocks show their old-side start line
  styled distinctly (dimmer, italic) with tooltip "Old lines 3–5".
- **Word-diff merged blocks** (the "only these words changed"
  rendering): one number, the new-side start; the tooltip carries
  both truths — "Lines 12–14 · was 10–12". The rendered merge is a
  single block, so a single new-side coordinate is the honest label.
- **Split view**: each column is numbered by its own side — the one
  place old and new numbering are both first class.
- **Result view**: identical to document mode (it renders the new
  document and already carries `data-pm-lines`).
- The source/patch view is untouched — it already has real per-line
  numbers.

## 4. Coexistence

- **Blame**: blame-on currently reserves an 84px left gutter. With
  both on, the gutter widens so blame avatars sit outside and line
  numbers sit nearest the content; each feature's padding rule
  composes rather than fights. Both off → no left padding, unchanged.
- **Comment rail**: untouched; it owns the right margin
  (`pm-comment-room`). Line numbers own the left.
- **Content width**: padding composes with `data-width` the same way
  blame's per-theme `max-width` adjustments do, including Full Width.
- **Edit mode**: `data-pm-lines` is already re-stamped as edits
  commit; labels rebuild on the same re-render events, so numbers
  stay live while editing.

## 5. Verification

- `render-check.sh` assertion that the label markup appears when the
  root class is set and not otherwise.
- Headless-harness battery for diff-side numbering: added/removed/
  modified/moved/word-diff blocks produce the specified numbers and
  tooltips in inline and split views.
- Live screenshots (PM_DEMO where published): document view on/off,
  diff inline, blame + line numbers together, Full Width.

## 6. Release

- Ships off by default; the changelog frames it as a rendered-view
  companion to the source view's existing numbers.
- The same release refreshes **all** site screenshots from the
  PM_DEMO demo world at published pixel dimensions (migrating
  app-doc/blame/edit/theme shots that still show real data), per the
  standing marketing-screenshot policy.
