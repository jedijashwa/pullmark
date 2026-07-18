# PullMark demo document

This file exercises the GitHub-flavored Markdown features PullMark renders.

## Table

| Feature | Status |
|---|---|
| Tables | ✅ |
| Task lists | ✅ |
| Mermaid | ✅ |

## Task list

- [x] Render local files
- [x] Rendered PR diffs
- [ ] Editing (later)

## Code preview

```swift
struct MarkdownBlock: Equatable {
    let text: String
    let startLine: Int
    let endLine: Int
}
```

## Mermaid

```mermaid
flowchart LR
    A[Local .md file] --> R[Rendered view]
    B[GitHub PR] --> D[Rendered diff]
    D --> C{Comment?}
    C -->|Comment now| G[(GitHub API)]
    C -->|Add to review| P[Pending review] --> G
```

## Alert

> [!NOTE]
> Alerts use GitHub's callout syntax.

> [!WARNING]
> This one is a warning.

~~Strikethrough~~ and a [link](https://github.com).

## Relative image

![PullMark icon](img/pullmark.png)
