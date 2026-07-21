# Changelog

Notable user-facing changes to PullMark. Release notes for GitHub releases are
extracted from this file by `scripts/make-release.sh` — keep the `## Unreleased`
section current as features land.

## Unreleased

- Fixed a crash on the first markdown render on any machine other than the
  one that built the release — Settings → Themes (whose preview cards are
  the first render if no document is open) and opening any document were
  both affected. Rendering assets were resolved through a build-time path
  that only exists on the build machine; they are now loaded from inside
  the app bundle, where they have always shipped.

## 0.15.0 - 2026-07-20

- Settings gained a Keyboard tab: every keyboard action in the app, grouped
  by the menu it belongs to, each one rebindable. Click a shortcut (or
  select a row and press Return) and type the new keys; Delete removes a
  shortcut, Esc cancels. Combos already owned by something else are refused
  with the name of what owns them — a standard command like Undo, something
  the system swallows like ⌘Space, or another PullMark action, which offers
  to hand the keys over. The pane is fully keyboard-operable, and the fixed
  editing and sheet keys are listed so it's clear why they aren't editable.
- Every keyboard shortcut now has a menu item. Find Next/Previous and Edit
  Mode joined the Edit menu; Show Outline, Reload Document, and the pull
  request Rendered/Source/Result switch and diff-layout flip joined View.
  They were invisible commands before — no menu entry, no greying out when
  they didn't apply, nothing for VoiceOver to find.
- Checking for updates no longer shoves the button away from the window
  edge when the "you're up to date" line appears.

## 0.14.0 - 2026-07-20

- Edit mode: press ⌘E (or the toolbar pencil) and the page becomes the
  editor. The block under your selection reveals its raw
  Markdown in place — matching the rendered type so nothing jumps — and
  you're ready to type immediately. Click away or arrow onward to commit;
  Esc reverts. Down/Up at a block's edge walks editing through the
  document; Backspace at a block's start merges it into the previous one;
  blank lines split into new blocks; a quiet + at the end appends (and
  makes empty documents writable). Reading remains the default posture.
- Saving is the mode: leaving a block writes it (guarded against the file
  changing underneath), and Revert Last Edit undoes the whole editing
  session. The old Automatic/Manual saving setting and ⌘S are gone —
  with an explicit edit mode, the mode boundary is the save gesture.
- Re-renders (blame arriving, external file changes) wait while you're
  editing and keep your place after; an editor can never lose a draft to
  a background refresh.
- A keyboard pass across the app: ⌘G/⇧⌘G step find matches, arrows drive
  the all-files search palette, review requests appear in ⌘K, ⌘1/2/3 pick
  a PR file's view, ⌥⌘L flips the diff layout, ⌥⌘O toggles the outline,
  ⌘R reloads — and ⌘E inside an open editor commits and exits edit mode.

## 0.13.0 - 2026-07-19

- Editing grew up: click a block's pencil and it becomes an editor right
  inside the rendered page, with Save/Cancel buttons. ⌘↩ saves
  through the same guarded path as ever (collision check, edit history,
  autosave or ⌘S per Settings), Esc puts the rendered block back untouched.
- A review-request inbox: pull requests awaiting your review appear at the
  top of the sidebar with unread indicators and a Markdown-file-count badge
  (PRs with no Markdown are dimmed — PullMark will open them, but the
  reading room has nothing to show). Refreshes quietly every five minutes;
  Settings can hide it.
- Moved-block detection: a block relocated verbatim now renders once, at
  its new position, with a quiet violet "moved" chip (tooltip: the line it
  came from) — instead of a red deletion here and a green addition there.
  Only unambiguous relocations qualify; duplicated boilerplate stays plain.
- Open Quickly (⌘K): one field that jumps anywhere — headings in the
  current document, sidebar files, pull requests and their files, recents —
  with fuzzy matching that favors word starts and short names.
- Session restore: the files and PRs you had open reopen at launch
  (Settings-controlled; new ⌘N windows always start empty).
- Reading positions: long documents reopen where you left off.
- Every PullMark edit is revertible: the previous contents snapshot before
  any write, and File → Revert Last Edit restores them (revertible itself).
- Drag .md files or folders onto the window to open them.
- Print (⌘P): the rendered document, through the standard print panel.
- Fixed a long-standing scroll bug: the page could reload underneath you and
  jump to the top mid-read (nondeterministic page serialization — now
  byte-stable). Saving an edit or an external file change now puts you back
  exactly where you were, and re-renders wait while an editor is open so a
  draft can never be destroyed mid-typing.
- Compare menus rank branches by recent activity (with hundreds of
  branches, an alphabetical top-20 was never the ones you wanted) and say
  when they're showing a subset; the commit sheet stays fast in monorepos
  with thousands of changed files.

## 0.12.0 - 2026-07-19

- Multiple windows, really: ⌘N opens an independent window — its own
  sidebar, PRs, selection, and unsaved edits — and windows merge into
  native macOS tabs. Files opened from Finder, the CLI, or the Dock land
  in the frontmost window; menu commands act on the focused one.
- The commit sheet can push: "Push to origin after committing" (shown when
  the repo has a remote, remembered once set) pushes with upstream setup so
  brand-new branches land on the first try. If the push fails the message
  says exactly that — the commit itself is never misreported as failed.

## 0.11.0 - 2026-07-19

- Local block editing: hover any block in a local document and the pencil
  opens its Markdown source in an editor. Choose in Settings whether edits
  save to disk immediately (default) or accumulate until File → Save (⌘S) —
  unsaved state shows as "· edited" in the titlebar. Collisions with other
  writers (editors, agents) are guarded: applying an edit verifies the
  block hasn't moved, ⌘S asks before overwriting a file that changed
  underneath, and a notice appears the moment the file diverges.
- Commit without leaving: File → Commit Changes… (⌃⌘K) stages and commits
  changes in the active file's repository — changed files with toggles,
  a message field, and the current branch shown up front. On main/master
  it first offers to create a branch (with a per-repo "don't ask again").
- The titlebar now shows the current git branch next to the folder path.

## 0.10.0 - 2026-07-19

- Edit-as-suggestion: hover any new-side block in a rendered PR diff and a
  pencil appears next to the comment bubble. It opens the block's actual
  Markdown source in an editor — change it, optionally explain why, and
  submit. Your edit lands as a GitHub ```suggestion comment the author
  applies with one click (or add it to your review like any draft).
  Clearing the text suggests deleting the lines; embedded code fences are
  fenced safely. The first step on PullMark's editing roadmap.

## 0.9.0 - 2026-07-19

- Show Markdown Source: **⌥⌘U** (View menu) temporarily flips the active
  document — local files, browsed PR docs, and a PR file's Result view — to
  its raw Markdown, monospace and syntax-tinted, honoring light/dark and
  your reading theme's paper. Press again to return; the choice is never
  persisted, so reading stays the default.
- Quick Look previews are now a preference: Settings → General → "Quick
  Look previews" chooses **Rendered** (default) or **Raw Source** — the raw
  view is a clean monospace page that follows light/dark, not the system's
  plain-text dump.

## 0.8.1 - 2026-07-19

- The app icon adopts macOS 26's layered Liquid Glass format: the M and
  the green download arrow are separate layers over a gradient fill, so
  tinted and dark icon modes recolor the glyph properly instead of
  desaturating a flat bitmap. Older macOS versions keep a flat icon derived
  from the same layers.
- Fixed Quick Look previews showing the raw file after an update: brew's
  delete-and-replace upgrade can silently drop the preview extension's
  registration. The app now re-registers its extension on every launch, and
  the Homebrew cask re-registers it right after each install/upgrade — so
  space-bar previews survive updates without ever launching the app.

## 0.8.0 - 2026-07-19

- Quick Look previews now follow your reading theme: the app shares the
  choice with the (sandboxed) preview extension through an app group, so
  pressing space in Finder shows Editorial, GitHub, or Terminal — whichever
  you read in. Custom `.css` themes can't cross the sandbox boundary and
  fall back to their GitHub base in previews.
- Review-thread resolution state now loads for PRs with more than 100
  threads (cursor pagination), and the changed-file and comment lists
  paginate to the API's own 3,000-item maximum instead of stopping at 1,000.
- Opening a folder scans it off the main thread — a huge directory tree can
  no longer freeze the UI — and the "no Markdown files here" / "showing the
  first 500 files" messages are now plain notices instead of appearing
  under a "Something went wrong" error title.
- ⌘F (Find in Page) now works on the PR overview page, not just file views.
- Fixed the Settings theme-preview cards occasionally painting blank until
  clicked, and hardened the web view's transparent-background setup against
  future WebKit changes.

## 0.7.1 - 2026-07-19

- Rendering huge documents is dramatically faster: two quadratic paths in the
  Markdown pipeline are now linear. A 10,000-paragraph, 1&nbsp;MB document that
  took ~6.8&nbsp;seconds of main-thread work now renders in ~0.6&nbsp;seconds; a
  5,000-row table dropped from ~1.5&nbsp;s to ~0.45&nbsp;s. (The causes:
  marked calls every extension's `start()` with the whole remaining source per
  token — now bounded to a 4&nbsp;KB lookahead — and marked's `walkTokens`
  accumulates with repeated `Array.concat` — replaced with a linear
  traversal. Both fixes also apply to Quick Look previews.)
- New `make perf-check` stress harness renders pathological documents
  (10k paragraphs, 5k-row tables, 400 code fences, a 1.5&nbsp;MB single
  paragraph) plus real-world giants through the real pipeline in headless
  Chrome and reports timings, and the Swift test suite now includes
  performance smoke tests guarding the block splitter and diff engine.

## 0.7.0 - 2026-07-19

- A proper DMG install experience (macOS provides neither prompt itself):
  launch PullMark from the disk image and it offers to move itself into
  Applications and relaunch; once installed, if the disk image is still
  mounted it offers to eject it and move the `.dmg` to the Trash. Declining
  the Trash offer is remembered — PullMark won't ask about that image again.
- Releases now also publish a version-less `PullMark.dmg` asset, so
  [the latest DMG has a stable URL](https://github.com/jedijashwa/pullmark/releases/latest/download/PullMark.dmg)
  — the website's Download button points straight at it.

## 0.6.0 - 2026-07-19

- Editorial is now the default reading theme (GitHub and Terminal remain one click away in Settings).

- Paths shown in the UI abbreviate your home folder to `~` (titlebar
  subtitles, Recents tooltips, search-result subtitles).
- Export (#9): File → "Export as PDF…" / "Export as HTML…" save the rendered
  document (local files, a PR file's Result view, and browsed repo docs —
  not diffs). PDF captures the full document via WebKit as one continuous
  page (not paginated). HTML is a self-contained single file: styles are
  inlined (KaTeX with embedded fonts when math is present), scripts and the
  CSP are stripped, and local/already-loaded PR images are embedded as data:
  URIs (unfetched remote images keep their URLs, best effort).
- Copy in two flavors (#10): ⌘C keeps the web view's native copy — the
  selection lands on the pasteboard as rich text (RTF/HTML) that pastes
  formatted into Google Docs, Slack, and friends. Edit → "Copy as Markdown"
  (⌥⌘C) instead maps the selection back to the original Markdown source at
  whole-block granularity (selecting part of a block copies that whole
  block's source; no selection copies the whole document). Works on local
  files, a PR file's Result view, and browsed repo docs. Rendered documents
  now always annotate blocks with their source line ranges (previously only
  when blame was shown), which is what makes the mapping possible.
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
- Extended inline marks (#11): `==highlight==` → highlighted text,
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
