import Foundation

/// The viewer's pending (unsubmitted) review as adopted from GitHub — the
/// source of truth for review state (spec §4). `comments` are the
/// server-accepted pending comments; anything GitHub hasn't accepted yet
/// stays in the session's local queue until a sync lands it here.
struct PendingReviewState: Equatable {
    let reviewID: Int
    /// GraphQL node id — the handle incremental adds need.
    let nodeID: String
    /// The commit the review was created against (may predate the loaded
    /// head when the review was started on github.com).
    let commitID: String?
    /// Summary text already saved on the review server-side.
    let summary: String?
    var comments: [PendingComment]
}

/// Pure reconciliation between the server's pending review and the local
/// queue of not-yet-accepted comments.
enum PendingReviewSync {
    /// The viewer's pending review among a PR's reviews, if any. GitHub
    /// enforces at most one pending review per user per PR; other users'
    /// pending reviews are filtered defensively (the API shouldn't return
    /// them, but adopting someone else's review would corrupt the session).
    static func pendingReview(in reviews: [PullRequestReview],
                              viewer: String?) -> PullRequestReview? {
        guard let viewer else { return nil }
        return reviews.first { $0.state == "PENDING" && $0.user?.login == viewer }
    }

    /// The local queue after a server fetch: queued comments the server now
    /// holds (matched by anchor + body — the server never echoes local ids)
    /// are dropped in favor of the authoritative server copy; everything
    /// unmatched is retained so a failed or interrupted upload never loses
    /// work. Each server comment claims at most one queued twin, so a
    /// deliberately repeated comment survives until it uploads too.
    static func remainingQueue(local: [PendingComment],
                               server: [PendingComment]) -> [PendingComment] {
        var unclaimed = server
        return local.filter { queued in
            if let match = unclaimed.firstIndex(where: {
                $0.path == queued.path && $0.lineStart == queued.lineStart
                    && $0.lineEnd == queued.lineEnd && $0.side == queued.side
                    && $0.body == queued.body
            }) {
                unclaimed.remove(at: match)
                return false
            }
            return true
        }
    }
}

/// Disk persistence for review work GitHub hasn't accepted yet: queued
/// pending comments keyed by repo/PR/commit (line anchors are only valid
/// against the head they were authored on) and in-progress summary text
/// keyed by repo/PR (prose survives head moves). Lives in the app's
/// existing UserDefaults domain — see DefaultsKeys.
enum PendingReviewStore {
    struct StoredQueue: Codable, Equatable {
        var comments: [PendingComment]
        var savedAt: Date
    }

    static let maxQueues = 20

    static func queueKey(ref: PullRequestRef, headSHA: String) -> String {
        "\(ref.owner)/\(ref.repo)#\(ref.number)@\(headSHA)"
    }

    static func summaryKey(ref: PullRequestRef) -> String {
        "\(ref.owner)/\(ref.repo)#\(ref.number)"
    }

    // Pure encode/decode/update over the stored set (unit-tested); the
    // UserDefaults accessors below stay thin shims over them.

    static func decodeQueues(_ data: Data?) -> [String: StoredQueue] {
        guard let data,
              let decoded = try? JSONDecoder().decode([String: StoredQueue].self, from: data)
        else { return [:] }
        return decoded
    }

    static func encodeQueues(_ queues: [String: StoredQueue]) -> Data? {
        try? JSONEncoder().encode(queues)
    }

    /// One queue update applied to the stored set: empty queues drop their
    /// key, and the set is capped oldest-first so stale heads (a PR whose
    /// head moved with comments still queued) can't grow unbounded.
    static func updatedQueues(_ queues: [String: StoredQueue], key: String,
                              comments: [PendingComment],
                              now: Date = Date()) -> [String: StoredQueue] {
        var result = queues
        if comments.isEmpty {
            result[key] = nil
        } else {
            result[key] = StoredQueue(comments: comments, savedAt: now)
        }
        while result.count > maxQueues {
            guard let oldest = result.min(by: { $0.value.savedAt < $1.value.savedAt })
            else { break }
            result[oldest.key] = nil
        }
        return result
    }

    static func loadQueue(ref: PullRequestRef, headSHA: String) -> [PendingComment] {
        let queues = decodeQueues(UserDefaults.standard.data(forKey: DefaultsKeys.pendingCommentQueues))
        return queues[queueKey(ref: ref, headSHA: headSHA)]?.comments ?? []
    }

    static func saveQueue(_ comments: [PendingComment], ref: PullRequestRef, headSHA: String) {
        let current = decodeQueues(UserDefaults.standard.data(forKey: DefaultsKeys.pendingCommentQueues))
        let updated = updatedQueues(current, key: queueKey(ref: ref, headSHA: headSHA),
                                    comments: comments)
        UserDefaults.standard.set(encodeQueues(updated), forKey: DefaultsKeys.pendingCommentQueues)
    }

    static func loadSummary(ref: PullRequestRef) -> String? {
        let all = UserDefaults.standard.dictionary(forKey: DefaultsKeys.pendingReviewSummaries)
            as? [String: String]
        return all?[summaryKey(ref: ref)]
    }

    /// Nil or empty text removes the entry.
    static func saveSummary(_ text: String?, ref: PullRequestRef) {
        var all = UserDefaults.standard.dictionary(forKey: DefaultsKeys.pendingReviewSummaries)
            as? [String: String] ?? [:]
        all[summaryKey(ref: ref)] = (text?.isEmpty == false) ? text : nil
        UserDefaults.standard.set(all, forKey: DefaultsKeys.pendingReviewSummaries)
    }
}
