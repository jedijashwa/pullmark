# PullMark

A lightweight, native macOS app for reading Markdown — locally and in GitHub pull requests.

PullMark renders local Markdown files with GitHub-style formatting, and opens GitHub PRs to show their Markdown changes as **rich rendered diffs** (not just `+`/`-` source lines). You can comment on the diff directly, or collect comments into a review and submit it — including saving it as a pending (draft) review on GitHub. It authenticates with the GitHub credentials already on your system, so private and organization repos just work.

## Features

- **Local Markdown viewing** — open files or whole folders; files re-render automatically when they change on disk.
- **GitHub-flavored rendering** — tables, task lists, strikethrough, alerts/callouts (`> [!NOTE]`), syntax-highlighted code blocks, and Mermaid diagrams.
- **Rendered PR diffs** — Markdown changes shown as formatted output with added/removed/modified blocks highlighted. Toggle between *Rendered Diff*, *Source Diff* (the raw patch), and *Result* (the file as it will look after merge).
- **PR review comments** — hover any diff block and click 💬 to comment:
  - **Comment Now** posts a single review comment immediately.
  - **Add to Review** collects drafts locally; submit them together as a review (Comment / Approve / Request Changes) or save them to GitHub as a **pending review** to finish later on github.com.
- **Uses your existing credentials** — tries `gh auth token` first, then `git credential fill` (Keychain or any configured credential helper). No separate login, works with private org repos.
- **Light & dark mode** — follows the system by default, with a manual Light/Dark/System switch that applies to both the app chrome and rendered content (including Mermaid themes).

## Requirements

- macOS 13+
- Swift toolchain (Xcode, or just the Command Line Tools) to build
- `gh` CLI logged in, or git credentials for github.com configured, for PR features

## Build & run

```sh
git clone https://github.com/<you>/pullmark.git
cd pullmark

make app         # builds dist/PullMark.app (release, ad-hoc signed)
open dist/PullMark.app

# or, during development:
make run         # swift run PullMark
make test        # unit tests
```

No Xcode project, no package dependencies — plain SwiftPM. The only bundled third-party code is a handful of vendored JS/CSS rendering assets (see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)).

## Usage

- **Local files**: `⌘O` or the folder toolbar button. Opening a folder adds every Markdown file in it.
- **Pull requests**: `⇧⌘O` or the PR toolbar button, then paste a PR URL (`https://github.com/owner/repo/pull/123`) or the short form `owner/repo#123`. Markdown files changed in the PR appear in the sidebar.
- **Commenting**: in a PR file's Rendered Diff, hover a block and click 💬. GitHub only accepts comments on lines that are part of the diff (changed lines and nearby context); commenting far from any change returns an error from the API.
- **Appearance**: toolbar half-circle menu, or the View menu.

## How the rendered diff works

Markdown files are split into blocks (paragraphs, headings, fenced code, …), the old and new versions are aligned with an LCS diff, and each block is rendered to HTML. Added blocks get a green bar, removed blocks red, and a changed block shows its old and new rendering stacked. Every block keeps its original file line numbers, which is what makes GitHub review comments (`line`/`side`) possible from a rendered view.

## Notes & limitations

- GitHub allows only one pending review per user per PR — if you already have one, "Save as Pending" will fail until it's submitted or dismissed on github.com.
- Editing is not supported yet; PullMark is currently a viewer/reviewer.
- Relative images/links inside local Markdown files aren't resolved yet.
- Existing review comment threads aren't displayed yet.

## License

[MIT](LICENSE)
