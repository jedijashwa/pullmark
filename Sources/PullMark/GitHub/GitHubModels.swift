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

/// The REST reactions rollup carried by every review comment: one count per
/// canonical reaction. "+1"/"-1" are GitHub's literal JSON keys (they carry
/// no underscore, so the snake-case strategy leaves them alone); missing
/// keys decode as zero rather than failing the whole comments page.
struct ReactionRollup: Decodable, Equatable {
    var plusOne = 0
    var minusOne = 0
    var laugh = 0
    var hooray = 0
    var confused = 0
    var heart = 0
    var rocket = 0
    var eyes = 0

    init(plusOne: Int = 0, minusOne: Int = 0, laugh: Int = 0, hooray: Int = 0,
         confused: Int = 0, heart: Int = 0, rocket: Int = 0, eyes: Int = 0) {
        self.plusOne = plusOne
        self.minusOne = minusOne
        self.laugh = laugh
        self.hooray = hooray
        self.confused = confused
        self.heart = heart
        self.rocket = rocket
        self.eyes = eyes
    }

    private enum CodingKeys: String, CodingKey {
        case plusOne = "+1"
        case minusOne = "-1"
        case laugh, hooray, confused, heart, rocket, eyes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        plusOne = try container.decodeIfPresent(Int.self, forKey: .plusOne) ?? 0
        minusOne = try container.decodeIfPresent(Int.self, forKey: .minusOne) ?? 0
        laugh = try container.decodeIfPresent(Int.self, forKey: .laugh) ?? 0
        hooray = try container.decodeIfPresent(Int.self, forKey: .hooray) ?? 0
        confused = try container.decodeIfPresent(Int.self, forKey: .confused) ?? 0
        heart = try container.decodeIfPresent(Int.self, forKey: .heart) ?? 0
        rocket = try container.decodeIfPresent(Int.self, forKey: .rocket) ?? 0
        eyes = try container.decodeIfPresent(Int.self, forKey: .eyes) ?? 0
    }

    mutating func setCount(_ count: Int, for kind: ReactionKind) {
        switch kind {
        case .thumbsUp: plusOne = count
        case .thumbsDown: minusOne = count
        case .laugh: laugh = count
        case .hooray: hooray = count
        case .confused: confused = count
        case .heart: heart = count
        case .rocket: rocket = count
        case .eyes: eyes = count
        }
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
    /// Mutable so a confirmed edit folds into the loaded model without
    /// a refetch (same pattern as reactions).
    var body: String
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
    /// The original-diff hunk from its header down to exactly the
    /// commented line (REST shape) — the discussion list's excerpt
    /// source. Reflects the diff as of when the comment was made.
    var diffHunk: String? = nil
    /// Reaction counts (REST rollup). Mutable so a confirmed reaction
    /// toggle folds into the loaded model without a refetch.
    var reactions: ReactionRollup? = nil

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
