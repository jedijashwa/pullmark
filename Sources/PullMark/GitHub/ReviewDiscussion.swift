import Foundation

/// The PR overview's "Review discussion" section (spec:
/// pr-review-discussion): every review thread on the PR — rendered
/// files and not — grouped by file in the PR's changed-file order,
/// each thread carrying a clamped tail of its REST diff hunk so the
/// commented line is always the excerpt's last line. Pure assembly;
/// the overview page renders it.
enum ReviewDiscussion {
    /// One excerpt line. `kind`: "add", "del", or "ctx" — the page
    /// tints add/del like diff blocks.
    struct ExcerptLine: Encodable, Equatable {
        let text: String
        let kind: String
    }

    struct ThreadItem: Encodable, Equatable {
        let lineLabel: String
        let comments: [CommentPayload]
        let rootID: Int
        /// Nil when GraphQL thread meta is unavailable — the cards then
        /// suppress Resolve, exactly like the file views.
        let resolved: Bool?
        let outdated: Bool
        let excerpt: [ExcerptLine]
        /// highlight.js language for the excerpt (nil renders plain).
        let language: String?
        /// Root comment's #discussion_r permalink — the one deep link
        /// that still lands when a thread is outdated.
        let htmlUrl: URL?
    }

    struct FileGroup: Encodable, Equatable {
        let path: String
        /// The file renders in PullMark → threads offer View in File;
        /// otherwise they offer Show on GitHub.
        let isMarkdown: Bool
        let unresolvedCount: Int
        let threads: [ThreadItem]
    }

    /// Grouped discussion payload. `fileOrder` is the PR's changed-file
    /// list; `renames` maps a file's previous path to its current one so
    /// threads from before a rename join the renamed file's group.
    /// Commented paths outside both (historic paths on outdated threads)
    /// follow alphabetically so nothing vanishes.
    static func groups(comments: [ReviewComment],
                       meta: [Int: ThreadMeta],
                       viewer: String?,
                       markdownPaths: Set<String>,
                       fileOrder: [String],
                       renames: [String: String] = [:]) -> [FileGroup] {
        let threads = ReviewThreads.group(comments)
        var byPath: [String: [ReviewThread]] = [:]
        for thread in threads {
            byPath[renames[thread.path] ?? thread.path, default: []].append(thread)
        }

        var orderedPaths = fileOrder.filter { byPath[$0] != nil }
        let extras = byPath.keys.filter { !fileOrder.contains($0) }.sorted()
        orderedPaths.append(contentsOf: extras)

        return orderedPaths.map { path in
            // Tie-break on root id: Swift's sort is unstable, and two
            // threads on one line must keep chronological order.
            let fileThreads = (byPath[path] ?? []).sorted {
                (anchorSortKey($0), $0.root.id) < (anchorSortKey($1), $1.root.id)
            }
            let items = fileThreads.map { thread -> ThreadItem in
                let threadMeta = meta[thread.root.id]
                return ThreadItem(
                    lineLabel: thread.lineLabel,
                    comments: thread.comments.map {
                        CommentPayload($0, meta: threadMeta, viewer: viewer)
                    },
                    rootID: thread.root.id,
                    resolved: threadMeta?.isResolved,
                    outdated: thread.isOutdated,
                    excerpt: thread.isFileLevel ? [] : excerpt(from: thread.root.diffHunk),
                    language: CodeLanguages.hljsLanguage(forPath: path),
                    htmlUrl: thread.root.htmlUrl)
            }
            let unresolved = items.filter { $0.resolved != true }.count
            return FileGroup(path: path,
                             isMarkdown: markdownPaths.contains(path),
                             unresolvedCount: unresolved,
                             threads: items)
        }
    }

    /// Whole-file threads first, then by anchor line (outdated threads
    /// sort at their original line — where the conversation was).
    private static func anchorSortKey(_ thread: ReviewThread) -> Int {
        if thread.isFileLevel { return -1 }
        return thread.root.line ?? thread.root.originalLine ?? Int.max
    }

    /// The last `limit` content lines of a REST diff hunk. The hunk
    /// runs from its `@@` header down to exactly the commented line
    /// (verified API shape), so keeping the tail keeps the anchor
    /// visible as the final line. "\ No newline at end of file" markers
    /// are noise, not code.
    static func excerpt(from hunk: String?, limit: Int = 4) -> [ExcerptLine] {
        guard let hunk, !hunk.isEmpty else { return [] }
        // Empty elements are trailing-newline artifacts, never code — a
        // blank context line arrives as a single space. Dropping them
        // keeps the commented line as the excerpt's true last line.
        let lines = hunk.components(separatedBy: "\n")
            .filter { !$0.isEmpty && !$0.hasPrefix("@@") && !$0.hasPrefix("\\") }
        return lines.suffix(limit).map { raw in
            // CRLF hunks carry a trailing \r per line — a raw CR inside
            // white-space:pre renders as a spurious break.
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            switch line.first {
            case "+": return ExcerptLine(text: String(line.dropFirst()), kind: "add")
            case "-": return ExcerptLine(text: String(line.dropFirst()), kind: "del")
            default:
                let text = line.hasPrefix(" ") ? String(line.dropFirst()) : line
                return ExcerptLine(text: text, kind: "ctx")
            }
        }
    }
}
