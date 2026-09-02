# GitHub work: buckets, followed repositories, issues

The Pull Requests section grows from one "Review Requests" inbox into
the pull requests AND issues that concern you — requested, created,
assigned, participating — plus whole repositories you choose to
follow, with issues becoming a first-class document you can read and
comment on in the app. Two layouts over one model, chosen by a
setting.

Josh (2026-08-28): "see PRs that I've opened too, not just ones I'm
assigned. Also maybe ones I'm participating in"; "a way of adding
specific repos where you want to see all pull requests"; "add issues
support here too with the same"; "I think I prefer A [type-grouped]
but can see why others may want B [involvement-grouped]. Can this be a
setting?"; per-item unread override; single release ("not doing slow
rollouts"). Design pitch with mockups:
https://claude.ai/code/artifact/4664885b-eacd-40dd-92aa-9ff3b53753d2

## Research summary

- Trailer (the native analog) buckets by involvement — Mine /
  Participated / Mentioned — and gates per repository whether PRs and
  issues sync at all.
- GitHub's own inbox ships four default filters (assigned,
  participating, review requested, mentioned) and saved custom filters
  scoped `repo:owner/name`.
- The search API accepts `@me` on every involvement qualifier;
  `author:@me` returns issues and PRs in one query. Budget: 30
  searches/min authenticated.

## §1 The item

One type covers both kinds: `kind` (pr | issue), `owner/repo#number`,
title, author, last activity, draft flag, and the **roles** that put it
in front of you: reviewRequested, created, assigned, participating.
An item may sit in more than one bucket (created AND assigned), as
GitHub shows it; unread state is one per item, keyed
`owner/repo#number`, extending today's `pm.inboxSeen` rule (unread =
changed since last opened).

## §2 Buckets

| Type   | Buckets (in order)                                   |
|--------|------------------------------------------------------|
| PRs    | Review Requests · Created · Assigned · Participating |
| Issues | Created · Assigned · Participating                   |

Participating = `involves:@me` or `reviewed-by:@me`, minus created and
assigned. Drafts are shown, marked "· draft" in the subtitle. Empty
buckets are hidden (as the inbox is today when empty).

Queries per refresh, riding the existing inbox cadence:
`is:open is:pr review-requested:@me`; `is:open author:@me`;
`is:open assignee:@me`; `is:open involves:@me -author:@me -assignee:@me`;
`is:open is:pr reviewed-by:@me -author:@me`; all with
`archived:false`, sorted by updated, `per_page` 30. Plus one
`repo:owner/name is:open` per followed repo.

## §3 Followed repositories

- A **preference**, not session state: `pm.followedRepos` — list of
  `owner/repo` with an unread rule: Everything (default) / Only mine /
  None. Always restores.
- **Follow Repository…** in the section header: type `owner/repo` or
  pick from repositories already open (Locations with a GitHub remote,
  PR sessions, browsed repos). **Unfollow** and the unread rule in the
  group's context menu.
- Each followed repo is a group listing everything open there, most
  recently updated first.

## §4 Per-item unread override

Any item row's context menu: **Unread: Use repository setting /
Always / Never**. Inherits the repo's rule (Everything for items that
only appear through an involvement bucket); the item's own choice wins
when set. Stored with the seen-state.

## §5 Groups: caps and paging

Every group loads the 30 most recently updated; a trailing **Show
more…** row fetches the next 30. Group headers carry the unread count
(two-part `6 · 14` PRs · issues in the mixed layout).

## §6 Two layouts, one setting

Settings › Sidebar › **Group GitHub work by**:

- **Type** (default, `pm.githubGrouping = type`): a **Pull Requests**
  section and an **Issues** section, each with its opened items at the
  top, then its buckets, then the followed-repo groups filtered to
  that type.
- **Involvement** (`involvement`): one **GitHub** section: opened items
  of both kinds at the top, the buckets mixing PRs and issues with a
  type glyph on every row, then the followed-repo groups mixing both.

Rows, counts, menus, and unread behave identically; only grouping
differs. Section collapse states are per section.

## §7 Rows

Today's inbox row generalizes: unread dot, title (semibold while
unread), subtitle `owner/repo#number` plus the reason when it isn't
obvious ("· assigned", "· mentioned", "· reviewed", "· draft"), the
Markdown-file badge for PRs. Click opens; arrow keys select; context
menu: Open, Reveal on GitHub, the unread override.

## §8 Issues as documents

- Opening an issue creates an **issue session** (no file tree). The
  content area shows the rendered body through the normal Markdown
  pipeline, then the timeline — comments, reactions, reference and
  state events — and a composer, reusing the PR cockpit's merged
  timeline and the review-discussion composer. Comment, react, edit
  or delete your own comments.
- The opened issue is a single row (issue glyph) at the top of its
  section; Close from its context menu; Recents entry; restores with
  the session subject to the reopen setting.
- Out of scope for v1: creating issues, editing titles or bodies,
  labels, assignees, milestones, closing/reopening.

## §9 Localization and strings

All new labels go through the strings gate (7 locales). Bucket names,
setting labels, the banner-free flows — nothing user-visible bypasses
`check-strings.py`.

## §10 Verification

- Pure tests: query builders; bucket assignment from roles (an item in
  two buckets); seen-state and per-item override precedence; paging
  merge (no duplicates across pages); the mixed-count formatter.
- Live: demo fixtures for both layouts; a followed repo with >30 items
  and Show more…; an issue session with a comment posted to the
  disposable livetest repo (never the main repo).

## §11 Release

One release — buckets, followed repos, grouping setting, and issues
together (Josh: no staged rollouts). Feature ⇒ minor bump.
