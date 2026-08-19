# The PR cockpit: review state, checks, and conversation

The PR overview gains the half of the loop it can't show today: where
the pull request stands. Review decision, per-reviewer states and
requested reviewers, CI check status, and a readable conversation
timeline — so a docs PR can be followed from open to approved without
a browser tab open beside the app. Display and conversation only: the
one write remains commenting, which the overview already has.

## Motivation

PullMark can *submit* a review but can't show what any review
concluded. The overview's header knows open/draft/merged/closed and
nothing else: no approved/changes-requested state, no reviewers, no CI
rollup — and the conversation field is post-only, so a comment posted
from PullMark is never seen again inside PullMark. The churn risk this
invites: "nice viewer, but I still need the browser open." Closing it
is the cheapest meaningful upgrade on the roadmap — the data is one
GraphQL query and two REST lists away — and pairing it with graduating
the review-discussion list (spec: pr-review-discussion) turns the
overview into the place a docs PR actually lives.

## Research summary

Field survey plus live GraphQL/REST probes against api.github.com
(schema introspection and real PRs); full report in the session
record. Load-bearing findings:

- **No native macOS client has a cockpit.** GitHub Desktop does
  checks well and nothing else; Tower shows a comments+commits
  timeline; Fork/Gitfox link out; the menu-bar apps (Gitify, Trailer,
  Pullwalla, PR Focus) are list-level. The bar is GitHub's own merge
  box and Conversation tab, filtered with VS-Code/Tower restraint.
- **`reviewDecision` is null** on repos with no required-review rule
  and no standing opinion (probed live): render nothing for null —
  GitHub shows nothing either. `APPROVED`/`CHANGES_REQUESTED`/
  `REVIEW_REQUIRED` are the only states.
- **`latestOpinionatedReviews`** returns one row per user reflecting
  their standing opinion; `latestReviews` additionally includes
  COMMENTED rows (probed — the schema descriptions differ only in a
  subordinate clause; the behavior difference is real).
- **`statusCheckRollup` lives directly on `PullRequest`** — no
  commits(last:1) detour — with `checkRunCountsByState` for counts
  without fetching nodes. SKIPPED checks don't break a green rollup
  (probed: 5 skipped + 2 success ⇒ rollup SUCCESS).
- **The whole cockpit query costs exactly 1 rate-limit point**
  (measured live): reviewDecision + reviewers + requests + rollup with
  50 contexts. A 60-second poll is 60 points/hour against 5,000.
- **Check-run transitions do not bump the PR's `updatedAt`** — CI
  status can never ride the existing update gate; it needs its own
  fetch on the shared timer.
- **Inline-only review submissions generate empty-body COMMENTED
  reviews** — 3–5 per PR observed on livetest. An unfiltered timeline
  is mostly blank grey cards; filtering them is load-bearing.
- **REST conditional requests are free**: a 304 on an ETag'd issue-
  comments GET consumes no rate limit (verified live), and the
  endpoint takes `since` for incremental fetches.
- **`requestedReviewer` nodes can be null** in live data (code-owner /
  Copilot request rows) — decode as optional or the whole query fails.

## The design

### Header: two capsules and a reviewer strip

A third header row in the existing `Label` + tinted-capsule idiom
(PRStatus's visual family — same shape, same 0.18-opacity tint).

**Review capsule**, from `reviewDecision`:

| State | Label | Symbol | Color |
|---|---|---|---|
| APPROVED | Approved | checkmark.circle.fill | green |
| CHANGES_REQUESTED | Changes requested | plusminus.circle.fill | red |
| REVIEW_REQUIRED | Review required | clock | yellow |
| null | *no capsule* | | |

**Checks capsule**, from the rollup counts, first match wins: any
failure-family state (FAILURE, ERROR, TIMED_OUT, CANCELLED,
STARTUP_FAILURE, ACTION_REQUIRED) → "Checks failed" red with the count
("2 of 7 failing"); anything non-terminal and not approval-gated →
"Checks running" yellow with a small indeterminate spinner (the HIG
idiom for unknown-duration work — not a static dot); only WAITING
gates outstanding → "Checks awaiting approval" gray; everything
SUCCESS/NEUTRAL/SKIPPED → "Checks passed" green. **No contexts at all →
no capsule**: repos without CI and fork PRs whose workflows await
approval both present an empty rollup, and "passed" would be a lie.

Clicking the checks capsule opens a popover: a flat list (no grouping —
docs PRs rarely carry 30 checks), failures first, then running, then
alphabetical (GitHub's own order); each row is state icon +
workflow/app name + check name + duration + a subtle "Required" tag
where `isRequired` says so; clicking a row opens its `detailsUrl` /
`targetUrl` in the browser. A footer link opens the PR's checks page.

**Reviewer strip**: avatars for everyone in
`latestOpinionatedReviews(writersOnly: false)`, each badged with their
state glyph (green check / red ±), then requested reviewers dimmed
with a dotted-circle badge — GitHub's sidebar convention. Teams render
as name chips. Tooltips carry the relative time ("approved 2 days
ago"). Commented-only participants stay off the strip — their words
appear in the timeline; the strip answers only "who approved, who
blocked, who's awaited." Avatars fetch through an ephemeral session
(fetched remote content stays purgeable); demo mode uses the
fixture's initials avatars.

### Conversation: the timeline

A "Conversation" section in the overview's rendered page, after the
description and before the review-discussion list. One chronological
list merging:

- **Issue comments** — the PR's timeline comments, as full cards.
- **Submitted reviews** with state APPROVED, CHANGES_REQUESTED, or
  DISMISSED — and COMMENTED only when the body is non-empty. A review
  card opens with a state line in GitHub's card grammar ("sam-ortega
  approved these changes" with the green check; "requested changes"
  with the red ±; "dismissed their review" grayed) above its summary
  body.

Filtered out: PENDING reviews (the viewer's own unsubmitted review —
the review popover remains its one surface) and the empty-body
COMMENTED noise. Excluded event types: commits, force-pushes, labels,
assignments, review-request events, cross-references — every minimal
client surveyed cuts repo mechanics and keeps human speech. Bot
comments stay, with a small "bot" tag: on docs PRs the CI bot's
comment is often the payload.

Issue-comment cards get full parity with review-thread cards:
Markdown rendering, reaction chips with viewer state, edit and delete
on the viewer's own comments. The plumbing differs — issue comments
mutate through `/issues/comments/{id}`, not `/pulls/comments/{id}` —
but the mutation surface and card chrome are the same, extended
through the existing `ThreadCardActions` seam. Reactions reuse the
existing GraphQL add/remove mutations (they act on any reactable node
id) and apply to review cards too. Review summary bodies render
read-only: editing one's own review summary is a rare act that stays
on GitHub.

**The composer moves in-page** to the foot of the Conversation
section, replacing the native text field currently floating above the
description — the bottom-of-thread convention every client shares.
Click-away drafts persist through the existing `ComposerDraftStore`
under the overview's pseudo-path. Posting folds the returned comment
into the timeline locally — the comments list lags fresh writes
(the documented 0.31.0 lesson; never refetch on mutation).

The timeline carries `pm-annotation`, so print, PDF, and HTML export
drop it with the rest of the non-content layer, exactly like the
discussion list and margin notes.

### Data plumbing

**One new cockpit GraphQL query** — `reviewDecision`,
`latestOpinionatedReviews(first: 20)`, `reviewRequests(first: 20)`,
`statusCheckRollup { state, contexts(first: 50) { totalCount,
checkRunCountsByState, nodes } }`, plus issue-comment meta
(node ids, `lastEditedAt`, `reactionGroups` with viewer state) via
`issueComments` pagination, following the thread-meta pattern. It is
deliberately a **separate query from thread-meta**: that query's
documented failure mode (a bad shape silently blanks all thread state
through a `try?`) must not couple cockpit and thread data — neither
can take the other down.

**Two REST lists**: issue comments (`per_page` 100, paginated, `since`
for increments, ETag conditional requests for free 304s) and reviews
(chronological, same pagination).

**Failure isolation.** A cockpit fetch failure keeps the last-known
header state and retries next tick — no banner, and it never trips
`commentsUnavailable`. A conversation fetch failure shows one quiet
inline row ("Conversation unavailable — retrying") without touching
review threads. `PRSession` gains the cockpit fields alongside the
existing ones; all-new nullable so old snapshots restore clean.

### Refresh: one 60-second cadence

The existing key-window timer gains a cockpit step for the frontmost
PR session: refetch cockpit state (1 point) and the conversation
increment (`since` + ETag, usually a free 304), and apply quietly in
place. Native header state updates cost nothing; the page re-renders
only when timeline content actually changed (content-hash compare),
preserving scroll through the existing fraction-restore machinery.
There is **no fast poll** — 60 seconds always, by decision. The
update-available banner is untouched: it stays keyed to head-SHA
movement (new commits change the diffs under review; that reload
remains the reader's choice). Submitting a review or posting a comment
from PullMark triggers an immediate cockpit refresh so the header
reflects the viewer's own action without waiting a tick.

### Graduation: review discussion goes default-on

`pm.prDiscussionEnabled` flips its default to **on**. The toggle moves
from Settings ▸ Experimental to General ▸ Reviewing, keeping its
wording ("Show review discussion on the PR overview"); the
Experimental entry retires. Stored values are respected on all paths:
never-touched users get the new default, users who explicitly toggled
keep their choice. The header's "N unresolved review comments on files
not shown" honesty line retires with it (already coded to yield when
the list is on). Docs: the experimental page notes the graduation, the
features and settings pages document the full overview.

## Interactions with existing features

- **Review popover** — unchanged; submitting refreshes the cockpit
  immediately, and pending reviews never appear in the timeline.
- **Review-discussion list** — sits after Conversation; deliberately
  not nested under review cards (file grouping was chosen in
  pr-review-discussion and stands). The two sections answer different
  questions: what was decided/said vs. what's open where.
- **Update banner** — untouched; head-SHA only. Cockpit and
  conversation changes flow in quietly beneath it.
- **commentsUnavailable** — cockpit and conversation failures are
  isolated from it in both directions.
- **Demo mode** — `DemoSession` gains fixture reviewers, checks, and
  conversation (demo never polls; published screenshots come from the
  fixture per standing policy).
- **Theming, zoom, find** — the timeline is page content: it inherits
  themes and page zoom, and ⌘F searches it like everything else.
- **Print/export/Quick Look** — excluded via `pm-annotation`; paper
  carries the document only.
- **Recents/sidebar** — `updateRecentPRStatus` continues carrying
  lifecycle status only; decision/check badges on sidebar rows are a
  future consideration, not this wave.
- **Shortcuts/menus** — no new commands; the cockpit is glanceable
  state, not a navigation target.

## Out of scope

- Merge button, branch actions, re-request review, ready-for-review —
  no writes beyond commenting.
- Fast polling while checks run (60s always), and any queued-vs-stuck
  staleness heuristics that a fast poll would have needed.
- Commit / force-push / label / assignment timeline events (a quiet
  "n new commits since your review" divider is a noted future option).
- Minimized-comment handling (`isMinimized` is GraphQL-only; rare in
  small-team docs repos — noted for later).
- Per-check re-run actions; sidebar decision badges; GitLab.

## Visual verification

The cockpit is the most glanceable UI in the app, and the header is
where taste failures would live: cursor-driven live trials on a real
PR (livetest) and the demo fixture, judged for design quality — capsule
rhythm and crowding at narrow window widths, both appearances, the
timeline's typography against the document body, spinner restraint —
not just data correctness. Design review at full strength before ship;
dist trial before release. Functional live checks ride the same
sessions: real approve/changes-requested/checks transitions observed
end-to-end on livetest.

## Open questions for implementation

- Probe `reviewDecision` = APPROVED on a no-branch-protection repo
  (one approval on livetest settles it; high confidence, unverified).
- Dismissed reviews on the strip: gray badge (GitHub's treatment) vs.
  dropping off — depends on how `latestOpinionatedReviews` reports
  dismissals; one probe decides.
- Timeline re-render granularity: whole-page rebuild on content-hash
  change is the simple baseline; per-card DOM patching only if the
  rebuild proves visibly disruptive under the 60s tick.
- Whether the checks popover wants workflow-run grouping once a real
  monorepo PR shows 30+ checks (flat list until proven otherwise).
