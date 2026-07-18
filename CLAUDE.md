# PullMark

Native macOS Markdown viewer + GitHub PR Markdown reviewer. SwiftUI + WKWebView, zero package dependencies, plain SwiftPM (no Xcode project).

## Commands

- `make build` — debug build
- `make test` — unit tests (adds Swift Testing search paths when only Command Line Tools are installed)
- `make run` — launch via `swift run`
- `make app` — build `dist/PullMark.app` (release, ad-hoc signed)

## Layout

- `Sources/PullMark/Core/` — pure logic: Markdown block splitting, LCS block diff, appearance
- `Sources/PullMark/GitHub/` — PR URL parsing, REST client, system credential resolution (`gh auth token` → `git credential fill`)
- `Sources/PullMark/Rendering/` — HTML page builder + WKWebView wrapper (JS bridge posts comment requests to Swift)
- `Sources/PullMark/Resources/` — `app.js`/`app.css` and vendored marked/highlight.js/mermaid/github-markdown-css
- `Tests/PullMarkTests/` — Swift Testing (`import Testing`, not XCTest — XCTest is unavailable with CLT)

## Conventions

- Keep core logic (diffing, parsing, request-body building) in pure, non-UI types so it stays unit-testable.
- GitHub review comment positions use file line numbers + side (`RIGHT` = new file, `LEFT` = old); blocks carry their source line ranges through the diff for this.
- Language mode is Swift 5 (set in Package.swift) — don't introduce strict-concurrency-only patterns.
