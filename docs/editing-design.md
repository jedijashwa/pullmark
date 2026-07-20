# Full editing: design brief (draft for review)

The block-editor shipped in 0.13.0 is a stepping stone. The verdict that
started this project: *"How can I delete sections? add blocks? We need full
editing — the page itself writable."* This brief frames the reconception before any
code — the editing model deserves a decision, not a default.

## What "full editing" actually means here

The trick the seamless Markdown editors share: **the document is always rendered, and the block you're
touching temporarily reveals its source.** Type `## Heading` and it becomes a
heading when you leave it. No mode switch, no preview pane — reading and
writing are the same surface. For PullMark that thesis fits perfectly: we
already render everything; editing means making the rendered page writable.

## Non-negotiables (inherited from the product)

- Reading remains the default posture; a file never opens "in edit mode."
- Every write stays guarded and versioned (collision check, edit history,
  autosave/manual, commit/push flow) — the plumbing survives the redesign.
- The rendered pipeline (marked + extensions + themes + CSP) stays the
  single source of rendering truth. No second renderer to drift.
- Viewer features keep working mid-edit: blame, find, outline, word count.

## Architecture candidates

### A. Grown block editor (evolve what exists)
Blocks stay the unit, but editing becomes continuous: Enter at block end
creates a new block-editor below; Backspace at block start merges with the
previous block; a selected block can be deleted/moved; typing flows across
block boundaries by handing focus between per-block editors.
- **For:** incremental; block model, line mapping, guards all reuse; each
  keystroke touches one block's source (fast, safe).
- **Against:** cross-block selection/drag is hard; "it feels like fields,
  not a document" risk — the exact complaint being addressed.

### B. contenteditable document (fully WYSIWYG)
The whole rendered article becomes `contenteditable`; a Markdown⇄DOM sync
layer maps DOM mutations back to source (per-block, using the existing
`data-pm-lines` mapping to localize changes).
- **For:** genuinely one writable document — select across blocks, delete a
  section by selecting it, caret flows everywhere; the seamless feel.
- **Against:** contenteditable is notoriously fiddly (WebKit quirks, paste,
  IME, undo); DOM→Markdown inversion is the hard part — must be lossless
  for everything we render (tables, math, mermaid, footnotes). Highest
  effort, highest ceiling.

### C. Hybrid: source-reveal blocks (how the seamless editors really work)
Rendered blocks; the block containing the caret swaps to its raw source
(styled, monospace) in place, and re-renders on caret exit. Arrow keys and
clicks move the "revealed" block; Enter splits, Backspace merges — but
implemented over the source lines, not DOM inversion.
- **For:** the seamless feel without DOM→Markdown inversion (source is
  always the truth; render is per-block); add/delete/split/merge are line
  operations on the existing block model; incremental path from A.
- **Against:** cross-block *rich* selection still limited (source-level
  selection across revealed blocks is workable); caret handoff between
  rendered and source views needs care.

## Recommendation

**C**, built in two stages: (1) caret-driven source reveal + Enter/Backspace
split/merge + block add/delete — this alone answers "delete sections, add
blocks"; (2) smooth caret handoff and cross-block selection. Keep **B** as
the long-horizon ceiling if C's feel isn't seamless enough in practice — C's
per-block source mapping is a prerequisite for B anyway, so no work is lost.

## Decisions (2026-07-19)

1. **Source-reveal matches the bar** — raw `**bold**` inside the active
   block is the expectation. Architecture **C** confirmed.
2. **Editing is a mode** — explicit toggle; reading stays the default
   posture. No always-on editing.
3. **Tables/mermaid as source blocks is good enough for now** — real or
   assisted structured editing is future roadmap.

## Original questions (answered above)

1. Does source-reveal (you see raw `**bold**` while inside a block) match
   your expectation, or do you want inline rich editing (bold stays
   bold while typing) — i.e., is B the real bar?
2. Should editing be a mode (toggle, like the old plan) or always-on for
   local files? Always-on changes the reading posture.
3. Tables and mermaid: edit as source blocks (simple) or need structured
   editing eventually?

*Next step after your answers: prototype stage 1 of C in this worktree,
live-review it the way we did the last waves.*
