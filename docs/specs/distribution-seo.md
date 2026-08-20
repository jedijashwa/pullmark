# Distribution & SEO: the agent-feedback story

## Motivation

PullMark's most differentiated feature — margin notes, shipped to beta in
0.35.0 — appears nowhere on the homepage. An audit (2026-08-20) found the
site also lacks every piece of standard search plumbing: no `sitemap.xml`,
no `robots.txt`, no structured data, no canonical URLs, and only the
homepage carries an `og:image` (currently the blame screenshot — a strange
social card). The six site screenshots predate both the PR cockpit (0.34.0)
and margin notes. The GitHub repo has **zero topics** set.

Distribution for a niche tool means being the obvious answer to one
specific, growing question. Ours: **"my agent wrote a big plan/spec — how
do I actually review it?"** The current answers are bad: raw Markdown in an
editor, pasting chunks into chat, or committing a draft just to get PR
comments — and not every document belongs committed, nor every working
version pushed. PullMark's answer: read it rendered, leave margin notes in
the exact places, tell your agent to address them — the notes live in the
file, so the agent reads them where you left them. Feedback the way you'd
give it to a coworker.

Scope decided with Josh (2026-08-20): Tracks A (site), B (GitHub surface),
C (launch material drafts). No standalone essay (D) — the `/agents/` page
carries the story. Homepage treatment: keep the existing hero; the agent
story becomes the **first section** beneath it. Use-case page lives at
**`/agents/`**.

## Copy rules (project-wide, non-negotiable)

- Margin notes are "ordinary HTML comments that stay out of rendered
  Markdown." **Never** claim other tools can't see them.
- Never name the competitor on any public surface.
- Screenshots that leave this machine show demo-fixture content only,
  captured with the published-screenshot accent flags
  (`-AppleAccentColor 4 -AppleHighlightColor "0.698039 0.843137 1.000000
  Blue"`), never Josh's real documents, repos, or PRs.
- Nothing in Track C gets posted anywhere without Josh's explicit go,
  item by item.

## Track A — Site

### New screenshots (three)

1. **`app-notes.png`** — the margin-notes shot: `site-survey-draft.md`
   from the demo fixtures (sam-ortega file-level note + elena-fisk block
   note), with one note card open showing author and text and the other
   visible as a bubble. Same window geometry as the existing reading
   shots (1052×784 logical).
2. **`app-pr.png`** — the PR cockpit: demo PR overview showing the review
   decision, reviewer strip, checks capsule, and conversation timeline.
   Reading-shot geometry.
3. **`og-card.png`** — a designed 1200×630 social card: icon, wordmark,
   tagline, and a screenshot fragment. Replaces `app-blame.png` as the
   homepage/social `og:image`; also uploaded as the GitHub repo's social
   preview (Track B).

Capture procedure: `make app`, launch dist with `PM_DEMO` + accent flags,
drive via `scripts/drive/` (⌘K to open fixtures; close Settings before
driving; filter `winlist` by width for the main window), `screencapture -x`
in-process. Mandatory cleanup: quit dist instance, `make unregister-dist`,
relaunch /Applications if displaced.

### Homepage (`site/index.html`)

New section `#agents` between the hero and `#why`:

- Kicker: `your agent`. Headline: the agent-review wedge ("Your agent
  writes plans. Give feedback like a coworker." — final copy at build
  time, subject to design review).
- Body: the loop in one paragraph — agent writes `plan.md` → open it
  rendered → margin notes on the exact blocks → "address my notes in
  plan.md" → watch the edits land highlighted via live compare. Notes are
  ordinary HTML comments in the file itself: no commit, no PR, no
  copy-paste.
- `app-notes.png` as the section figure.
- Link to `/agents/` for the full story and to
  `/docs/experimental/margin-notes/` for mechanics.
- The `#reviewing` section gains the `app-pr.png` cockpit shot only if it
  strengthens the section (design-review call); the existing
  `app-diff.png` stays the primary reviewing figure.

### `/agents/` use-case page

Standalone marketing page (not under `/docs/`), same visual system as the
homepage. Structure:

1. **The moment** — your agent produced a 400-line plan; reading it raw or
   pasting it into chat loses the thread; committing a draft just to get
   PR comments is the wrong ceremony for a working document.
2. **The loop** — rendered reading → margin notes (screenshot) → the
   hand-back ("address my notes"), including the tell-your-agent snippet
   (same copy the app's Copy button produces) in a copyable block.
3. **Watching the revision** — live compare / `pullmark --diff`: the
   agent's edits land as highlighted changes while the file changes.
4. **When it *is* a PR** — rendered diffs, review comments, the cockpit
   (`app-pr.png`); PullMark covers the committed path too.
5. **Get it** — install block (same as homepage), links to docs.

Full meta set (title ~"Review your AI agent's plans and docs — PullMark",
description targeting "review AI agent plans/specs markdown", og/twitter
cards using `app-notes.png`, canonical).

### Technical SEO plumbing (all pages)

- `site/sitemap.xml` — all indexable pages, and a build-time check is not
  needed (hand-maintained; page count is small).
- `site/robots.txt` — allow all, `Sitemap:` pointer.
- `<link rel="canonical">` on every page.
- `og:title/description/type/url/image` + `twitter:card=summary_large_image`
  on every page (docs pages may share the og-card image).
- JSON-LD `SoftwareApplication` on the homepage: name, operatingSystem
  "macOS 13.0+", applicationCategory DeveloperApplication, offers price 0,
  license MIT, downloadUrl (latest DMG), screenshot, url.
- `site/llms.txt` — concise tool description plus key links (homepage,
  /agents/, docs index, margin-notes docs, troubleshooting, GitHub,
  latest release). Agents recommending tools is a distribution channel;
  be legible to them.

### Housekeeping folded in

- Footer on every page gains **Licenses → /licenses/** (deferred from
  0.35.0).
- `site/docs/settings/index.html`: move the GitHub section after
  Reviewing to match the in-app order (0.36.0 residue).

## Track B — GitHub surface

- **Topics** (`gh repo edit --add-topic`): macos, swift, swiftui,
  markdown, markdown-viewer, code-review, pull-requests, github,
  mermaid, ai-agents, developer-tools. Outward-facing write — gets
  Josh's go with the rest of the ship.
- **README**: add `app-notes.png` and `app-pr.png` near the top via
  `github-attach` user-attachments URLs (never committed to the repo, no
  raw.githubusercontent), plus a short agent-loop paragraph mirroring the
  homepage section.
- **Repo social preview**: upload `og-card.png` in repo settings
  (browser-only; via the logged-in Chrome session, gated with Josh).

## Track C — Launch material drafts (nothing posted)

Drafts delivered to `~/Google Drive/My Drive/Handoffs/pullmark-launch/`
(not committed — committing launch copy to the public repo publishes it
early):

- **Show HN** — title options + body, anchored on the agent-feedback
  story, linking pullmark.app/agents/.
- **awesome-mac / awesome-markdown** — one-line entries + PR body text
  (jedijashwa identity).
- **AlternativeTo** — listing description and screenshots to use.
- A posting checklist with the order of operations (site live first, then
  README, then listings, HN last).

## Out of scope

- homebrew/cask core inclusion — notability-gated (stars/forks); revisit
  after a launch bump.
- Site analytics of any kind — the site stays tracker-free, matching the
  app's privacy posture.
- Blog infrastructure, mailing list, Product Hunt.
- Any in-app changes; this wave ships no app release.

## Verification

- Design review pass on the homepage section, `/agents/`, and all three
  images (live-visual taste standard, same as app waves).
- Link check across the site (internal hrefs resolve, no orphan pages);
  sitemap URLs all return 200 on the preview deploy.
- og/JSON-LD validated (structural lint; no external validators needed).
- Preview deploy via wrangler; Josh reviews the preview URL before
  production, and separately green-lights each Track B/C outward write.
