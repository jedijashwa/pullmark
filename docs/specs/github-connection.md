# GitHub connection: status, setup walkthrough, and the auth traps

PullMark finally *says* whether it can talk to GitHub, helps a new
machine get connected, and stops punishing users who fix their auth
mid-session. One wave, four pieces: a connection model with a Settings
status row, a live-detecting setup sheet, re-resolution that kills the
once-per-launch token latch, and the public-PR 401 bug fix — plus a
quiet signed-out cue on the PR overview.

## Motivation

PullMark's auth model — borrow the token the user's own tooling
already has — is the right privacy story, but today it is completely
silent. On a machine without `gh` (or with it signed out), private
PRs fail with "may be a private repository your GitHub credentials
can't access" and no path forward; nothing anywhere shows whether the
app is connected or as whom; and the token resolves exactly once per
launch (`GitHubClient.tokenResolved`), so a user who runs
`gh auth login` after seeing an error keeps failing until they
relaunch — the walkthrough this spec adds would be a lie without
fixing that. Bonus live bug: on public PRs viewed signed-out, REST
comments load but the GraphQL thread-meta 401s, and their shared
`do/catch` trips `commentsUnavailable` over comments that loaded.

## Research summary (token capability matrix)

What the two credential sources can and can't do — this shapes the
walkthrough's recommendation order and the docs page:

- **gh as git's credential helper** (`gh auth setup-git`): the
  helper path returns gh's own token — literally identical.
- **Classic PAT with `repo` scope** (keychain, from an old HTTPS
  push): covers everything PullMark does (REST + GraphQL, private
  repos, comments, reviews, reactions). Edges: missing `read:org`
  degrades org team names in the reviewer strip; SAML/SSO orgs need
  the PAT authorized per-org; manual PATs expire silently — the
  status row and auth-failure re-resolve make that visible.
- **Fine-grained PATs** (GA March 2025): GraphQL supported since
  April 2023, but a token is bound to ONE resource owner (still true
  2026; roadmap item to lift). PullMark opens PRs on arbitrary
  repos, so these produce half-working states — public reads fine,
  one owner's private repos fine, everything else denied.
- **Other helpers** (Git Credential Manager, GitHub Desktop, VS
  Code): mint OAuth tokens with repo-equivalent scopes — fine.

Conclusion: recommend `gh` (known-good scopes, browser-flow SSO,
refreshing tokens); honor helpers as "you may already be set up."

## The design

**Connection model.** `SystemGitCredentials.resolveToken` returns
`(token, source)` — source: `.githubCLI` or `.credentialHelper`.
`GitHubClient` exposes observable connection state:
`connected(login, source)` / `notConnected` / `checking`. The login
comes from the existing `viewerIdentity()`; its cache invalidates
whenever the token changes. Demo mode reports the fiction —
connected as the demo viewer — and never shows signed-out surfaces
over fixtures.

**Latch fix.** `tokenResolved` is replaced by re-resolution:

- `recheck()` — explicit, from the Settings row and the setup sheet.
- Automatic: an auth-shaped failure (HTTP 401; NOT rate-limit 403)
  invalidates the cached token, re-resolves once, and retries the
  failed request once. Debounced: at most one automatic re-resolve
  per 30-second burst, so a storm of 401s can't fork subprocess
  chains. Success resets the debounce.

**Settings ▸ General ▸ GitHub.** A status row: "Connected as
jedijashwa · GitHub CLI" (source named; avatar optional) or "Not
connected — private repositories and reviewing are unavailable."
Buttons: **Check Again** and **Set Up…** (opens the sheet). New
anchor `settings/general/github`; the Add-PR sheet's "works with
private repos using your existing gh or git credentials" caption
links to it.

**Setup sheet** (`GitHubSetupSheet`). Live-detecting, shows only the
relevant step:

1. `gh` not found on PATH → "Install the GitHub CLI": copyable
   `brew install gh`, link to cli.github.com for non-Homebrew.
2. `gh` present but signed out → copyable `gh auth login`, with the
   trust framing: it runs in the user's own terminal and opens a
   browser; PullMark never sees a password and never runs the login
   itself (commands are only ever copied).
3. Either state also notes: an existing git credential helper works
   with zero setup — Check Again will find it.
4. Connected → ✓ "Connected as X via <source>" and Done.

Detection (which gh, `gh auth status`, `git credential fill` probe)
runs detached off-main like resolution today. **Check Again** re-runs
detection AND `recheck()` — connecting mid-session works without
relaunch, which is the whole point.

**Reactive errors.** PR-open failures that are auth-shaped gain a
"Set Up GitHub Access…" button on the existing error alert. Auth-
shaped here: 401 always; 404 only when signed out (GitHub answers
404 for private-without-auth, and a signed-out 404 is far more
likely "private" than "typo").

**Signed-out cue.** PR overview only: when signed out, the cockpit
header's GraphQL fails and that strip renders empty today — the slot
instead shows one quiet line: "Viewing signed out — commenting and
reviewing are off · Set Up…". No new chrome for connected users; the
cue disappears the moment auth lands (the 60s tick or a retry
repopulates the cockpit).

**Bug fix.** Split the shared `do/catch` in `addPR`
(AppState.swift:1504-1510): `reviewComments` failure alone trips
`commentsUnavailable`; `reviewThreadMeta` failure alone renders
threads with degraded meta (no reactions/resolve state/viewer flags)
— comments that loaded are never banished by meta that didn't.

## Interactions with existing features

- **Demo mode** — connected-as-fiction; signed-out cue and setup
  surfaces never appear over fixtures.
- **Inbox / review requests** — already hidden when unauthenticated;
  now Settings explains why.
- **Pending review adoption** — viewer cache invalidation on token
  change keeps `cachedViewer` honest (its comment already demands
  retry-on-transient-failure semantics).
- **Rate limiting** — 403s are never treated as auth failures; no
  re-resolve storms during rate-limit windows.
- **Blame/compare/local git** — untouched; local git operations use
  the user's own credential helpers directly, not PullMark's token.
- **Margin notes author** — `MarginNoteAuthor` prefers viewerLogin;
  a mid-session connect now improves the signature without relaunch.

## Out of scope

- Any in-app OAuth/device flow — the borrow-your-tooling model IS
  the privacy story. The app never prompts for or stores secrets.
- Running `gh auth login` on the user's behalf (interactive; and
  policy: commands are copied, never executed).
- Per-org SSO diagnostics or scope introspection — the docs page
  explains the matrix; the app reports connected/not.

## Verification

- `PM_NO_CREDENTIALS=1` guard at the top of
  `SystemGitCredentials.resolveToken` (PM_DEMO-style env hook) so a
  dist trial on a fully-authed machine can be genuinely signed out.
- Unit tests: source-tagged resolution parsing, auth-shape
  classification (401 yes, 403 no, 404 only-when-signed-out),
  debounce window, viewer-cache invalidation on token change.
- Live E2E on a PUBLIC livetest PR, signed out: comments render with
  no banner (bug fix), cue shows, then `gh` re-auth + Check Again
  connects without relaunch and the cockpit populates.
- Dist trial: cold walkthrough from each entry point (Settings,
  error alert, cue), judged for feel; full design review before ship.
