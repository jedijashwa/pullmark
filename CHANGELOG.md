# Changelog

Notable user-facing changes to PullMark. Release notes for GitHub releases are
extracted from this file by `scripts/make-release.sh` — keep the `## Unreleased`
section current as features land.

## 0.29.0 - 2026-08-11

- **Customize the toolbar** — right-click the toolbar (or View →
  Customize Toolbar…) for the native palette: drag items out you never
  use, rearrange the rest, add Flexible Space. Every kind of view — a
  local file, a GitHub doc, a pull request file, the PR overview —
  keeps its own arrangement, remembered across launches; customize each
  one while you're in it, the way Mail's compose window works.
- **New optional toolbar items**, all hidden until you add them: a
  raw-**Source** toggle for local files and GitHub docs, **Zoom
  In / Actual Size / Zoom Out**, the **Content Width** picker, **Add
  Margin Note** (when the feature is on), and for GitHub docs
  **Share** — the document's github.com page, never a raw link — and
  **Reload**, which re-resolves a branch to its current tip (and stays
  disabled, with the reason, for documents opened at a specific
  commit).
- Out of the box nothing changes: every toolbar looks exactly as it
  did, and the palette holds the rest.

## 0.28.4 - 2026-08-07

- **Update Now actually updates now** — the in-app Homebrew upgrade
  refreshed nothing first, so a stale local tap could "upgrade" you to
  the version you already had, report success, and relaunch you into
  the same banner forever. The updater now fast-forwards the tap
  before upgrading and verifies the version on disk is the one it
  offered before relaunching — a mismatch is reported instead of
  looped.

## 0.28.3 - 2026-08-07

- **Deep links land on the exact setting now** — a
  `pullmark://settings/<tab>/<setting>` link scrolls the Settings
  window to that row and flashes it. The docs site's Settings page
  uses them everywhere: every setting name is now a link that opens
  its own row in the app.

## 0.28.2 - 2026-08-07

- A release-notes or website link to Settings now brings the Settings
  window to the front even when it was already open behind another
  window.

## 0.28.1 - 2026-08-07

- The Settings links in release notes work now — and they're honest:
  a link this version can't honor (a feature that moved, or one from
  a newer version's notes) renders as plain text instead of a dead
  link.
- A release-notes link straight to an alpha feature offers the "Show
  alpha features" switch on arrival when alpha is hidden, instead of
  landing on a tab with nothing in it. (A link to the Experimental tab
  itself never prompts.)
- The `pullmark://` links are registered with macOS now, so they work
  from the website and anywhere else too — not just inside the app's
  own sheets.
- A link this version doesn't know (say, from a newer release's docs)
  gets a proper dialog instead of silence: check for updates, file a
  pre-filled issue carrying the link, or close.

## 0.28.0 - 2026-08-07

- **Margin notes** *(experimental, alpha)* — comment on any local
  Markdown document the way you'd comment on a pull request. Hover a
  block for the note bubble (select text first to quote it), write in
  Markdown, and the note saves into the file itself as a plain HTML
  comment — `<!-- note @you: like this -->` — invisible to GitHub and
  every other renderer, rendered by PullMark as a bubble pinned to
  that spot. Built for reviewing documents an agent wrote for you:
  tell the agent to address the notes and delete them as it goes, and
  watch the bubbles disappear live. Edit and delete from each bubble,
  ⌥⌘M notes the block you're reading, Open Files rows carry a count
  chip, notes render read-only in browsed GitHub files, and they never
  appear in print or exports. Off by default — turn it on in
  [Settings → Experimental](pullmark://settings/experimental/margin-notes), where a
  copy-paste snippet teaches your agent the format. The full spec:
  [margin notes](https://pullmark.app/docs/experimental/margin-notes/).
- **An Experimental tab in Settings** — features now land with an
  honesty label. *Beta* features get a real compatibility effort
  between versions and are likely to graduate; *alpha* features (like
  margin notes) carry no guarantees at all. Alpha features stay hidden
  until you opt in. [How experimental features
  work](https://pullmark.app/docs/experimental/).
- **Big repos stopped nagging** — the folder scan now takes up to
  20,000 Markdown files (was 2,000), and hitting a limit no longer
  pops a dialog: the quiet note inside the folder's own tree is the
  single indicator.
- **Hidden files, when you want them** — Settings → General → "Show
  hidden files", View → Show Hidden Files, or Finder's own ⇧⌘.
  (rebindable). Every open Location rescans on the flip, so `.github/`
  docs appear in place.
- **Settings, reorganized** — every section now predicts its contents:
  General reads Reading · Reviewing · Updates · System, the
  Light/Dark/System picker moved to the top of the Appearance tab, and
  Experimental got its own tab.
- **Release notes, wherever you need them** — What's New shows the
  notes of *every* release between your version and the new one, with
  versions as headings in the content; **Help → Release Notes** shows
  the full history up to the version you're running; and What's New
  can deep-link into the app — like that Settings link above, which
  closes the sheet and lands on the right tab. Settings offers updates
  in place when one is already known (What's New · Update Now · check
  again), and a new option swaps the automatic post-update sheet for a
  quiet banner.
- **Help → Report a Bug…** pre-fills the issue form's version and
  macOS fields.
- Jumping from the outline (or ⌘K, or an anchor link) highlights the
  destination instead of flashing every heading it glides past, and
  sideways trackpad swipes no longer rubber-band the page.
- The short-lived beta release channel is retired in favor of the
  Experimental tab — one release train, features labeled by how
  settled they are. (If you ran a 0.28 beta: thank you — this is the
  same build you tested, and your settings carry over unchanged.)

## 0.28.0-beta.5 - 2026-08-07

- Jumping from the outline (or ⌘K, or an anchor link) no longer
  flashes every heading it glides past — the destination highlights
  immediately and stays highlighted; scrolling yourself mid-glide
  hands control straight back.
- The beta note under the update-channel picker is now one sentence
  with a clickable link to the beta docs.

## 0.28.0-beta.4 - 2026-08-07

- **Big repos stopped nagging** — the folder scan now takes up to
  20,000 Markdown files (was 2,000), and hitting a limit no longer
  pops a dialog — let alone one per file change. The quiet "Showing
  the first N Markdown files" note inside the folder's own tree is the
  single indicator, and it should now be rare outside pathological
  roots.
- **Hidden files, when you want them** — Settings → General → "Show
  hidden files", View → Show Hidden Files, or Finder's own ⇧⌘.
  (rebindable). Every open Location rescans on the flip, so
  `.github/` docs and friends appear in place. The `.git` store is
  always skipped.
- **Settings, reorganized so every section predicts its contents** —
  the Light/Dark/System picker now lives at the top of the Appearance
  tab (its General section collided with the tab's name); General is
  now Reading, Reviewing, Updates, System, and Experimental, with
  Quick Look filed under System where the integrations live and the
  update controls promoted out of System into their own section.
- **Updates meet you where you are** — when an update is already
  known, Settings shows What's New (right there, not a pointer at the
  main window), Update Now, and a refresh button that looks for
  something even newer; progress and failures show inline.
- **What's New tells the whole story** — the update offer now shows
  the notes of every release between your version and the new one,
  not just the newest: updating from 0.26 straight to 0.28 includes
  what 0.27 changed.

## 0.28.0-beta.3 - 2026-08-07

- **Margin notes are now an experimental setting** — off by default,
  switched on in Settings → General → **Experimental**. The toggle
  gates the authoring tools (the hover bubble, ⌥⌘M, the Edit-menu
  items, Edit/Delete on bubbles); documents that already contain notes
  always render them, so a file annotated by a teammate or an agent
  never shows you nothing. This is the shape margin notes will keep
  when they reach the stable channel: the beta settles the format, the
  experimental switch lets you decide whether the workflow is for you.
- **Help → Report a Bug…** now pre-fills the version and macOS fields
  of the issue form — the app knows both better than you do, and it
  matters more now that beta and stable versions coexist.

## 0.28.0-beta.2 - 2026-08-06

- Margin-note and review-comment bubbles in the margin rail now stay
  clear of the overlay scrollbar when the web view is narrow (sidebar
  and outline open) — first beta feedback, thanks!
- Sideways trackpad swipes no longer rubber-band the page: documents
  never scroll horizontally by design (wide code blocks and tables
  scroll within themselves), so the page now says so.

## 0.28.0-beta.1 - 2026-08-06

- **Margin notes (beta)** — leave comments on any local Markdown
  document, the way you would on a pull request. Hover a block for the
  note bubble (or select text first to quote it), write in Markdown,
  and the note is saved into the file itself as a plain HTML comment —
  `<!-- note @you: like this -->` — invisible to GitHub and every other
  renderer, but rendered by PullMark as a comment bubble pinned to that
  spot. Built for reviewing documents an agent wrote for you: tell the
  agent to address the notes and delete them as it goes, and watch the
  bubbles disappear live.
  - Edit and delete from each bubble; **File Margin Note** (Edit menu)
    for document-level notes; ⌥⌘M notes the block you're reading.
  - Open Files rows show a comment-count chip while a document still
    carries notes.
  - Notes render read-only in browsed GitHub files, never appear in
    print or exports, and View → Hide Margin Notes clears the page.
  - The format is a documented convention, not an app database:
    [pullmark.app/docs/beta/margin-notes](https://pullmark.app/docs/beta/margin-notes/)
    has the two-sentence spec and a paste-into-your-CLAUDE.md snippet
    for agents.
- **A beta channel** — this release inaugurates it. Betas are signed
  and notarized like any release; get them with
  `brew install --cask jedijashwa/tap/pullmark@beta` (or the release
  DMG), and Settings → General → Update channel keeps you on the
  track you choose. Stable installs never see prereleases.

## 0.27.2 - 2026-08-07

- The update-channel note in Settings is now one sentence with a
  clickable link to the beta docs.

## 0.27.1 - 2026-08-07

- **PullMark has a beta channel now** — and this update is how the
  stable channel finds out. Settings → General → **Update channel:
  Beta** makes the update banner offer pre-release versions; Stable
  (the default) never sees them. Betas are signed and notarized like
  any release — what's "beta" is the feature design, which may still
  shift with feedback.
- First up on the channel: **margin notes** — comment on any local
  Markdown document the way you'd comment on a PR, saved into the file
  itself in a format agents can read and act on. The whole story:
  [pullmark.app/docs/beta](https://pullmark.app/docs/beta/).

## 0.27.0 - 2026-08-06

- **Open Files, with previews** — the Files section is now Open Files:
  the flat, reorderable working set of everything you've explicitly
  opened. Single-clicking a file inside a Location shows it as a
  *preview* — one italicized entry, always last in the section, that
  the next single-click replaces — so browsing a big tree never piles
  up rows, and the file you were just reading always has exactly one
  place to be found.
  - **Keeping a file**: double-click it (in the tree or on the italic
    entry), choose Keep Open from the right-click menu, or just start
    editing — authoring always pins; reading (blame, history,
    inspecting an image) never does. External opens — Finder, drag &
    drop, ⌘O, the CLI — pin as before.
  - **A setting to taste**: Settings → General → "Clicking files in
    Locations" — Preview First (default) or Open Fully, which keeps
    every file you click.
  - **Reveal in Location** on any Open Files row jumps to where the
    file lives in its tree; Close All lives on the section header;
    the preview survives relaunch, still as a preview.
  - Clicking a relative link to a file in an open Location now
    previews it instead of pinning a row.
  - **Remote repos preview too, in the same place** — browsing a
    GitHub repo's tree or following links inside a remote doc puts
    the same single italic entry in Open Files (book icon,
    `owner/repo @ ref` second line) instead of permanently growing
    the session's docs list. One preview per window, local or
    remote. Keeping a remote doc — double-click or Keep Open — files
    it with its repo under Locations; kept docs get a hover-✕, sit
    above the tree so they never drown under a big repo, and ⌘K
    opens still pin directly.
- **A real CLI** — `pullmark --help` and `--version` exist now, with
  errors that name the path that didn't resolve (and abort the whole
  open, so scripts fail loudly). `pullmark <worktree> <file>` opens
  the worktree as a Location and shows the file — made for agents
  putting a document in front of you. Everything still lands in the
  frontmost window of a running app.
- **Docs** — pullmark.app grew a documentation section:
  [pullmark.app/docs](https://pullmark.app/docs/) covers the features,
  the sidebar and every icon, all settings, the full keyboard map, the
  CLI, and troubleshooting.

## 0.26.1 - 2026-08-05

- ⌘K now accepts GitHub URLs typed without the scheme —
  `github.com/owner/repo` and `github.com/…/blob/…` work the same as
  their `https://` spellings.

## 0.26.0 - 2026-08-05

- **GitHub Markdown links open in PullMark** — click a
  `github.com/…/blob/…` (or raw) link to a Markdown file and PullMark
  fetches and renders it in-app instead of bouncing to the browser.
  The first click asks which behavior you want; your choice becomes
  the default (Settings → General), and ⌘-click always does the other.
  The link-status pill in the corner says where a hovered link will
  open — and flips live while ⌘ is held.
  - **Provenance is always visible**: a bar above the content reads
    `owner/repo @ ref · path`, shows the exact commit the ref resolved
    to, and carries the Open on GitHub control — you never have to
    wonder whether you're reading a local file or a repo.
  - **Remote docs are browsable**: relative links (`./sibling.md`,
    `../other/doc.md`) resolve against the repo at the same pinned
    commit, images load the same way, and Browse Repo Files fetches
    the repo's whole Markdown tree into the sidebar. ⌘K accepts blob
    URLs and `github.com/owner/repo` too.
  - **PRs keep precedence**: a link into a repo you have open as a
    pull request opens in the PR space — the rendered diff when the
    file is part of the PR, the PR's browsed docs at its head branch —
    and a link to any other branch opens pinned to *that* branch.
  - **Blame and branch compare work there too**: the blame gutter and
    a Compare menu (rendered diff against any other branch) come along
    from the PR machinery.
  - **Private repos work** with the same GitHub credentials PRs
    already use; failures say loudly whether a file is missing or
    possibly unauthorized. Nothing fetched touches disk, sessions
    restore as references only, and no link is fetched without an
    explicit click.
  - Heading anchors now match GitHub's slug rules exactly
    (underscores survive, consecutive spaces keep their hyphens), so
    `#section` links written for GitHub land correctly in PullMark
    and vice versa.
- **A calmer sidebar** — four sections instead of six. Local folders
  and GitHub repos now share one **Locations** section (browsable
  roots, wherever they live — repo rows wear GitHub's book icon and
  show their ref), and Review Requests became a subgroup inside
  **Pull Requests**, unread badge intact.
- **Every Location says what it is** — a plain folder is just a
  folder; a git checkout gains a branch chip; a checkout of a GitHub
  repo adds a small book mark; a remote repo is the book itself. The
  chip is a control: on remote repos it switches the session's branch
  in place or opens another branch as a sibling Location (⌥-pick does
  it from the same list); on local checkouts it lists the repo's
  **worktrees** — each opens as its own Location — and, for
  GitHub-backed folders, other branches viewable from GitHub
  (preferring a worktree when one has that branch checked out).
  PullMark never checks anything out — disk state is discovered and
  read, never mutated. Fork + upstream remotes both count as the
  repo's identity, and links to a repo you have cloned on the linked
  branch now open the **local** file instead of fetching.
- **Places show their README** — selecting a folder, a folder in its
  tree, or a remote repo renders that directory's README (or index
  file) instead of an empty placeholder, GitHub-style.
- The ask dialog for GitHub links grew a **Remember my selection**
  checkbox: checked (the default), your choice becomes the standing
  policy; unchecked, it applies once — and the unchecked state is
  itself remembered.

## 0.25.0 - 2026-08-04

- **A `pullmark` command** — open files and folders from the shell:
  `pullmark README.md`, `pullmark docs/`, or bare `pullmark` for the
  app itself, with relative paths resolved against your working
  directory. Homebrew installs it automatically; DMG installs add it
  with one click in Settings → General → Command line.
- **Links go where they point** — relative links in local documents now
  follow symlinks (including ones that lead outside the folder you
  opened — common in cloud-drive setups) and `../` paths to sibling
  folders, instead of failing silently. A link whose target genuinely
  doesn't exist says so, naming the path. Images and other resources
  the page loads by itself keep their stricter containment.

## 0.24.0 - 2026-08-04

- **The sidebar navigator, rebuilt**
  ([#32](https://github.com/jedijashwa/pullmark/issues/32)) — the
  navigation panel's interactions are now first class:
  - **Folders are real places**: opening a folder shows a closeable
    root with a live file tree — folders first, single-child chains
    compressed (`docs/en/guide`), empty directories pruned — instead
    of a flat dump of every file. Files added, renamed, or deleted on
    disk appear in the tree as they happen, and a root whose path
    disappears (branch switch, unmounted volume) dims and revives
    instead of vanishing. View as List remains per root.
  - **Five honest sections**: Files (documents you opened
    individually), Folders, Pull Requests — whose changed-file lists
    are now the same trees, with status icons and unresolved-comment
    badges — Review Requests, and Recents. Every row selects and
    participates in keyboard navigation.
  - **Closing things is easy**: hover any removable row for ✕, press
    ⌫ on a selection, or use the grown context menus — Remove,
    Reveal in Finder, Copy Path, Refresh Folder, Clear Recents — all
    also in the File menu as rebindable commands.
  - **Recents tell the truth**: an entry whose file has gone missing
    dims with a "last seen at" tooltip and revives automatically when
    the file returns; clicking one offers Remove from Recents instead
    of an error.
  - **Session restore keeps up**: relaunching restores folder roots
    with their expansion — including files added while the app was
    closed. Drag top-level rows to reorder; the order persists.
  - Plus: ⌥-click deep-expands a subtree, Space Quick Looks the
    selected file (macOS 14+), empty sections offer Open buttons, and
    ⌘K / ⇧⌘F cover everything in folder trees.

## 0.23.0 - 2026-08-04

- **Line numbers in rendered views** — a new Appearance setting, off by
  default: each block shows its starting source line in the margin of
  rendered documents and diffs, with the block's full range on hover.
  Rendered text wraps freely, so numbering is per block — the rendered
  views' honest answer to "where is this in the file?" (the raw source
  view keeps its true per-line gutter). Diffs number by the new file;
  removed blocks keep their old-file coordinates, and side-by-side view
  numbers each column by its own side. Plays with blame: numbers sit
  nearest the text, history outside them.
- **Appearance settings** — the Themes settings tab is now Appearance:
  theme cards under their own header with the custom-theme controls
  beside them, and each layout choice — theme, content width, line
  numbers — presented as selectable preview cards.

## 0.22.0 - 2026-08-04

- **Review conversations** ([#29]) — reviewing now happens wherever
  you read:
  - **Threads in the Result view**: comment badges in the margin with
    counts, clustered per block; click to expand the conversation in
    place. Resolved conversations stay tucked away until you ask —
    "Show Resolved Conversations" lives in the View menu (rebindable)
    and at the end of the document.
  - **An honest review state**: one toolbar control reads "Review
    changes" or "Finish your review · N" — and N is true, because
    pending reviews live on GitHub, not in app memory. Reviews started
    on github.com appear in PullMark and vice versa; quitting loses
    nothing. "Abandon review" (with confirmation) discards server-side.
  - **Verdicts that can't happen by accident**: Comment / Approve /
    Request changes as an explicit selection, Comment preselected every
    time, one Submit button. On your own PR, Approve and Request
    changes are disabled with the reason inline.
  - **An in-page composer** replacing the sheet: it expands beneath the
    block, brings itself into view, pre-fills suggestions from the
    block's lines, narrows its range to your text selection, and keeps
    drafts when you click away. One comment bubble on a fixed margin
    rail (the margin is part of the hover zone — park your pointer
    there and scroll); suggestion editing starts inside the composer.
  - **Reactions and comment management**: react with GitHub's eight
    emoji on any published comment; edit or delete your own from the
    ⋯ menu. Resolved threads in diff views collapse to one line.
  - **Comment counts** on sidebar file rows, plus a note on the PR
    overview when comments live on files PullMark doesn't show.

[#29]: https://github.com/jedijashwa/pullmark/issues/29

## 0.21.0 - 2026-07-31

- **Content width** — choose how far text may stretch before it wraps:
  **Standard** (the classic reading measure, still the default), **Wide**
  (longer lines, more on screen, still capped), or **Full Width** (the
  document gets the whole window — made for full screen). Pick in
  Settings → Themes with illustrated previews, or switch mid-read from
  View → Content Width; changes apply live to every open document and
  keep your place. Plays with every theme, the blame gutter, diffs, and
  zoom. Requested by a full-screen reader tired of the dead space.

## 0.20.6 - 2026-07-29

- Dropping a Markdown file (or folder) onto the rendered document now
  opens it, matching the sidebar and the Dock icon. The page previously
  swallowed drops silently — and it covers most of the window.

## 0.20.5 - 2026-07-28

- Toggling edit mode keeps your place in the document. Entering edit
  mode now auto-reveals the block you were reading instead of the first
  block, so long documents no longer snap back to the top; leaving edit
  mode restores your scroll position too.

## 0.20.4 - 2026-07-28

- The Compare menu (and blame, and the titlebar branch) now notice
  commits made while a file is open: git info refreshes when you switch
  back to the app and after in-app commits, so a file's first commit no
  longer leaves the menu showing only branches until reopened.
- The Compare menu is now a native menu built fresh on every click —
  previously the first open after history or branches changed could
  show stale rows, or truncate new ones to the old menu's width.

## 0.20.3 - 2026-07-27

- The review-request unread count no longer hugs the sidebar's edge —
  it aligns with the section's rows.

## 0.20.2 - 2026-07-27

- The review-request inbox no longer flashes unfiltered on refresh or
  at launch: Markdown-file counts are resolved before the list updates
  (published together, atomically), counts survive a PR's activity
  bumps as placeholders while re-counting, and the cache persists
  across launches.

## 0.20.1 - 2026-07-27

- A dedicated bug hunt, all confirmed with reproductions, all fixed:
  opening edit mode on a Windows-authored (CRLF) file no longer rewrites
  its line endings on disk — visiting a block is a true no-op, and real
  edits keep the file's own endings; CRLF documents now split into
  blocks properly, so PR diffs, comment targeting, and blame regain
  per-paragraph precision; relative links with #anchors work in local
  documents; ⌘F no longer counts invisible math markup (searching
  "frac" won't scroll to nothing); percent-encoded image names in PRs
  load instead of 404ing; a GitHub hiccup now shows a "comments couldn't
  be loaded" banner with Retry instead of silently presenting a
  commented PR as clean; old-side review comments anchor to the right
  block (or honestly report as outdated) instead of guessing; ⌘K
  heading jumps work for "## Heading ##" styles; a document deleted and
  recreated (e.g. a git checkout round-trip) picks its file watcher
  back up; clicking the end-of-document "+" and clicking away no longer
  appends blank lines; a document opening with a horizontal rule is no
  longer misread as YAML metadata; and updating from an oddly-named
  folder relaunches correctly.
- Right-clicking rendered content now shows a reading menu — Copy, Copy
  as Markdown, Look Up, Translate, link and image copying, sharing —
  instead of the web view's browser menu.

## 0.20.0 - 2026-07-27

- The media inspector became a true modal: clicking an image, Mermaid
  diagram, or formula now takes over the whole reading area (only the
  sidebar stays live) with a native glass scrim — the document behind
  it is completely covered, the outline folds away, and everything on
  screen is native: pan and zoom gestures, the control capsule, an
  editable zoom percentage, a fit that actually re-centers, an
  actual-size button, and an interactive minimap when you're zoomed
  past the edges (drag it to pan — diagrams generate their own
  thumbnail for it). Diagrams open at their intrinsic size and render
  as live vectors — crisp at any zoom — and Save As…/Share still
  export SVG or PNG for diagrams, original bytes for images, and
  high-resolution captures for formulas. ⌘+/⌘−/⌘0 control the
  inspector while it's open instead of the app behind it, the cursor
  reads right (open hand over content, closed while dragging, arrow on
  the controls), and the format menus unfold upward, clear of the
  capsule.
- The outline panel now genuinely remembers its width: the old split
  view ignored the remembered width at launch and opened at minimum no
  matter what. The panel now owns its width with its own drag handle,
  flush against the panel edge, and only your drags can change it.

## 0.19.0 - 2026-07-27

- The lightbox grew up: its controls are now a native glass capsule at
  the bottom center (real materials, real SF Symbols — where macOS puts
  transient media controls), the document behind the scrim is truly
  frozen while it's open, and two new buttons export exactly what you're
  inspecting — Save As… and Share. Mermaid diagrams offer both formats
  (real SVG — crisp at any size, built for huge charts — or a
  high-resolution PNG), images export their original bytes, and formulas
  render at high resolution.
- Fresh installs now open with the window, sidebar, and outline sized
  the way the app is meant to be read (1317×698, 278pt, 255pt) — and a
  narrow window squeezing the outline to its minimum no longer
  overwrites the width you chose.
- The word-count pill no longer overlaps the scrollbar.

## 0.18.0 - 2026-07-27

- Click any image, Mermaid diagram, or block formula to inspect it: a
  focused overlay opens with pan and zoom (drag or scroll to pan; pinch,
  ⌘-scroll, +/− or a double-tap to zoom; Esc or a click outside to
  close) — complex diagrams no longer have to fit the reading column.
- A "feels more Mac" round: the title bar carries the open document's
  proxy icon (drag it anywhere, ⌘-click the title for the folder path),
  documents you open show up in the Dock icon's right-click menu and
  Apple → Recent Items, and a Share button on documents and pull
  requests sends the file (or the PR link) to Mail, Messages, AirDrop,
  and friends.
- Zoom niceties: a two-finger double-tap smart-zooms between 100% and
  your last level (Safari-style), a quiet haptic tick marks the end of
  the range, and the zoom pill and outline scrolling respect the
  system's Reduce Motion setting.
- File → Page Setup… (⇧⌘P) — paper size and orientation now carry into
  Print.

## 0.17.0 - 2026-07-27

- Magnification ([#12](https://github.com/jedijashwa/pullmark/issues/12)): ⌘+ / ⌘− zoom the document in browser style — text,
  images, and the content column all scale together, reflowing to the
  window and never past its edge — and ⌘0 (View → Actual Size) resets.
  Pinch and ⌘-scroll zoom the page too, a brief pill shows the level
  (VoiceOver announces it), and the setting sticks across launches,
  app-wide. The sidebar and outline grow along with the reading size (at
  a gentler rate, so navigation never turns into a billboard), while
  print and PDF export stay at 100% regardless. Zoom In/Out/Actual Size
  are rebindable in Settings → Keyboard like every other command.

## 0.16.2 - 2026-07-21

- The outline panel remembers its width across launches (the sidebar
  always did; the outline's divider had no memory of its own), and a
  window quit in full screen comes back in full screen.

## 0.16.1 - 2026-07-21

- Actually killed the white flash while pages load. 0.16.0 fixed the
  first paint's color but the web view itself still painted opaque white
  for an instant before that on current macOS — the transparency call
  was silently skipped because WebKit renamed the private setter it
  checks for. Both spellings are accepted now, so loading shows the
  theme's paper color from the very first frame.

## 0.16.0 - 2026-07-21

- The sidebar is yours to arrange around: every section collapses with a
  click on its header (state remembered), and Review Requests moved below
  Local Files and Pull Requests — what you opened yourself outranks what
  was assigned to you.
- Open Quickly (⌘K) now also opens things that aren't open yet: paste a
  GitHub pull request URL (or owner/repo#123) or type an absolute path
  (/…, ~/…) and the first row offers to open it directly.
- A brand-new file in a pull request no longer tints every block green —
  one note at the top says the whole document is new, and the added/
  removed highlights stay reserved for actual changes in changed files.
- The comment and suggestion sheet got room to breathe: helper text moved
  out of the button row, buttons no longer squish or truncate, and Add to
  Review is now the prominent ⌘↩ default (Comment Now moved to ⇧⌘↩) —
  batching a review is what a review app should encourage.
- Comment on exactly the lines you mean: when a comment targets a
  multi-line block, the sheet lists the block's source lines — click one
  to target just it, shift-click to extend. Suggestions re-seed to the
  narrowed lines while untouched.
- Review a pull request without writing line comments: the overview's
  Review box now always offers Approve, Request Changes, and Comment
  (with an optional summary), matching GitHub's review flow. A separate
  field posts plain conversation comments, and every PR file's toolbar
  gained "Comment on File" for whole-file notes.
- Getting around a pull request no longer needs the sidebar: a PR file's
  toolbar now has a back-to-overview button, previous/next file arrows,
  and a "2 of 5" jump menu.
- The review-request inbox now shows only pull requests that change
  Markdown by default (Settings → General can bring back the rest), and
  carries an unread count in its header even while collapsed.
- No more white flash while pages load in dark mode: the first paint now
  uses the current theme's paper color in both appearances, and the
  backdrop behind loading pages matches it.
- Check for Updates (PullMark menu) now reports its result in an alert.
  Before, the "you're up to date" reply went to the focused document
  window — and was silently dropped when Settings was key or no window
  was open, making the menu item look like it did nothing.

## 0.15.2 - 2026-07-21

- Fresh installs now actually default to the Editorial reading theme. The
  default was changed to Editorial some releases ago, but the views' own
  fallback still said GitHub, so a machine that had never touched
  Settings → Themes read documents in GitHub while Quick Look previews
  correctly used Editorial. Machines where a theme was ever selected are
  unaffected.

## 0.15.1 - 2026-07-21

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
