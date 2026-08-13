# Review discussion on the PR overview

The PR overview gains a discussion list of every review thread on the
pull request — including threads on files PullMark doesn't render — so
a mostly-Markdown PR with some code changes can be reviewed without
bouncing to the browser.

## Motivation

One of PullMark's heaviest users reviews PRs that are heavily Markdown
(the app's sweet spot) but carry some code changes. Comments on the
non-Markdown files currently have no surface at all beyond the
overview's one-line count ("N unresolved review comments on files not
shown in PullMark") — the review ping-pongs between PullMark and
github.com. The decision not to render non-Markdown files stands; the
missing piece is seeing and following the *conversations* on them.

## Research summary

Full field survey in the session record; the load-bearing findings:

- **GitHub web is the only convention.** No shipping native macOS
  client shows review-thread cards with code excerpts — Trailer,
  Gitify, Fork link out with zero context; VS Code's PR extension
  jumps into real diff editors; Xcode 26 dropped its PR UI entirely.
  GitHub's Conversation tab and Mobile are the pattern to follow.
- **`diff_hunk` (REST) is shaped for excerpts**: it runs from the hunk
  header down to *exactly the commented line* — the anchor line is
  always the last line. It reflects the original diff (stale for
  outdated threads) and is unbounded (30+ lines observed), so clamp
  the tail; GitHub's own unclamped truncation draws complaints, as
  does its omission of line numbers on the card
  ([community #130618](https://github.com/orgs/community/discussions/130618)).
- **Outdated detection**: REST `line == null` (never `position` — an
  outdated comment with `position: 1` was observed live). PullMark's
  `ReviewThread.isOutdated` already keys off exactly this.
- **Resolved threads collapse, never hide** — hiding is what users
  file angry threads about. PullMark's collapsed-resolved cards
  already match.
- **The robust deep link is the comment's own `html_url`**
  (`…/pull/N#discussion_r<id>`): the Files-changed anchor form is
  undocumented and lands nowhere for outdated threads, which GitHub
  removes from that tab.
- **Highlighting**: GitHub highlights even tiny excerpts (since 2014);
  highlight.js deliberately has no extension→language map — hosts
  maintain their own (GitHub uses Linguist's `languages.yml`).

## The design

**Placement.** A "Review discussion" section in the overview's
existing web page, after the description. The section is part of the
same rendered document surface — reusing the thread cards, reply
composers, reaction chips, resolve links, comment-Markdown rendering,
and vendored highlight.js at zero size cost.

**Content.** Every review thread on the PR — Markdown and
non-Markdown files alike (one complete list; the file views remain the
richer surface for Markdown threads). Grouped by file, each group a
monospace path header with its unresolved count. Review threads only:
the issue-comment timeline is out of scope, and the viewer's pending
comments stay in the review popover.

**The thread card** is the existing card plus:

- The thread's line label ("Line 41 (new)", "Outdated — was line 12",
  "Whole file") — on the card, fixing GitHub's most-complained-about
  omission.
- A passage preview above the comments, built from the last ≤ 4
  content lines of `diff_hunk` (the commented line is always the hunk's
  final line, so the tail keeps the anchor visible). **Markdown files
  default to a rich preview** — the passage rendered as Markdown,
  showing it as it reads, with change highlighting matching the main
  rendered-diff view's bands: contiguous added lines render as a
  green-banded fragment, deleted lines red, context plain. Code files
  show the raw hunk
  tail: +/- lines keep their diff tinting and the code is
  syntax-highlighted via a small curated extension→language map into
  highlight.js. No preview for whole-file threads or when the hunk is
  absent. Outdated threads keep theirs (it *is* the passage the
  comment was about) under the honest "Outdated" label.
- One action per thread: Markdown file → **View in File**, which opens
  that file's rendered diff and scrolls to the thread, expanded;
  non-Markdown → **Show on GitHub**, opening the root comment's
  `html_url` in the browser.

**Resolved** threads render visible-but-collapsed (the existing
one-line header, expandable per card) — the field-evidence pattern.
No bulk show/hide control in v1: per-card expansion covers it, and a
section-scoped toggle plus View-menu mirroring can graduate with the
feature if beta feedback asks for it.

**The setting.** Settings → Experimental → **"Review discussion on
the PR overview"**, beta level (visible without the alpha gate), off
by default (`pm.prDiscussionEnabled`). While on, the overview's "N
unresolved review comments on files not shown" line retires — the
list is that count's surface. Off: everything exactly as today.

## Interactions with existing features

- **Result view / file views**: unchanged; the discussion list links
  into them (View in File) but owns nothing they show.
- **Resolved visibility**: per-card expansion of collapsed resolved
  threads; the file surfaces' bulk toggle doesn't apply here (v1).
- **Reply / reactions / resolve**: existing bridge round trips work
  as-is (cards carry rootID); replies re-render via the normal reload.
- **Refresh loop**: new comments arrive with the session refetch and
  re-render the overview page like any model update.
- **Find bar**: the section is page content — find works over it.
- **Exports / print**: the overview page has no export surface; n/a.
- **Zoom, themes**: inherited from the page.
- **Demo mode**: the staged demo PR gains a code-file thread so the
  feature is demonstrable.
- **Sidebar**: non-Markdown files stay unlisted; the files-summary
  line keeps its "other files not shown" honesty either way.

## Out of scope

- Rendering non-Markdown files, in any form.
- Commenting on non-Markdown lines from PullMark (GitHub for that;
  replying to existing threads works).
- The issue-comment (conversation) timeline.
- Filtering beyond resolved-collapse (research: GitHub's own
  Conversation tab ships none; add on demand).

## Open questions

- Whether the hunk excerpt's 4-line clamp wants a "Show more"
  expander (defer until real hunks feel cramped).
- Whether View in File should prefer the Result view when the thread
  anchors to live lines (v1: rendered diff always — threads render
  there in every state, outdated included).
