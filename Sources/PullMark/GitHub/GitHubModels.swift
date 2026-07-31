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

/// A review comment authored in PullMark: an anchor (path, line range, side)
/// plus a body. Once GitHub accepts it into the viewer's pending review it
/// carries the server comment id; until then it lives in the local queue
/// (persisted to disk — see PendingReviewStore). Also the payload shape for
/// immediate single comments.
struct PendingComment: Identifiable, Equatable, Codable {
    /// Set once GitHub accepted the comment into the pending review.
    var serverID: Int?
    /// Identity before the server assigns one (and across disk round trips).
    var localID: UUID
    var path: String
    var lineStart: Int
    var lineEnd: Int
    var side: String
    var body: String

    /// Always the local UUID, so a row's identity survives the moment the
    /// server accepts it (serverID lands in its own field, the id never
    /// flips) — SwiftUI must not rebuild rows once per uploaded comment.
    /// Adoption keeps localIDs stable across refetches by matching fresh
    /// server copies to known ones (see PendingReviewSync.reconcile).
    var id: String { localID.uuidString }

    init(serverID: Int? = nil, localID: UUID = UUID(),
         path: String, lineStart: Int, lineEnd: Int, side: String, body: String) {
        self.serverID = serverID
        self.localID = localID
        self.path = path
        self.lineStart = lineStart
        self.lineEnd = lineEnd
        self.side = side
        self.body = body
    }

    // NOTE: pending comments are never built from the REST review-comments
    // endpoint — GET …/reviews/{id}/comments returns only legacy
    // diff-position fields (position/original_position/diff_hunk), no
    // line/side, so nothing decoded from it can anchor a PendingComment.
    // They come from GraphQL review threads instead — see
    // GitHubClient.pendingReviewComments and the REST-shape regression
    // fixture in PendingReviewTests.

    var lineDescription: String {
        let which = side == "LEFT" ? "old" : "new"
        return lineStart == lineEnd
            ? "line \(lineEnd) (\(which))"
            : "lines \(lineStart)–\(lineEnd) (\(which))"
    }
}

/// A review row from GET /pulls/{n}/reviews. `state` "PENDING" marks an
/// unsubmitted review — the list includes the viewer's own; other users'
/// pending reviews are never visible. `nodeId` feeds the GraphQL
/// incremental-add mutation (see GitHubClient's API-mix note).
struct PullRequestReview: Decodable, Equatable {
    struct User: Decodable, Equatable {
        let login: String
    }
    let id: Int
    let nodeId: String
    let user: User?
    let body: String?
    let state: String
    let commitId: String?
}
