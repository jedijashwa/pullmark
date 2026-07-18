# PullMark

**A lightweight, native macOS app for reading Markdown — locally, and in GitHub pull requests.**

PullMark renders local Markdown files with GitHub-style formatting, and opens GitHub PRs to show their Markdown changes as **rich rendered diffs** — formatted output with changed words highlighted, not walls of `+`/`-` source lines. You can comment on the diff directly, collect comments into a review, and submit or save it as a pending (draft) review. It authenticates with the GitHub credentials already on your system, so private and organization repos just work.

## Features

- **Local Markdown viewing** — open files or whole folders; files re-render automatically when they change on disk; relative images and links between local Markdown files work.
- **GitHub-flavored rendering** — tables, task lists, strikethrough, alerts/callouts (`> [!NOTE]`), syntax-highlighted code blocks, and Mermaid diagrams.
- **Rendered PR diffs** — added, removed, and changed blocks highlighted in place. Changed blocks show a **word-level diff** when the edit is small enough to make sense (falling back to old/new stacked when it isn't). Switch between **inline** and **side-by-side** layout, or drop to the raw *Source Diff*, or preview the final *Result*.
- **PR review comments** — existing review threads appear under the blocks they discuss (outdated threads listed at the end). Hover any block and click the bubble to add your own:
  - **Comment Now** posts a single review comment immediately.
  - **Add to Review** collects drafts locally; submit them together (Comment / Approve / Request Changes) or save them to GitHub as a **pending review** to finish later on github.com.
- **Uses your existing credentials** — no separate login (see [Authentication](#authentication)).
- **Light & dark mode** — follows the system by default, with a manual switch that restyles everything, Mermaid included.

## Installation

### Build from source (currently the only method)

Requirements: **macOS 13+** and a Swift 6 toolchain — either Xcode, or just the [Command Line Tools](https://developer.apple.com/download/all/) (`xcode-select --install`). No other dependencies.

```sh
git clone https://github.com/joshriesenbach/pullmark.git
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

## Notes & limitations

- GitHub allows one pending review per user per PR — if you already have one, "Save as Pending" fails until it's submitted or dismissed on github.com.
- Editing is not supported yet; PullMark is a viewer/reviewer.
- Images referenced by PR files (repo-relative) aren't fetched yet; local-file images work.

## License

[MIT](LICENSE) — third-party rendering assets listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
