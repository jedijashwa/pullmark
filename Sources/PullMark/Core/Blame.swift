import Foundation

/// One commit as seen by blame — shared between local `git blame --porcelain`
/// output and GitHub's GraphQL blame (which adds avatar and commit URLs).
struct BlameCommit: Equatable {
    let sha: String
    let authorName: String
    let date: Date?
    let summary: String
    var avatarUrl: String? = nil
    var url: String? = nil

    /// Working-tree lines not yet committed blame to the all-zero sha.
    var isUncommitted: Bool { !sha.isEmpty && sha.allSatisfy { $0 == "0" } }
}

/// A contiguous run of file lines (1-based, inclusive) last touched by one commit.
struct BlameRange: Equatable {
    let start: Int
    let end: Int
    let commit: BlameCommit
}

/// An extra contributor shown as a stacked avatar next to the primary author.
struct BlameAuthorPayload: Encodable, Equatable {
    let name: String
    let avatarUrl: String?
}

/// Per-block blame annotation handed to app.js. Carries the block's Markdown
/// source so the page can render block-by-block with an annotation strip under
/// each block; commit fields are nil for blocks no blame range covers.
struct BlockBlamePayload: Encodable, Equatable {
    let text: String
    let lineStart: Int
    let lineEnd: Int
    var sha: String? = nil
    var shortSHA: String? = nil
    var author: String? = nil
    var avatarUrl: String? = nil
    var dateLabel: String? = nil
    var headline: String? = nil
    var url: String? = nil
    /// Up to two additional distinct contributors (most recent first).
    var others: [BlameAuthorPayload]? = nil
    var uncommitted: Bool? = nil
}

/// Pure mapping from per-line blame ranges to per-block annotations.
enum BlameMapper {
    /// For each rendered block: the most recent commit touching its line
    /// range, plus up to two more distinct contributors (three avatars total).
    static func annotations(blocks: [MarkdownBlock], ranges: [BlameRange],
                            now: Date = Date()) -> [BlockBlamePayload] {
        blocks.map { block in
            var payload = BlockBlamePayload(text: block.text,
                                            lineStart: block.startLine,
                                            lineEnd: block.endLine)
            let overlapping = ranges.filter {
                $0.start <= block.endLine && $0.end >= block.startLine
            }
            guard !overlapping.isEmpty else { return payload }

            var seen = Set<String>()
            var commits: [BlameCommit] = []
            for range in overlapping where seen.insert(range.commit.sha).inserted {
                commits.append(range.commit)
            }
            commits.sort {
                let l = $0.date ?? .distantPast, r = $1.date ?? .distantPast
                return l != r ? l > r : $0.sha < $1.sha
            }

            let primary = commits[0]
            payload.sha = primary.sha
            payload.shortSHA = String(primary.sha.prefix(7))
            payload.author = primary.authorName
            payload.avatarUrl = primary.avatarUrl
            payload.dateLabel = primary.date.map { relativeLabel(from: $0, to: now) }
            payload.headline = primary.summary.isEmpty ? nil : primary.summary
            payload.url = primary.url
            payload.uncommitted = primary.isUncommitted ? true : nil

            var authors: Set<String> = [primary.authorName]
            var others: [BlameAuthorPayload] = []
            for commit in commits.dropFirst() where authors.insert(commit.authorName).inserted {
                others.append(BlameAuthorPayload(name: commit.authorName,
                                                 avatarUrl: commit.avatarUrl))
                if others.count == 2 { break }
            }
            payload.others = others.isEmpty ? nil : others
            return payload
        }
    }

    /// "3 weeks ago"-style label, computed in Swift so the page shows plain
    /// strings (no date logic in JS).
    static func relativeLabel(from date: Date, to now: Date = Date()) -> String {
        func plural(_ n: Int, _ unit: String) -> String {
            "\(n) \(unit)\(n == 1 ? "" : "s") ago"
        }
        let seconds = now.timeIntervalSince(date)
        if seconds < 45 { return "just now" }
        let minutes = max(1, Int((seconds / 60).rounded()))
        if minutes < 60 { return plural(minutes, "minute") }
        let hours = Int((seconds / 3600).rounded())
        if hours < 24 { return plural(hours, "hour") }
        let days = Int((seconds / 86400).rounded())
        if days < 7 { return plural(days, "day") }
        if days < 30 { return plural(days / 7, "week") }
        let months = Int((Double(days) / 30.44).rounded())
        if months < 12 { return plural(max(1, months), "month") }
        return plural(max(1, Int(Double(days) / 365.25)), "year")
    }
}
