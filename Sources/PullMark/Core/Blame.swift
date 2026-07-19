import Foundation

/// One commit as seen by blame — shared between local `git blame --porcelain`
/// output and GitHub's GraphQL blame (which adds avatars and commit URLs).
struct BlameCommit: Equatable {
    let sha: String
    let authorName: String
    var authorEmail: String? = nil
    let date: Date?
    let summary: String
    /// The author's GitHub account avatar (GraphQL `author.user.avatarUrl`) —
    /// the strongest avatar signal.
    var userAvatarUrl: String? = nil
    /// GitHub's commit-email-derived avatar (GraphQL `author.avatarUrl`),
    /// present even when the email can't be matched to an account.
    var actorAvatarUrl: String? = nil
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

/// The authenticated GitHub user, fetched once per session. Used to resolve
/// avatars for commits authored under private/noreply emails that GitHub's
/// blame can't match to an account.
struct ViewerIdentity: Equatable {
    let login: String
    var name: String? = nil
    var email: String? = nil
    var avatarUrl: String? = nil
}

/// One gutter entry handed to app.js: a coalesced run of consecutive blocks
/// whose most recent commit is the same. Line numbers are 1-based source
/// lines spanning the run's first block start to last block end.
struct BlameRunPayload: Encodable, Equatable {
    let lineStart: Int
    let lineEnd: Int
    let sha: String
    let shortSHA: String
    let author: String
    var avatarUrl: String? = nil
    var dateLabel: String? = nil
    var headline: String? = nil
    var url: String? = nil
    var uncommitted: Bool? = nil
}

/// One row of the line/file History panel.
struct HistoryEntry: Identifiable, Equatable {
    let sha: String
    let shortSHA: String
    let author: String
    let dateLabel: String?
    let headline: String
    let avatarUrl: String?
    let url: String?
    var id: String { sha }
}

/// Everything the History panel needs, assembled off the UI.
struct HistoryPanelData: Equatable {
    let title: String
    let subtitle: String?
    /// Honest labeling when line-level history wasn't available.
    let note: String?
    let entries: [HistoryEntry]
    /// PR panels: index of the first entry that is already on the base
    /// branch (a labeled divider renders before it). Nil when the split is
    /// unknown or everything falls on one side.
    var baseStart: Int? = nil
}

/// Pure mapping from per-line blame ranges to coalesced gutter runs.
enum BlameMapper {
    /// The most recent commit touching a block's line range; nil when no
    /// range covers the block.
    static func primaryCommit(for block: MarkdownBlock, in ranges: [BlameRange]) -> BlameCommit? {
        let overlapping = ranges.filter {
            $0.start <= block.endLine && $0.end >= block.startLine
        }
        return overlapping.map(\.commit).min {
            let l = $0.date ?? .distantPast, r = $1.date ?? .distantPast
            return l != r ? l > r : $0.sha < $1.sha
        }
    }

    /// Coalesces consecutive blocks blamed to the same most-recent commit
    /// into one gutter run. Blocks no range covers produce no run and break
    /// coalescing.
    static func runs(blocks: [MarkdownBlock], ranges: [BlameRange],
                     viewer: ViewerIdentity? = nil, now: Date = Date()) -> [BlameRunPayload] {
        var out: [BlameRunPayload] = []
        var current: (commit: BlameCommit, start: Int, end: Int)?

        func flush() {
            guard let run = current else { return }
            current = nil
            let commit = run.commit
            out.append(BlameRunPayload(
                lineStart: run.start,
                lineEnd: run.end,
                sha: commit.sha,
                shortSHA: String(commit.sha.prefix(7)),
                author: commit.authorName,
                avatarUrl: avatarURL(for: commit, viewer: viewer),
                dateLabel: commit.date.map { relativeLabel(from: $0, to: now) },
                headline: commit.summary.isEmpty ? nil : commit.summary,
                url: commit.url,
                uncommitted: commit.isUncommitted ? true : nil
            ))
        }

        for block in blocks {
            guard let commit = primaryCommit(for: block, in: ranges) else {
                flush()
                continue
            }
            if let run = current, run.commit.sha == commit.sha {
                current = (run.commit, run.start, block.endLine)
            } else {
                flush()
                current = (commit, block.startLine, block.endLine)
            }
        }
        flush()
        return out
    }

    /// Layered avatar resolution:
    /// 1. the commit author's GitHub account avatar (GraphQL `author.user`),
    /// 2. the signed-in viewer's avatar when the commit author matches them
    ///    (catches commits authored under private/noreply emails),
    /// 3. GitHub's commit-email-derived avatar (GraphQL `author.avatarUrl`),
    /// 4. nil — the page falls back to an initials circle.
    static func avatarURL(for commit: BlameCommit, viewer: ViewerIdentity?) -> String? {
        if commit.isUncommitted {
            return viewer?.avatarUrl
        }
        if let url = commit.userAvatarUrl { return url }
        if let viewer, let url = viewer.avatarUrl, matchesViewer(commit, viewer) {
            return url
        }
        return commit.actorAvatarUrl
    }

    /// True when the commit's author name or email identifies the viewer.
    static func matchesViewer(_ commit: BlameCommit, _ viewer: ViewerIdentity) -> Bool {
        let name = commit.authorName.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty {
            if let viewerName = viewer.name,
               name.compare(viewerName, options: .caseInsensitive) == .orderedSame {
                return true
            }
            if name.compare(viewer.login, options: .caseInsensitive) == .orderedSame {
                return true
            }
        }
        guard let email = commit.authorEmail?.lowercased(), !email.isEmpty else { return false }
        if let viewerEmail = viewer.email?.lowercased(), !viewerEmail.isEmpty,
           email == viewerEmail {
            return true
        }
        // GitHub noreply addresses: "login@users.noreply.github.com" or
        // "12345+login@users.noreply.github.com".
        let noreply = "\(viewer.login.lowercased())@users.noreply.github.com"
        return email == noreply || email.hasSuffix("+\(noreply)")
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

/// Pure mapping from history commits (git log or GraphQL history) to the
/// rows the History panel shows, applying the same avatar tiering as blame.
enum HistoryBuilder {
    static func entries(from commits: [BlameCommit], viewer: ViewerIdentity? = nil,
                        now: Date = Date()) -> [HistoryEntry] {
        commits.map { commit in
            HistoryEntry(
                sha: commit.sha,
                shortSHA: String(commit.sha.prefix(7)),
                author: commit.authorName,
                dateLabel: commit.date.map { BlameMapper.relativeLabel(from: $0, to: now) },
                headline: commit.summary,
                avatarUrl: BlameMapper.avatarURL(for: commit, viewer: viewer),
                url: commit.url
            )
        }
    }

    /// Splits PR file history into PR-branch commits first (they're the
    /// newest), then commits already on the base branch, keeping each side's
    /// original order. `baseStart` is the divider position — nil when either
    /// side is empty (no divider to draw).
    static func partition(entries: [HistoryEntry],
                          prSHAs: Set<String>) -> (entries: [HistoryEntry], baseStart: Int?) {
        let pr = entries.filter { prSHAs.contains($0.sha) }
        let base = entries.filter { !prSHAs.contains($0.sha) }
        guard !pr.isEmpty, !base.isEmpty else { return (entries, nil) }
        return (pr + base, pr.count)
    }
}
