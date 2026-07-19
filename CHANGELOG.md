# Changelog

Notable user-facing changes to PullMark. Release notes for GitHub releases are
extracted from this file by `scripts/make-release.sh` — keep the `## Unreleased`
section current as features land.

## Unreleased

- Export (#9): File → "Export as PDF…" / "Export as HTML…" save the rendered
  document (local files, a PR file's Result view, and browsed repo docs —
  not diffs). PDF captures the full document via WebKit as one continuous
  page (not paginated). HTML is a self-contained single file: styles are
  inlined (KaTeX with embedded fonts when math is present), scripts and the
  CSP are stripped, and local/already-loaded PR images are embedded as data:
  URIs (unfetched remote images keep their URLs, best effort).
- Search across all files (#8): ⇧⌘F (Edit-menu "Search All Files…") opens a
  command-palette-style search over everything in the sidebar — local files
  are read from disk, and PR documents already loaded in memory are included
  (never fetched for search). Results group by file with the matched term
  bolded in its line context; Enter or a click opens the file and drives
  find-in-page so the term is highlighted and scrolled into view.
- Find-in-page fixes: highlights are re-applied when the page re-renders
  underneath an active find (e.g. blame annotations arriving), and matches
  inside non-rendered text (mermaid's embedded SVG stylesheets) no longer
  inflate the count or swallow the first hit.
- Math rendering (#11): `$inline$` and `$$block$$` TeX render through a
  bundled KaTeX — fully offline and CSP-compatible. The tokenizer is
  conservative so prose survives: `$5 and $10` stays currency, dollars inside
  code spans and fences are untouched, and untrusted `\href` targets are
  refused. Quick Look previews render math too (server-side, no scripts).
- `[toc]`: a paragraph containing exactly `[toc]` renders as a linked table
  of contents built from the document's headings — in documents, diffs, and
  Quick Look previews.
- Typora-style inline marks (#11): `==highlight==` → highlighted text,
  `~sub~` → subscript, `^sup^` → superscript. `~~strikethrough~~` is
  unaffected.
- Custom themes: drop `.css` files into
  `~/Library/Application Support/PullMark/Themes/` and they appear in
  Settings → Themes below the built-ins, with live preview cards. Custom CSS
  applies on top of the GitHub look; if the file disappears, PullMark falls
  back to the GitHub theme.
- Word count and reading time: rendered documents show a quiet
  "1,234 words · 6 min" pill in the bottom corner (documents only, never
  diffs).

## 0.5.0 - 2026-07-19

- Non-brew installs now truly self-update: "Update Now" downloads the
  release's zip to a purgeable temp folder, verifies it before touching
  anything (code signature intact, signed by PullMark's Developer ID team,
  accepted by Gatekeeper/notarization), swaps the app bundle in place with a
  rename dance that can't leave a half-installed app, and relaunches. Any
  verification failure aborts, cleans up, shows the error in the banner, and
  opens the release page as a fallback. The banner reports progress
  ("Downloading…", "Verifying…", "Installing…").
- Fixed update-method detection: a brew-installed pullmark cask elsewhere on
  the machine no longer claims a PullMark running from a different location —
  the brew tier now applies only when the running bundle is the copy brew
  manages (/Applications/PullMark.app or brew's Caskroom).
- Releases now include a drag-to-install DMG.

## 0.4.0 - 2026-07-19

- Settings → General now shows which app opens `.md` files, with a one-click
  "Make PullMark the Default" button when it isn't PullMark.
- If you made PullMark your default Markdown app and an upgrade later makes
  macOS drop that binding (brew replaces the app on disk and Launch Services
  forgets), a banner offers to make PullMark the default again. Dismissing it
  clears the reminder until you claim the default next time.
- The update banner now updates in place: brew-managed installs get an
  "Update Now" button that runs `brew upgrade --cask pullmark` and relaunches
  PullMark (with a fallback to the copyable command if brew fails); other
  installs get a "Download" button that opens the release page.
- Rendered pages are hardened against script injection from hostile Markdown
  (#5): a Content-Security-Policy only lets PullMark's own bundled scripts
  run — inline `<script>` tags and `on*=` handlers smuggled in via raw HTML
  are blocked — and the render payload is embedded as non-executing JSON.
  Quick Look previews get an even stricter policy (no scripts at all).
- YAML front matter now renders as metadata instead of prose (#6): documents
  (and Quick Look previews) show a quiet, collapsed "Front matter" table at
  the top, and rendered diffs show compact key/value tables inside the usual
  red/green blocks instead of walls of bold prose. Simple `key: value` lines
  split into two columns; nested YAML stays preformatted. Word-level diff
  marks are skipped for front matter (plain old/new tables are clearer).
- Blame redesigned as a gutter: instead of annotation strips under every
  block, blame now draws a quiet left gutter — one avatar per run of
  consecutive blocks last touched by the same commit, with a rule spanning
  the run. Hovering shows a popover with the author, relative date, commit
  headline, and the SHA chip (open on GitHub / copy). Works across all three
  reading themes in Light and Dark.
- Blame mode now renders the whole document once, so footnotes and
  reference-style links work with blame on (#7).
- Avatars resolve far more often: commits authored under private/noreply
  emails that GitHub can't match to an account now fall back to the signed-in
  user's avatar when the author is you, then to GitHub's email-derived
  avatar, before initials.
- Line history: clicking a gutter entry opens a History panel. Local files
  get true line history (`git log -L`) for the run's lines; PR files show the
  file's history (GitHub has no line-history API — the panel says so), split
  by a divider into commits on the PR branch vs ones already on the base
  branch. Rows open the commit on GitHub or copy the SHA.
- Empty added/removed blocks in rendered diffs show a small "(empty)" label
  instead of a bare colored box (#7).
- The Blame toolbar button no longer appears for files outside a git
  repository.

## 0.3.1 - 2026-07-18

- Opening a file while PullMark is already running no longer spawns a
  duplicate window — files now open in the existing window.
- Find in Page (⌘F) reliably focuses the search field when the bar opens.
- The outline sidebar now highlights the current section while scrolling a
  PR file's diff (it already did for local files and browsed docs).
- Hovering a repo-relative link in PR content shows a readable path in the
  status pill instead of a raw pullmark-remote URL.
- Dismissing the update banner fully clears the pending release notes.

## 0.3.0 - 2026-07-18

- Blame annotations: a toolbar toggle on rendered documents (local files, a
  PR file's Result view, and repo files browsed from a PR) shows who last
  touched each block — GitHub avatar, author name, relative date, and a
  short-SHA chip that opens the commit on GitHub (hover for the commit
  headline). Up to three contributors stack per block. Uses GitHub's GraphQL
  blame whenever the repo lives on github.com; local files fall back to
  `git blame` with initials avatars when no GitHub data is available.

## 0.2.0 - 2026-07-18

- Reading themes: choose between GitHub (the classic look), Editorial (serif
  headers on warm paper), and Terminal (monospace with a phosphor-green
  accent) for rendered Markdown and diffs — each adapts to Light and Dark
  appearance. Quick Look previews always use the GitHub theme.
- Settings window (⌘,): General tab with Appearance, default diff layout,
  and update checks; Themes tab with live preview cards rendered by the real
  pipeline — click a card to switch instantly
- Automatic update checks: a banner appears when a new PullMark release is
  available, with its release notes and a one-click copy of the
  `brew upgrade --cask pullmark` command
- "Check for Updates…" in the PullMark menu
- "What's New in PullMark" sheet showing the release notes you missed after
  updating
- Help menu: report a bug or request a feature without leaving the app
- Support PullMark on Ko-fi from the Help menu
- New website at [pullmark.app](https://pullmark.app)

## 0.1.1 - 2026-07-18

Signed with Developer ID and notarized by Apple — no Gatekeeper warnings. Also: review thread replies and resolution, scroll-spy outline sidebar, recents with PR status, local git history/branch comparison.

## 0.1.0 - 2026-07-18

First release: rendered Markdown viewing, PR rendered diffs with word-level highlights, review comments/suggestions/threads, Quick Look extension, CLI, default-app support. Ad-hoc signed — right-click → Open on first launch.
