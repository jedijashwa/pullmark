# Copy GitHub link

Any local document, folder, or tree directory that lives in a checkout
with a GitHub remote gets a one-click "Copy GitHub Link": the
github.com URL for that thing, at the current branch by default, at the
exact commit via ⌥ or a setting. Context menus beside Copy Path, plus a
File-menu command with a rebindable shortcut.

## Motivation

Josh (2026-08-20): local docs with remotes need "an easy way to copy a
github link." Reading a doc in PullMark and pointing a teammate (or an
agent, or an issue) at it currently means reconstructing the URL by
hand on github.com. The app already knows everything the URL needs —
LocalGit parses GitHub remotes, branch, toplevel, and relative paths
for the sidebar — nothing is fetched, only assembled.

## §1 The URL builder (Core)

`Sources/PullMark/Core/GitHubLink.swift` — pure and unit-tested, the
only new logic:

- Inputs: owner, repo, ref (branch name or commit SHA), repo-relative
  path, and a kind: `.file`, `.directory`, `.root`.
- Output: `https://github.com/{owner}/{repo}/blob/{ref}/{path}` for
  files, `.../tree/{ref}/{path}` for directories, `.../tree/{ref}`
  for the root.
- Path and ref components are percent-encoded per segment; `/` inside
  branch names stays verbatim (GitHub resolves ref/path greedily).

## §2 Link style: branch vs permalink

- **Branch link** (`blob/<branch>/…`): reads naturally, tracks the doc
  as it evolves. May 404 until the branch is pushed — the same honesty
  as Copy Path (we copy; where it resolves is the repo's business).
- **Permalink** (`blob/<HEAD-SHA>/…`): durable forever once pushed,
  frozen content.
- **Setting** (Settings → General): "Copy GitHub links as: Current
  branch / Exact commit (permalink)". Defaults key
  `pm.githubLinkStyle` (`branch` | `commit`), default `branch`.
- **Menu naming rule:** the primary item is always titled "Copy GitHub
  Link" and copies whatever the setting says. The ⌥ alternate names
  the *other* flavor explicitly: "Copy GitHub Permalink" when the
  default is branch, "Copy GitHub Branch Link" when the default is
  commit. ⌥ alternates use `modifierKeyAlternate` (macOS 15+); on
  13/14 the menus show only the primary item — the setting still
  chooses its flavor.
- Detached HEAD (no branch name): the branch flavor falls back to the
  SHA form automatically — the item never dead-ends.

## §3 Eligibility and resolution

- A row/command shows the item when the URL has a `.git` ancestor —
  a pure filesystem walk at menu-build time (no subprocess in a view
  builder; `.git` may be a file, which is how worktrees look, and
  counts).
- The git work runs only on click: repo root, branch (or HEAD SHA for
  permalinks), and the GitHub remote — origin first, else the first
  GitHub remote among the others, matching RepoInfo's own preference.
- Repo has no GitHub remote at click time: nothing is copied and the
  quiet notice line says "This repository has no GitHub remote."
  (lastNotice, never the error alert).

## §4 Surfaces

- **Context menus**, directly under "Copy Path", in every menu that
  has one today: open-file rows (and the preview row), folder-tree
  file rows, Location root rows, folder-node rows.
- **File menu**, after Copy Path: new `ShortcutAction.copyGitHubLink`
  ("Copy GitHub Link", category File, ships unbound like the other
  sidebar commands, scope note "With a local file or folder
  selected"). Enabled when the selection is a local file, folder
  root, or folder node whose URL passes the `.git`-ancestor test.
  The ⌥ alternate appears here too (same 15+ gating).
- The action copies to the general pasteboard.

## §5 Interactions with existing features

- Copy Path: unchanged; the new item sits beneath it everywhere.
- PR files and remote docs: untouched — they already carry canonical
  GitHub links via Share.
- Blame/compare: unaffected; the feature reads the same LocalGit
  plumbing, writes nothing.
- Worktrees: `.git`-file checkouts resolve like clones (existing
  LocalGit behavior).
- Untracked or unpushed files: the link copies and may 404 until
  pushed — deliberate, matching Copy Path.

## §6 Out of scope

- Line/heading anchors in copied links.
- The Share flow and the titlebar proxy menu (declined).
- Any validation that the link resolves.

## §7 Verification

- Unit tests for `GitHubLink` (kinds, encoding, slash-bearing branch
  names, permalink form) and for the eligibility walk (worktree `.git`
  file).
- Live: context-menu presence/absence in and out of repos, the ⌥
  swap, the setting flip, detached-HEAD fallback, no-remote notice.
