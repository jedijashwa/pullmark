# Rich editor (beta)

A whole-document rich Markdown editor behind a beta setting, replacing
click-to-edit-a-section-of-raw-Markdown for people who don't want to
write raw Markdown any more than they want to read it. Explicit edit
mode, minimal-diff saves, margin notes live while editing, real table
editing. Ships last in the 2026-08-28 queue, as its own release, only
after Josh has tried it live.

Josh (2026-08-28): "we made a mistake with how bare-bones our editing
is … someone who doesn't want to read in raw markdown probably also
doesn't want to write in raw markdown. This will need to be a beta
feature that totally switches how editing works. I want a full rich
editor that is great to use, not section by section. Also, margin
notes still need to work even while editing … For tables, definitely
rich table related editing … For diagrams, maybe they stay raw for
right now."

## §1 Editing model

- Reading stays the renderer. **Edit** (toolbar button, ⌘E,
  double-click on the document) turns the whole document into the
  editor in place — same typography (github-markdown.css), same scroll
  position, now with a cursor. **Done** (⌘E again) returns to reading.
- Beta off ⇒ today's section editor, untouched. Beta on ⇒ Edit opens
  the rich editor; **Edit Source** still opens the whole file raw as
  the escape hatch.
- Local files only. Diff, blame, compare, and PR/remote documents
  never enter edit mode.

## §2 Engine

ProseMirror core + `prosemirror-markdown` (MIT), vendored as bundles
next to marked/mermaid/KaTeX — no package dependencies, loads under
the page's `script-src 'self'` CSP. Our schema extensions: GFM tables,
task items, callouts, footnotes, image objects, raw blocks, margin-note
anchors.

Why not Milkdown/TipTap (deep dependency graphs to vendor), Lexical
(weak Markdown round-trip), or hand-rolled contenteditable (years of
edge cases).

**Feasibility spike first**: the vendored bundle running inside the
existing page; one fixture document parsed, untouched, and serialized
byte-identical; a one-word edit producing a one-line diff. If the
spike fails, stop and rethink before building anything on it.

Spike result (2026-08-28): PASSED in headless Chrome. esbuild bundles
prosemirror-{model,state,view,transform,history,keymap,commands,
inputrules,schema-list,tables,markdown} + markdown-it into one 520 KB
IIFE (`PM`), no eval; an 8-block fixture (heading, emphasis/code/link
paragraph, list, fenced code with a blank line, multi-line quote, HTML
comment, double blank line, reference link + definition) reassembles
byte-identical untouched and a one-word edit changes exactly one line.
The splitter must keep the exact blank-line gaps between blocks
(leading, between, trailing) — the Swift splitter drops them, so the
payload carries gaps alongside blocks.

## §3 Source preservation — minimal diffs

- The file splits into top-level blocks with line ranges via the
  existing `MarkdownBlocks` splitter. Each block parses into editor
  nodes tagged with its block id and original source text.
- A block becomes **dirty** only when a transaction touches its range
  (tracked through ProseMirror's mapping).
- On save: untouched blocks are emitted verbatim; dirty and new blocks
  are serialized (GFM serializer: tables, task items, callouts,
  footnotes); deleted blocks vanish. Reference-style links, unusual
  list markers, HTML, front matter, and `<!-- note -->` comments in
  untouched blocks never change.

## §4 Raw islands

Fenced code, Mermaid, math, HTML blocks, and front matter are
monospace editing areas inside the document with a language label;
Mermaid re-renders its preview when the block loses focus. Diagram
editing proper is a follow-up (all Mermaid diagram types at once).

## §5 Formatting chrome

- **Floating toolbar** on selection: bold, italic, code, link, heading
  level, and the callout type where applicable.
- **"/" insert menu** on an empty line: table, code block, image,
  callout, footnote, task list, divider.
- Typed Markdown shortcuts convert as you type (`# `, `- `, `1. `,
  `> `, `**…**`, `` `…` ``).
- Keyboard: ⌘B/⌘I/⌘K, ⌘Z/⇧⌘Z through ProseMirror history.

## §6 Margin notes stay live

The note rail anchors to blocks by id in both modes (editor top-level
nodes render with the same `data-pm-block` identity the renderer
emits), so adding, replying, and resolving work while editing. Notes
follow their block through moves and are re-emitted after it on save.
Deleting a block deletes its notes; undo restores both.

## §7 Tables

Cell editing; Tab/Shift-Tab between cells; Enter in the last row adds
a row; hover handles and context menu for add/remove row/column;
per-column alignment; fixed header row; **paste from spreadsheet**
(tab-separated cells create or fill a table); **sort by column** (click
a header, writes the new order). No column widths — Markdown has none.
Pipes inside cells escape on serialization.

## §8 Rich v1 set

Task lists (checkbox items, Enter continues), callouts (`> [!NOTE]`
… with a type picker: NOTE / TIP / IMPORTANT / WARNING / CAUTION),
footnotes (inline references with definitions managed at the end),
images as objects with alt/caption editing. Image resizing writes an
HTML `<img src width>` (GitHub renders it) — flagged in the beta notes
as the one construct that leaves pure Markdown.

## §9 Images on paste and drop

- Per-Location **Images folder** setting, auto-detected from where the
  repo's existing Markdown already references images (most common
  directory wins), overridable from the Location's context menu;
  first paste with no precedent proposes `<document>.assets/`.
- A dropped or pasted file already inside the Location is linked
  relatively, never copied.

## §10 Saving

Settings › Editing › **Save edits**: Automatically (default — debounced
write-through, one undo-history snapshot per edit session, Revert Last
Edit keeps working) or **When I press ⌘S** (unsaved-changes prompt on
close / Done).

## §11 Settings and gating

Settings › Editing › **Rich editor (beta)** — off by default. The
toggle only changes what Edit opens; nothing else moves.

## §12 Out of scope

Diagram editing, PR/remote documents, collaborative editing, editing
inside compare/diff views, WYSIWYG for HTML blocks.

## §13 Verification

- **Round-trip corpus** in the headless-Chrome harness
  (`scripts/render-check.sh` gains an editor pass): every fixture must
  serialize byte-identical untouched; scripted edits (word change,
  new row, moved block, deleted block with a note) must produce the
  expected minimal diff.
- Live taste trials with the drive scripts (floating toolbar, slash
  menu, table handles, note rail in edit mode), then Josh's own live
  check before release.

## §14 Implementation notes (2026-09-02)

- **Notes ride on nodes, not on ids.** §6 planned to anchor the note
  rail by block id; instead every block-level node carries a `notes`
  attribute (the parsed `<!-- note -->` comments that follow it, or
  precede it for a file-level note). Cards are widget decorations after
  the owner; add/edit/delete are transactions on that attribute, so
  undo restores block and notes together and a moved block takes its
  notes along. A block that is nothing but notes merges into the block
  before it (or after it, at the top of the file) so the pair is one
  range — untouched together, written back verbatim together.
- **Soft breaks are nodes.** A hard-wrapped paragraph keeps its line
  breaks as `soft_break` nodes (rendered as a space) rather than "\n"
  in the text, which the DOM re-read on typing would turn into spaces
  and re-flow the whole paragraph into one line. A one-word edit in a
  wrapped paragraph stays a one-line diff.
- **Islands.** Fenced code renders through a node view with a language
  label; a Mermaid fence keeps a preview under the source that
  re-renders when the caret leaves. `$$…$$` blocks stay raw ("math").
  The node view ignores mutations outside its content — the preview's
  own DOM changes must not trigger a re-read.
- **Tables.** No icon bar (Josh 2026-09-02: icons weren't clear before
  hovering). Like Notion, Craft, and Pages: a handle above the caret's
  column and one beside its row, each opening a menu of words (add
  left/right or above/below, delete, align, sort), "+" pills on the
  table's right and bottom edges that append a column or row, and the
  same words in the right-click menu. Column alignment writes every
  cell in the column (the serializer reads the header row); sort
  rebuilds the table node (numeric when both keys parse). Spreadsheet
  paste (tab-separated text) fills from the current cell, growing the
  table, or inserts a new table.
- **Escape hatch.** "Edit as Markdown" (right-click, ⇧⌘M) turns the
  caret's block into a raw island holding its own source (the original
  text when the block is untouched, its notes staying as cards);
  "Render Markdown" parses it back. This replaces §1's whole-file "Edit
  Source", which never existed as an editable surface (the source view
  is read-only).
- **Images (§9).** Pasted bytes and dropped files go to Swift over the
  bridge; `ImagesFolder` (Core) picks the destination — the Location's
  override (context menu › Images Folder…), else the folder the
  Location's Markdown references most, else `<document>.assets/` — and
  the editor inserts the relative link. A Finder drop of a file already
  inside the Location links it in place. The editor displays relative
  images through the same local scheme the renderer uses.
- **Manual save (§10).** Leaving edit mode with unsaved changes asks
  Save / Don't Save / Cancel; switching documents still saves.
- **Callouts** are `blockquote` nodes with a `kind`; the title is a
  type picker. **Footnotes** are `footnote_ref` (inline atom) and
  `footnote_def` (block) nodes; consecutive definitions arrive from
  markdown-it as one paragraph and are split on soft breaks. **Images**
  show an alt/title strip when selected; resizing is not built.
- The page has no `window.prompt` (Swift implements no JS panel), so
  link and image addresses use an inline prompt.
- `RenderPageStore` mirrors a fixed list of assets into the render
  directory; the editor script was missing from it and loaded silently
  as nothing — a test now keeps the list in step with the pages.
- Verification: `scripts/editor-check.sh` (headless Chrome) runs every
  fixture under `scripts/editor-check/fixtures` through the editor:
  untouched byte-identical, a one-word edit changing one line, plus
  per-fixture expectations (`expect.json`: note cards, callouts,
  footnotes, a scripted spreadsheet paste). `VERBOSE=1` prints the
  probe output.
