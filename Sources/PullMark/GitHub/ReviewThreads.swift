import Foundation

/// A root review comment plus its replies.
struct ReviewThread: Equatable {
    let root: ReviewComment
    var replies: [ReviewComment]

    var comments: [ReviewComment] { [root] + replies }
    var path: String { root.path }
    var anchorLine: Int? { root.line }
    var anchorSide: String { root.side ?? "RIGHT" }
    var isOutdated: Bool { root.line == nil }

    var lineLabel: String {
        if let line = root.line {
            let which = anchorSide == "LEFT" ? "old" : "new"
            return "Line \(line) (\(which))"
        }
        if let original = root.originalLine {
            return "Outdated — was line \(original)"
        }
        return "Outdated"
    }
}

enum ReviewThreads {
    /// Groups a flat comment list into threads. Replies carry the id of the
    /// thread's root comment in `in_reply_to_id`; a reply whose root is
    /// missing is promoted to a root so nothing is dropped.
    static func group(_ comments: [ReviewComment]) -> [ReviewThread] {
        let sorted = comments.sorted { $0.id < $1.id }
        var threads: [ReviewThread] = []
        var indexByRootID: [Int: Int] = [:]
        for comment in sorted {
            if let parentID = comment.inReplyToId, let index = indexByRootID[parentID] {
                threads[index].replies.append(comment)
            } else {
                indexByRootID[comment.id] = threads.count
                threads.append(ReviewThread(root: comment, replies: []))
            }
        }
        return threads
    }

    /// Attaches threads to the diff segment whose line range contains the
    /// thread's anchor (matching diff side), falling back to the nearest
    /// segment. Threads with no current position are returned separately.
    static func place(_ threads: [ReviewThread], in segments: [DiffSegmentPayload])
        -> (segments: [DiffSegmentPayload], outdated: [ReviewThread]) {
        var annotated = segments
        var outdated: [ReviewThread] = []
        for thread in threads {
            guard let line = thread.anchorLine, !annotated.isEmpty else {
                outdated.append(thread)
                continue
            }
            let side = thread.anchorSide
            let index = annotated.firstIndex {
                $0.side == side && $0.lineStart <= line && line <= $0.lineEnd
            } ?? nearestIndex(in: annotated, line: line, side: side)
            let payload = ThreadPayload(
                lineLabel: thread.lineLabel,
                comments: thread.comments.map(CommentPayload.init)
            )
            if annotated[index].threads == nil { annotated[index].threads = [] }
            annotated[index].threads?.append(payload)
        }
        return (annotated, outdated)
    }

    private static func nearestIndex(in segments: [DiffSegmentPayload], line: Int, side: String) -> Int {
        func distance(_ segment: DiffSegmentPayload) -> Int {
            if segment.lineStart <= line && line <= segment.lineEnd { return 0 }
            return min(abs(segment.lineStart - line), abs(segment.lineEnd - line))
        }
        let sameSide = segments.indices.filter { segments[$0].side == side }
        let candidates = sameSide.isEmpty ? Array(segments.indices) : sameSide
        return candidates.min { distance(segments[$0]) < distance(segments[$1]) } ?? 0
    }
}

struct ThreadPayload: Encodable, Equatable {
    let lineLabel: String
    let comments: [CommentPayload]
}

struct CommentPayload: Encodable, Equatable {
    let author: String
    let dateLabel: String
    let body: String

    init(author: String, dateLabel: String, body: String) {
        self.author = author
        self.dateLabel = dateLabel
        self.body = body
    }

    init(_ comment: ReviewComment) {
        self.init(author: comment.author, dateLabel: comment.dateLabel, body: comment.body)
    }
}
