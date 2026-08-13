# Nested comment targets

Comments and margin notes land on the unit the reader is pointing at — a
list item or a table row — instead of the whole list or table.

## Motivation

One of PullMark's heaviest users reports that the commentable block often
isn't the thing they mean. Blocks are blank-line-separated Markdown
blocks, so a bulleted list is one block: hovering any item offers a
comment on the entire list, and the note or review comment then reads as
being "about the list" when it was about one item.

Block-level commenting stays — that decision holds. The change is to
recognize that inside container blocks, the meaningful block is the
nested one: the `<li>`, not the `<ul>`. This applies to all three
commenting surfaces — adding PR review comments, displaying existing PR
comment threads, and margin notes (both adding and displaying).

## Research

Field survey of comment-anchor granularity (full report in the PR
description's provenance; key sources inline):

- **The innermost item is the shipped norm.** In Notion, each list
  item, to-do, and toggle *is* its own block — "the whole list" is not
  a commentable unit at all, and the hover affordance (⋮⋮ / 💬) targets
  the block under the pointer
  ([Notion Help](https://www.notion.com/help/comments-mentions-and-reminders),
  [API: comments anchor to a page or a child block](https://developers.notion.com/docs/working-with-comments)).
- **Row is the accepted floor for tables.** Coda is the only surveyed
  tool with a shipped structural table anchor, and it is the row:
  "you can't leave a comment on a single cell… only on the entire row"
  ([Coda Help](https://help.coda.io/hc/en-us/articles/39555917053069-Comment-on-Coda-docs)).
  No block-model tool ships cell-level block comments; Notion and
  Confluence route cells through inline text instead.
- **Widening is selection- or drag-driven everywhere.** GitHub widens a
  line anchor by dragging or shift-clicking across lines
  ([changelog](https://github.blog/changelog/2020-02-21-a-new-interaction-for-multi-line-pull-request-comments/));
  Notion widens by selecting text across blocks; Coda selects the row
  first. No tool offers a hover-time widen/narrow modifier — that
  pattern would be novel, and this spec doesn't attempt it.
- **Showing the target matters.** Word's modern comments use two-way
  hover emphasis between anchor highlight and comment card
  ([MS Support](https://support.microsoft.com/en-us/office/using-modern-comments-in-word-edc6ae71-0a2d-49fe-8faa-986f1e48136a));
  Notion's handle aligns to the hovered block's own edge and indent so
  position itself names the unit.
- **The cautionary tale is GitHub's rich diff**: it renders prose but
  anchors comments to raw diff lines, the two were never reconciled,
  and rendered-view commenting simply doesn't exist
  ([community #160981](https://github.com/orgs/community/discussions/160981)).
  PullMark's model — source-line anchors stamped onto rendered
  structure — is exactly the reconciliation that gap calls for, and
  finer stamps strengthen it.
- **Fragile-anchor warning**: Confluence's string-matched highlights
  break on duplicate header text and macro content
  ([CONFSERVER-55270](https://jira.atlassian.com/browse/CONFSERVER-55270))
  — evidence for positional/structural anchors over content-matched
  ones, which is what line-range stamping is.

## The unit map

| Rendered block | Comment target (v1) |
| --- | --- |
| Paragraph, heading, code fence, math, mermaid, HR | Whole block (unchanged) |
| Bulleted / numbered / task list | Each **list item**; the innermost item under the pointer wins. An item's range is its full source extent, nested children included. |
| Table | Each **body row** (one source line). The header row targets the header + delimiter pair. |
| Blockquote | Whole block (v1 — see Out of scope) |
| Front matter | Whole block (unchanged) |

## Anchor mechanics

Sub-units get their own attribute, `data-pm-sublines="start-end"`,
stamped in the same pass as `data-pm-lines` (`annotateBlockLines`
recursing into `list`/`table` tokens — the vendored marked exposes
`list.items[].raw` per item, and a table row *k* is source line
`start + 2 + k`; both verified against the vendored build).

A separate attribute — rather than nested `data-pm-lines` — keeps the
six existing consumers (copy-as-markdown, blame gutter, line numbers,
thread markers, edit line-shifting, selection mapping) provably
untouched: none of them can see the new stamps. Only the commenting
surfaces read both attributes, innermost match first.

## Surface: adding PR comments (Result view)

- The hover affordance attaches per sub-unit. Hovering inside an item
  shows the rail bubble aligned to that item; the comment range is the
  item's lines, clamped to the diff runs per unit — so in a partially
  changed list, changed items are commentable and unchanged ones show
  the existing "not part of the diff" state. That is strictly more
  precise than today's whole-block verdict.
- Widening still works: select text across several items, then click
  any bubble — the existing selection-narrowing (`narrowRangeTo`)
  computes the covered lines. No new drag UI needed.

## Surface: existing PR threads (Result view)

- Thread-to-block resolution (`blockFor`) resolves the **deepest**
  annotated element containing the thread's anchor line: the badge
  aligns to the item, and the anchor tint covers just that item or row.
- A thread whose anchor range spans several sub-units tints each
  intersecting unit; the badge sits on the first.

## Surface: diff views

Sub-unit targets apply only where the rendered structure *is* one
side's source: **added** and **unchanged** segments (new side).
Modified segments (word-diff merged rendering mixes old and new lines)
and removed segments keep block granularity.

## Surface: margin notes

**Adding, list items.** The note comment is inserted as an item
continuation — directly after the item's last source line, indented to
the item's content indent, with **no** surrounding blank lines:

```markdown
- First item
  <!-- note @josh: too vague -->
- Second item
```

Verified against the vendored marked: the indented comment stays inside
the item and the list stays tight and whole. (A column-0 comment splits
the list in two — restarting `1.` numbering — and blank-line separators
flip a tight list loose; both are why the existing `inserting()`
placement can't be reused. `MarginNotes.inserting` gains a tight,
indented mode.)

Constraint: the note grammar tolerates at most 3 leading spaces (4 is an
indented code block). Items whose content indent is ≤ 3 — the top-level
items of `-`/`*`/`+` (indent 2) and `1.` (indent 3) lists — get in-item
notes. A deeper nested item anchors to its top-level ancestor item.
Documented, not hidden.

**Adding, table rows.** A comment cannot live inside table syntax at
all, so a row note inserts after the whole table (placement unchanged)
with the row auto-quoted into the composer seed (`> | a | b |`) — the
same convention selection-quoting already uses to point at a sentence.
The quote tells humans and agents which row, with zero format changes.

**Displaying.** A note comment inside an `<li>` renders its card inside
the list, as a marker-less `<li class="pm-note-item">` immediately after
its item (a bare `div` between `li`s is invalid HTML). Notes elsewhere
render exactly as today. The existing card-hoisting fallback (comment
node inside an arbitrary element → card after the enclosing block)
remains for anything unexpected.

**Format documentation.** The agent-instructions copy
(`MarginNotes.agentInstructions`, Settings, and
pullmark.app/docs/experimental/margin-notes) gains one line: a note may
sit inside a list item, indented to the item's content, and should be
deleted with its indentation.

## Target visibility

While a unit's bubble is showing, the unit gets a subtle background
tint, so "item vs whole list" is always legible before clicking.
(Bubble position alone is ambiguous for one-line items adjacent to the
list edge.)

## Interactions with existing features

- **Hover probe (0.29.2 flicker fix):** the probe resolves
  `closest(".pm-block, .pm-commentable")`, which naturally finds the
  innermost commentable; the exclusivity latch and sticky-claim carry
  over. Needs live cursor re-verification — same bar as 0.29.2.
- **Copy as Markdown, blame, line numbers, editing:** untouched by
  construction (attribute separation).
- **Block editing:** sub-stamps are re-created when an edited block
  re-renders and re-stamps; nested elements never get `pm-editable`.
- **Exports:** the sub-unit tint classes and `pm-note-item` wrappers
  join the existing strip list (`pm-annotation` already covers cards).
- **Diff/blame history of note-bearing lists:** adding an in-item note
  makes the list block read as modified against older revisions — same
  as any note edit today, just inside a block instead of beside one.
- **Menu-driven note composer** (Add Margin Note): unchanged — it
  targets the block nearest the viewport top.
- **Quick Look, zoom, reading themes:** no commenting surface — no
  interaction.

## Out of scope

- Arbitrary text-range anchors (Google-Docs-style). Blocks stay the
  model.
- Table **cells**, code-fence **lines**, blockquote internals.
- A drag-across-items multi-select UI — selection + bubble covers it.
- Grammar extension for notes inside deeply nested items (indent ≥ 4).
- Split-view / modified-segment sub-targets in diffs.

## Open questions (implementation time)

- `pm-note-item` card styling: indent the card to the item's text, or
  keep the full-width card look?
- The rail-zone probe's fractional x-candidates (`width * 0.15`) can
  land in a list's left padding where no commentable sits — confirm the
  candidate ladder still resolves the item, or add a candidate.
- Should hovering a table-row note's bubble highlight the quoted row
  (fuzzy match against the quote)? Nice-to-have, not v1-blocking.
- Whether the header-row target deserves a distinct tooltip ("Comment
  on the table header").
