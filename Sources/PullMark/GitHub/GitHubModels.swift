import Foundation

struct PullRequestDetails: Decodable {
    struct CommitRef: Decodable {
        let sha: String
        let ref: String
    }
    struct User: Decodable {
        let login: String
    }
    let number: Int
    let title: String
    let body: String?
    let state: String
    let draft: Bool?
    let merged: Bool?
    let head: CommitRef
    let base: CommitRef
    let htmlUrl: URL
    let user: User?
}

struct PullRequestFile: Decodable, Identifiable, Equatable {
    let filename: String
    let status: String
    let additions: Int
    let deletions: Int
    let patch: String?
    let previousFilename: String?

    var id: String { filename }

    var isMarkdown: Bool {
        MarkdownFileType.matches((filename as NSString).pathExtension)
    }
}

/// An existing review comment fetched from GitHub. Comments whose `line` is
/// nil are "outdated": they anchor to a previous version of the diff.
struct ReviewComment: Decodable, Identifiable, Equatable {
    struct User: Decodable, Equatable {
        let login: String
    }
    let id: Int
    let path: String
    let body: String
    let line: Int?
    let side: String?
    let startLine: Int?
    let originalLine: Int?
    /// "file" for whole-file comments (no line anchor by design — they are
    /// not outdated, they were never anchored).
    let subjectType: String?
    let inReplyToId: Int?
    let user: User?
    let createdAt: String?
    let htmlUrl: URL?

    var author: String { user?.login ?? "unknown" }

    private static let isoParser = ISO8601DateFormatter()
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    /// "Jul 18, 2026" from the ISO-8601 `created_at`, or empty.
    var dateLabel: String {
        guard let createdAt, let date = Self.isoParser.date(from: createdAt) else { return "" }
        return Self.dateFormatter.string(from: date)
    }
}

/// A review comment the user has written but not yet sent to GitHub.
struct DraftComment: Identifiable, Equatable {
    let id: UUID
    var path: String
    var lineStart: Int
    var lineEnd: Int
    var side: String
    var body: String

    init(id: UUID = UUID(), path: String, lineStart: Int, lineEnd: Int, side: String, body: String) {
        self.id = id
        self.path = path
        self.lineStart = lineStart
        self.lineEnd = lineEnd
        self.side = side
        self.body = body
    }

    var lineDescription: String {
        let which = side == "LEFT" ? "old" : "new"
        return lineStart == lineEnd
            ? "line \(lineEnd) (\(which))"
            : "lines \(lineStart)–\(lineEnd) (\(which))"
    }
}
