import Foundation

/// A root review comment plus its replies.
struct ReviewThread: Equatable {
    let root: ReviewComment
    var replies: [ReviewComment]

    var comments: [ReviewComment] { [root] + replies }
    var path: String { root.path }
    var anchorLine: Int? { root.line }
    var anchorSide: String { root.side ?? "RIGHT" }
    /// Whole-file comments have no line by design — never anchored, never
    /// outdated.
    var isFileLevel: Bool { root.subjectType == "file" }
    var isOutdated: Bool { root.line == nil && !isFileLevel }

    var lineLabel: String {
        if isFileLevel { return "Whole file" }
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
    /// thread's root comment in `in_reply_to_id`; when that root was deleted
    /// the earliest surviving comment roots the thread, and the missing id
    /// is mapped to it so the remaining replies stay together instead of
    /// each being promoted into its own orphan thread.
    static func group(_ comments: [ReviewComment]) -> [ReviewThread] {
        let sorted = comments.sorted { $0.id < $1.id }
        var threads: [ReviewThread] = []
        var indexByRootID: [Int: Int] = [:]
        for comment in sorted {
            if let parentID = comment.inReplyToId {
                if let index = indexByRootID[parentID] {
                    threads[index].replies.append(comment)
                    continue
                }
                // Deleted root: this (earliest, ids are ascending) reply
                // becomes the root; later siblings follow it here.
                indexByRootID[parentID] = threads.count
            }
            indexByRootID[comment.id] = threads.count
            threads.append(ReviewThread(root: comment, replies: []))
        }
        return threads
    }

    /// Attaches threads to the diff segment whose line range contains the
    /// thread's anchor (matching diff side), falling back to the nearest
    /// segment. Threads with no current position are returned separately.
    static func place(_ threads: [ReviewThread], in segments: [DiffSegmentPayload],
                      meta: [Int: ThreadMeta] = [:], viewer: String? = nil)
        -> (segments: [DiffSegmentPayload], outdated: [ReviewThread]) {
        var annotated = segments
        var outdated: [ReviewThread] = []
        for thread in threads {
            guard let line = thread.anchorLine, !annotated.isEmpty else {
                outdated.append(thread)
                continue
            }
            let side = thread.anchorSide
            // LEFT anchors are old-file line numbers: match the old-side
            // ranges carried by removed/unchanged/modified segments. A
            // cross-side "nearest" would compare old numbers against new
            // ranges and pin the thread to an arbitrary block.
            let match: Int?
            if side == "LEFT" {
                match = annotated.firstIndex { segment in
                    if segment.side == "LEFT",
                       segment.lineStart <= line, line <= segment.lineEnd {
                        return true
                    }
                    if let start = segment.oldLineStart {
                        return start <= line && line <= (segment.oldLineEnd ?? start)
                    }
                    return false
                }
            } else {
                match = annotated.firstIndex {
                    $0.side == side && $0.lineStart <= line && line <= $0.lineEnd
                } ?? nearestIndex(in: annotated, line: line, side: side)
            }
            guard let index = match else {
                outdated.append(thread)
                continue
            }
            let threadMeta = meta[thread.root.id]
            let payload = ThreadPayload(
                lineLabel: thread.lineLabel,
                comments: thread.comments.map {
                    CommentPayload($0, meta: threadMeta, viewer: viewer)
                },
                rootID: thread.root.id,
                resolved: threadMeta?.isResolved
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

struct ThreadMeta: Equatable {
    let nodeID: String
    var isResolved: Bool
    /// Per-comment GraphQL state, keyed by REST databaseId: node id (the
    /// subject for reaction mutations), the viewer's own reactions, and
    /// whether the comment was edited.
    var comments: [Int: ReviewCommentMeta] = [:]
}

/// GraphQL-only per-comment state folded into the thread-meta query:
/// REST has no viewerHasReacted, and lastEditedAt is the exact "edited"
/// signal (updated_at also moves on non-edits).
struct ReviewCommentMeta: Equatable {
    let nodeID: String
    /// REST content names ("+1", "heart", …) the viewer has pressed.
    var viewerReacted: Set<String> = []
    var edited: Bool = false
}

struct ThreadPayload: Encodable, Equatable {
    let lineLabel: String
    let comments: [CommentPayload]
    /// Root comment id (REST databaseId) — enables reply/resolve actions.
    var rootID: Int? = nil
    var resolved: Bool? = nil
    /// New-side source line range of the anchor — set for Result-view
    /// marker payloads only (ThreadVisibility.resultAnchored); the page
    /// maps it onto rendered blocks via their data-pm-lines annotations.
    var anchorStart: Int? = nil
    var anchorEnd: Int? = nil
}

struct CommentPayload: Encodable, Equatable {
    let author: String
    let dateLabel: String
    let body: String
    /// REST comment id — present on published comments; enables the
    /// reaction and edit/delete bridge round trips.
    var id: Int? = nil
    /// GitHub's "edited" affordance (quiet "· edited" in the byline).
    var edited: Bool = false
    /// The viewer authored this comment — gates the ⋯ (Edit/Delete) menu.
    var viewerOwned: Bool = false
    /// Reaction toggles can work: the viewer is known and the comment's
    /// GraphQL node id is on hand. Chips still render read-only otherwise.
    var canReact: Bool = false
    var reactions: [ReactionChipPayload] = []

    init(author: String, dateLabel: String, body: String) {
        self.author = author
        self.dateLabel = dateLabel
        self.body = body
    }

    init(_ comment: ReviewComment) {
        self.init(author: comment.author, dateLabel: comment.dateLabel, body: comment.body)
    }

    /// A published comment enriched with viewer-relative state: `meta` is
    /// the containing thread's (nil degrades to counts-only chips, no
    /// menu, no toggles — never a crash).
    init(_ comment: ReviewComment, meta: ThreadMeta?, viewer: String?) {
        self.init(comment)
        let commentMeta = meta?.comments[comment.id]
        id = comment.id
        edited = commentMeta?.edited ?? false
        viewerOwned = CommentAuthorship.viewerOwns(author: comment.user?.login, viewer: viewer)
        canReact = viewer != nil && commentMeta != nil
        reactions = CommentReactions.chips(rollup: comment.reactions,
                                           viewerReacted: commentMeta?.viewerReacted ?? [])
    }
}
