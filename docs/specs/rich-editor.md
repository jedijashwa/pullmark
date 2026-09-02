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
