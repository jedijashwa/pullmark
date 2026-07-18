# Changelog

Notable user-facing changes to PullMark. Release notes for GitHub releases are
extracted from this file by `scripts/make-release.sh` — keep the `## Unreleased`
section current as features land.

## Unreleased

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
