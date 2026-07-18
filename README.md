# PullMark

**A native macOS app for people who think in rendered Markdown — for reading docs locally, and for reviewing documentation-heavy pull requests.**

## Why PullMark exists

More and more of what flows through pull requests isn't code — it's *documents*: design docs, decision records, agent and skill definitions, runbooks, READMEs. Reviewing those as walls of `+`/`-` source lines is the wrong altitude. A document is meant to be read the way readers will see it: formatted, with tables as tables and diagrams as diagrams. If you're a visual reader, a source diff of prose actively hides what changed.

PullMark shows Markdown changes as **rendered diffs** — formatted output with just the changed words highlighted — and lets you comment, suggest, and submit a review right there. It authenticates with the GitHub credentials already on your system, so private and organization repos just work.

**PullMark is deliberately not a full review client.** It shows only the Markdown files in a PR; for the code parts of a change, your usual review tools remain the right place. Think of it as the reading room next to the workshop.

## Features

- **Local Markdown viewing** — open files or whole folders; files re-render automatically when they change on disk. Relative images render, relative links to other Markdown files open in-app, heading anchors (`#section` links) jump within the page, and external links open in your browser — with a status pill previewing every link destination on hover.
- **GitHub-flavored rendering** — tables (with alignment), task lists, nested/numbered lists, strikethrough, footnotes, alerts/callouts (`> [!NOTE]`), syntax-highlighted code blocks, and Mermaid diagrams. The full construct list is exercised by [docs/kitchen-sink.md](docs/kitchen-sink.md) and asserted in CI by `scripts/render-check.sh`.
- **Rendered PR diffs** — added, removed, and changed blocks highlighted in place. Changed blocks show a **word-level diff** when the edit is small enough to make sense (falling back to old/new stacked when it isn't). Switch between **inline** and **side-by-side** layout, or drop to the raw *Source Diff*, or preview the final *Result*.
- **PR review comments** — existing review threads appear under the blocks they discuss (outdated threads listed at the end). Hover any block and click the bubble to add your own:
  - **Comment Now** posts a single review comment immediately.
  - **Add to Review** collects drafts locally; submit them together (Comment / Approve / Request Changes) or save them to GitHub as a **pending review** to finish later on github.com.
  - **Insert Suggestion** pre-fills a ` ```suggestion ` block with the targeted lines so the author can apply your edit with one click on GitHub.
- **PR images and links** — repo-relative images in PR files render (fetched at the PR's commit, cached in memory only); repo-relative links to Markdown files open in-app at that commit, other repo links open on GitHub.
- **Stays current** — open PRs are checked every minute; if the branch moves, a banner offers a one-click refresh (your draft comments survive).
- **Navigation** — a navigator-style outline sidebar (toolbar toggle) listing the document's headings with level indentation, and **⌘F** find-in-page with match stepping.
- **Recents** — recently opened files, folders, and pull requests live in **File → Open Recent** and a sidebar section. PR entries show their live status — draft, open, closed, merged, or unavailable (colored GitHub-style icons, kept up to date while you work).
- **Quick Look** — press space on any Markdown file in Finder to see it rendered PullMark-style (Mermaid degrades to a code block in previews).
- **Uses your existing credentials** — no separate login (see [Authentication](#authentication)).
- **Light & dark mode** — follows the system by default, with a manual switch that restyles everything, Mermaid included.

## Installation

### Build from source (currently the only method)

Requirements: **macOS 13+** and a Swift 6 toolchain — either Xcode, or just the [Command Line Tools](https://developer.apple.com/download/all/) (`xcode-select --install`). No other dependencies.

```sh
git clone https://github.com/jedijashwa/pullmark.git
cd pullmark
make app
```

This produces `dist/PullMark.app`. Move it wherever you like (e.g. `/Applications`) and launch it:

```sh
mv dist/PullMark.app /Applications/
open /Applications/PullMark.app
```

> [!NOTE]
> The app is ad-hoc signed (not notarized). If Gatekeeper complains on first launch, right-click the app → **Open** → **Open**, or allow it under **System Settings → Privacy & Security**.

For development:

```sh
make run    # launch without building an app bundle
make test   # unit tests
```

### Running from the command line

Install the `pullmark` command:

```sh
make install-cli                     # installs into /opt/homebrew/bin (or /usr/local/bin)
make install-cli BIN_DIR=~/bin       # or anywhere you like
```

Then, from any terminal:

```sh
pullmark                  # open the app
pullmark README.md        # open a file
pullmark notes.md a.md    # open several files
pullmark ~/notes docs/    # open folders — adds every Markdown file inside
```

Relative and absolute paths both work, and files open in the already-running app if there is one.

Without installing anything, the same is available through `open`:

```sh
open -a PullMark README.md ~/notes
```

The app binary itself also accepts paths (`PullMark.app/Contents/MacOS/PullMark <file-or-dir> ...`), so shell aliases pointing at the executable work too.

### Make PullMark the default app for Markdown

PullMark registers as a Markdown viewer, so: right-click any `.md` file in Finder → **Get Info** → **Open with:** → choose **PullMark** → **Change All…**. Every Markdown file will now open in PullMark on double-click.

### Authentication

PR features need a GitHub token for private repos (and for posting comments anywhere). PullMark looks for one in this order — whichever you already have set up wins:

1. **GitHub CLI**: `gh auth token` — if you use [gh](https://cli.github.com), you're done. Otherwise: `brew install gh && gh auth login`.
2. **Git credential helper**: `git credential fill` for `github.com` — the macOS Keychain helper (`osxkeychain`) or any other helper git is configured with.

No credentials at all still works for *reading public repos* (subject to GitHub's lower unauthenticated rate limits).

## Usage

### Local files

- **⌘O** (or the folder toolbar button) opens files or folders. Opening a folder adds every Markdown file in it to the sidebar.
- Files re-render when saved from any editor. Relative images resolve; clicking a relative link to another `.md` file opens it in PullMark.
- You can also drop `.md` files on the Dock icon or use Finder's **Open With → PullMark**.

### Pull requests

1. **⇧⌘O** (or the PR toolbar button), then paste a PR URL — `https://github.com/owner/repo/pull/123` — or the short form `owner/repo#123`.
2. The PR appears in the sidebar with its changed Markdown files; the overview shows the PR description and your in-progress review.
3. Pick a file and choose a view in the toolbar:
   - **Rendered Diff** — formatted output with changes highlighted; toggle *Inline* / *Side by Side* in the adjacent menu.
   - **Source Diff** — the raw patch.
   - **Result** — the file as it will look after merge.
4. Existing review discussions show up beneath the blocks they refer to.

### Commenting and reviewing

- Hover a block in the Rendered Diff and click the speech-bubble button.
- **Comment Now** publishes immediately; **Add to Review** saves a draft locally.
- Drafts live on the PR's overview page: add a summary, then **Submit Review** (Comment / Approve / Request Changes) or **Save as Pending on GitHub** to finish the review in the browser later.
- GitHub only accepts comments on lines that are part of the diff (changed lines plus nearby context). Commenting on an untouched block far from any change returns an API error — PullMark shows it and keeps your text.

### Appearance

Use the half-circle toolbar menu or the **View** menu to switch between **System / Light / Dark**.

## How the rendered diff works

Markdown files are split into blocks (paragraphs, headings, fenced code, …), old and new versions are aligned with an LCS diff, and each block renders to HTML. Added blocks get a green bar, removed blocks red. A changed block gets a **word-level diff**: changed runs are wrapped in invisible sentinels that survive Markdown rendering and become highlight marks afterward — so a one-word edit shows as one highlighted word in formatted text. When two blocks share too little text (or contain code fences), PullMark falls back to showing old and new in full. Every block keeps its original file line numbers, which is what makes GitHub review comments (`line`/`side`) possible from a rendered view.

## Privacy of fetched content

Nothing fetched from GitHub is written to persistent storage: API calls use an ephemeral session, images are cached in bounded memory only, the web views use non-persistent data stores, and rendered pages live in the system temp directory — which macOS purges on reboot even if the app crashed and never ran again.

## Notes & limitations

- GitHub allows one pending review per user per PR — if you already have one, "Save as Pending" fails until it's submitted or dismissed on github.com.
- Editing is not supported yet; PullMark is a viewer/reviewer.
- Quick Look previews render statically: code is highlighted, but Mermaid diagrams appear as code blocks.

## License

[MIT](LICENSE) — third-party rendering assets listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
