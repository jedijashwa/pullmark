# Review conversations

Threads wherever you read, an honest review state, and an in-place
composer.

## Motivation

PullMark's reason to exist is reviewing documentation PRs as rendered
documents. The review machinery shipped across v0.16–v0.21 — inline
threads in the diff views, Reply/Resolve, a local draft queue with
Comment / Approve / Request Changes — but the person it was built for
reported "I can't see existing comment threads," and a live
verification run explains why:

- Threads render **only** in Rendered Diff mode. The Result view — the
  natural way to *read* a documentation PR — shows a clean document
  with zero indication that any conversation exists. Source Diff shows
  nothing either.
- Nothing anywhere (sidebar, toolbar, top of file) says a file *has*
  comments; the only way to find a thread is to scroll onto it.
- Threads on the PR's non-Markdown files have no surface at all ("3
  Markdown files changed · 11 other files not shown" — comments on the
  11 simply vanish).
- For a brand-new file, Rendered Diff intentionally drops per-block
  added styling, so it looks identical to Result and the view picker
  appears broken.
- The staging model is invisible: "Add to Review" vs "Comment Now"
  live only inside a modal sheet, the draft count appears only on the
  PR overview page, drafts are in-memory (lost on quit), and a pending
  review saved to GitHub becomes undetectable in the app.
- The composer itself is a modal sheet stacked with a line-range
  picker, three differently-scoped submit buttons, and a suggestion
  variant — it rips the reviewer out of the document they're reading.

The itch strikes in both directions: reading a PR others have
discussed (the discussion is invisible) and following up on one's own
review (no way to see responses or continue threads without a
browser). This spec makes the existing machinery visible, truthful,
and pleasant rather than adding new review semantics.

## Research summary

Full survey by the feature-researcher agent, July 2026. Highlights:

- **GitHub's own rendered-Markdown view supports no commenting at
  all** — a long-standing, complained-about gap (community discussions
  [#160981](https://github.com/orgs/community/discussions/160981),
  [#186730](https://github.com/orgs/community/discussions/186730)).
  Threads in a rendered view are differentiation, not catch-up.
- Every major document tool converges on one pattern for comments in
  reading flow: **a small marker/highlight at the anchor, collapsed by
  default; the thread opens on click; resolved threads leave the page
  but stay reachable via a filter** — Google Docs (minimized-comments
  mode), Word modern comments (contextual view hides resolved),
  Confluence (highlight removed on resolve), Notion (Minimal mode =
  count badge), Pages (margin square + highlight), Figma (pins that
  cluster with counts). Nobody puts always-expanded thread cards in a
  reading surface.
- For pending-review state, the winning pattern is **one persistent
  control that is both the status and the way to finish**: GitHub's
  sticky "Finish your review" button with a pending-comment count
  badge; Graphite's header button whose label morphs to "Finish
  review"; Gerrit's highlighted Reply whenever unpublished drafts
  exist. The VS Code GitHub PR extension is the cautionary tale — its
  submit action is buried and users flee to the browser (issues
  [#1078](https://github.com/microsoft/vscode-pull-request-github/issues/1078),
  [#8751](https://github.com/microsoft/vscode-pull-request-github/issues/8751)).
- Composer prior art: GitHub and VS Code both use an **in-flow inline
  composer** that expands beneath the clicked line — no modal, the
  document stays visible. Multi-line targeting is a gesture (drag /
  shift-click line numbers), not a widget. Suggestions are a toolbar
  button inside the composer that pre-fills a ```suggestion fence, not
  a separate mode. The action row is exactly two buttons whose primary
  follows review state ("Start a review" → "Add review comment", with
  "Add single comment" demoted to secondary). Apple HIG ranks sheets
  last for transient content-anchored input (sheets are always modal
  on macOS); Pages and Xcode both anchor comment UI to the content.
- The annotation literature (MIT NB lineage; AnchoredAI,
  [arXiv 2509.16128](https://arxiv.org/pdf/2509.16128)) supports
  *visible anchors near the text* over detached feedback; it does not
  adjudicate margin-rail vs popover — the marker recommendation rests
  on industry convergence.
- GitHub vocabulary, verbatim from its docs: "Add single comment",
  "Start a review", "Add review comment", "Finish your review",
  "Pending" label, "Submit review", "Comment / Approve / Request
  changes", "Resolve conversation", "Abandon review". PullMark should
  match 1:1 wherever concepts map.

## The design

### 1. Thread markers in the Result view

- Anchored, live, new-side (RIGHT) threads render as a **small comment
  badge in the right margin**, vertically aligned with the anchored
  block, showing the comment count. Multiple threads on one block
  cluster into a single badge with a combined count (Figma-style); the
  anchored line range gets a subtle tinted highlight.
- Clicking the badge (or the highlight) expands the existing thread
  card — the same `threadsEl` markup, Reply and Resolve/Unresolve
  buttons, and `threadReply`/`threadResolve` bridge messages the diff
  view uses today — inline beneath the block. Clicking again (or Esc)
  collapses it.
- **Default on; resolved threads hidden.** A quiet control at the end
  of the document — "N resolved conversations" — reveals them on
  demand, and View ▸ Show Resolved Conversations mirrors it (with a
  rebindable shortcut, per the every-shortcut-has-a-menu-item rule).
- Anchoring uses the same machinery as the diff views: threads map to
  rendered blocks via the source line ranges blocks already carry (the
  blame overlay uses the same data). **No nearest-block guessing** —
  a misanchored highlight in a reading view is worse than an absent
  one. Old-side, outdated, and unanchorable threads do not mark prose;
  they remain in the diff views and are included in the file's comment
  count so nothing is silently missing.
- Source Diff mode gets the same treatment at patch-line granularity:
  a gutter badge on commented lines, click to expand.

### 2. Comment-presence signals

- **Sidebar file rows** in a PR show a small comment-count badge
  (unresolved count; the data is already grouped per path).
- **PR overview** gains one line when applicable: "N review comments
  on files not shown in PullMark" — honesty about non-Markdown files.
- In the diff views, **resolved threads render collapsed** to a
  one-line header (author · "Resolved") that expands on click,
  replacing today's full-prominence expanded cards.

### 3. One morphing review control

- A **toolbar button on every PR surface** (overview and file views):
  - No pending review: **"Review changes"**.
  - Pending comments exist: **"Finish your review · N"** with a badge
    tint.
- Clicking it opens the review surface (today's review section:
  summary field, pending-comment list, submit actions) as a popover.
  Verdict buttons match GitHub's casing: **Comment / Approve /
  Request changes**. **Verdicts appear only here, never in the
  composer** — the VS Code failure is finishing leaking into the
  composer and vice versa.
- Every pending comment, wherever it appears (review popover, at its
  anchor in diff or Result views), carries a yellow **Pending** tag.
- Menu item + rebindable shortcut for "Review changes", per
  convention.

### 4. Pending reviews: GitHub is the source of truth

- On PR load, fetch the viewer's pending review if one exists
  (`GET /pulls/{n}/reviews`, `state == PENDING`, viewer-authored) and
  its comments; they populate the pending list and appear at their
  anchors with Pending tags. A review started on github.com or saved
  from PullMark is fully visible and finishable in-app.
- Adding a review comment syncs it into the server-side pending
  review (creating one if absent) rather than holding it only in
  memory; the count on "Finish your review · N" is therefore true by
  construction and reviews survive quits and device hops.
- Local persistence (disk) covers composer text in progress and
  comments not yet accepted by the server (offline, API failure),
  keyed by repo/PR/commit; on reconnect they reconcile into the
  server pending review. Failures surface, never silently drop.
- "Save as Pending on GitHub" disappears as a separate button — the
  model subsumes it. **"Abandon review"** (GitHub's term) appears in
  the review popover to discard the pending review server-side, with
  confirmation.
- Submitting uses the existing submit path; "Add single comment"
  continues to post immediately and never touches the pending review.

### 5. In-page inline composer (replaces the sheet)

- The composer **expands beneath the target block inside the page**,
  styled as a sibling of the thread cards — the document stays visible
  and the composer scrolls with content. The existing hover
  affordances collapse to one: the bubble opens an empty composer; the
  pencil opens the same composer with a ```suggestion fence pre-filled
  from the block's current lines and focused (the separate suggest
  sheet retires).
- Contents: text area; a compact toolbar with one **"Add a
  suggestion"** button (pre-fills the fence; disabled on the old
  side); a static range caption ("Lines 12–14, new"); Cancel; and a
  two-action row.
- **Range narrowing is a gesture, not a widget**: default anchor is
  the whole block; selecting text within the block before invoking
  Comment narrows the range (blocks carry source line ranges; a
  selection spanning blocks clamps to the first block and the caption
  shows the clamped range). In Source Diff, click / shift-click line
  numbers, GitHub-style. The line-picker widget is retired.
- Actions, with state-following primary:
  - No pending review: primary **"Start a review"** (⌘↩), secondary
    **"Add single comment"** (⇧↩ stays as today's ⇧⌘↩).
  - Pending review exists: primary **"Add review comment"** (⌘↩),
    same secondary.
  - "Add to Review", "Comment Now", and "Suggest Now" labels retire.
- **Click-away saves, Cancel discards** (HIG nonmodal rule): clicking
  outside the composer preserves the typed text on that block and
  restores it on reopen; only Esc-with-empty-text or the explicit
  Cancel discards.
- Validation is inline and contextual: the primary disables with an
  explanation only when the resolved range falls outside the PR diff
  (replacing the always-visible "Comments must target lines…"
  caption). In Result view, commenting is offered on blocks that map
  into the diff; on others the affordance explains why not.
- Replies keep their current lighter flow but move in-page too: the
  Reply button expands a mini-composer inside the thread card.

### Emoji reactions on comments

- Each published comment card shows **reaction chips** (emoji +
  count) at its foot for any reactions present; chips the viewer has
  pressed are tinted. Clicking a chip toggles the viewer's reaction.
- An **add-reaction affordance** (smiley badge) on hover opens a
  compact picker limited to GitHub's eight canonical reactions
  (👍 👎 😄 🎉 😕 ❤️ 🚀 👀) — the chips-plus-picker pattern GitHub,
  Slack, and Messages share.
- Data: the REST comment payload already carries a `reactions`
  rollup; viewer state (`viewerHasReacted`) folds into the existing
  GraphQL thread-metadata query via `reactionGroups`. Writes use
  `POST`/`DELETE /pulls/comments/{id}/reactions` (or the matching
  GraphQL mutations).
- **Pending comments show no reaction UI** — GitHub does not support
  reactions on unsubmitted comments (platform behavior).
- Chips render wherever thread cards do (diff views, Result view,
  review popover) and stay visible on collapsed resolved-thread
  headers only as a count-free omission — expanding shows them.

### 6. New-file clarity

The added-file experience keeps the existing "New file — everything
here is added" note; with markers, counts, and the review control now
present in both Rendered Diff and Result, the two views stop being
indistinguishable in practice. No change to the view picker itself.

## Interactions with existing features

- **Theming / custom CSS**: markers, highlights, Pending tags, and the
  composer take colors from theme variables; a design-review pass
  covers every built-in theme, light and dark.
- **Zoom**: markers and composer live in-page, so they scale with
  document magnification like all other content.
- **Content width (Standard/Wide/Full)**: margin badges sit in the
  gutter outside the content column; at Full width they overlay the
  right edge — verified at all three settings.
- **Blame**: blame gutter and margin badges occupy opposite sides;
  thread highlight and blame hover tints must compose visibly.
- **Split diff layout**: badges attach to the new-side column;
  composer expands full-width beneath the row pair.
- **Editing mode**: entering edit mode collapses open thread cards and
  composers; a draft-in-progress on the edited block is preserved.
- **Suggestions**: absorbed into the composer's "Add a suggestion"
  button; suggestion rendering in threads is unchanged.
- **Exports (PDF / self-contained HTML)**: never include markers,
  threads, or composer chrome — exports are the document only.
- **Quick Look**: unaffected (local files have no PR context).
- **Find / cross-file search / outline**: thread and composer text is
  excluded from find-in-page and stats; outline unaffected.
- **Keyboard**: every new control gets a menu item and appears in
  Settings ▸ Keyboard as rebindable (existing convention).
- **Refresh loop**: the existing guard that avoids yanking an
  in-progress review extends to open composers and the pending fetch.
- **Comments-unavailable banner**: unchanged; when fetch fails, Result
  view shows the banner too (it currently cannot).
- **Persistence**: composer drafts and unsynced comments store under
  the app's existing UserDefaults/Application Support domain — bundle
  ids untouched.

## Out of scope

- Implementation (separate, separately-approved effort).
- PR timeline / issue-conversation threads beyond the existing
  overview comment box.
- Editing or deleting already-published comments, and notifications.
- Reactions on PR-level (timeline) comments — this wave covers review
  comments only.
- Rendering non-Markdown files (their comments get counted, not
  displayed).
- Multi-account or reviewing-as-a-team concerns.

## Open questions for implementation time

- Exact API mix for incremental pending-review sync: REST creates a
  pending review with comments in one shot, but adding to an existing
  one likely needs GraphQL `addPullRequestReviewThread`; commit-SHA
  and ordering pitfalls need a spike before committing to "sync on
  every add".
- In-page composer means owning focus, Esc, undo, IME, and dictation
  inside WKWebView — needs early testing with real input methods.
- Marker/cluster visuals per theme, and the density expansion (badge →
  list) when many threads share a block: design-reviewer pass on
  mockups before build.
- Reaction picker presentation (in-page popover vs native menu) and
  whether reaction toggles need optimistic UI given API latency.
- Whether Source Diff gutter badges land in the same wave or trail the
  Result-view work.
- Migration: what happens to an in-memory draft queue from a session
  that predates the sync model (likely trivial — first sync uploads).

## Verification notes

Ground truth for this spec came from a live repro (dev build driven
against PR #1, which holds a real two-comment resolved thread on
`docs/demo.md` line 53): threads render correctly in Rendered Diff,
and are confirmed absent with zero indication in Result and Source
Diff. The implementing PR should re-run that scenario plus: pending
review started on github.com appears in-app; quit/relaunch preserves
the review; "Finish your review · N" matches GitHub's count; added
file shows markers in both views; composer round-trips a multi-line
comment narrowed by text selection.

The implementing PR should say "Closes #ISSUE" (issue number filled in
once the issue exists).
