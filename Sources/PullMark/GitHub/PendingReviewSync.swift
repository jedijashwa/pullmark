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

    /// A fresh server fetch reconciled against what the session already
    /// held, publishing both halves of the truth at once:
    /// - Server comments inherit the `localID` of the copy the session
    ///   already knew (matched by server id) or of the queued twin they
    ///   claim (matched by anchor + body — the server never echoes local
    ///   ids), so SwiftUI row identity survives both upload and refetch.
    /// - Queued comments the server now holds are dropped in favor of the
    ///   authoritative server copy; everything unmatched is retained so a
    ///   failed or interrupted upload never loses work. Each server
    ///   comment claims at most one queued twin, so a deliberately
    ///   repeated comment survives until it uploads too.
    static func reconcile(server: [PendingComment],
                          previousServer: [PendingComment],
                          queue: [PendingComment])
        -> (server: [PendingComment], queue: [PendingComment]) {
        var remaining = queue
        let stabilized = server.map { fresh -> PendingComment in
            var fresh = fresh
            var identified = false
            if fresh.serverID != nil,
               let known = previousServer.first(where: { $0.serverID == fresh.serverID }) {
                fresh.localID = known.localID
                identified = true
            }
            if let match = remaining.firstIndex(where: {
                $0.path == fresh.path && $0.lineStart == fresh.lineStart
                    && $0.lineEnd == fresh.lineEnd && $0.side == fresh.side
                    && $0.body == fresh.body
            }) {
                if !identified { fresh.localID = remaining[match].localID }
                remaining.remove(at: match)
            }
            return fresh
        }
        return (stabilized, remaining)
    }

    /// The local queue after a server fetch — `reconcile` without identity
    /// carry-over context.
    static func remainingQueue(local: [PendingComment],
                               server: [PendingComment]) -> [PendingComment] {
        reconcile(server: server, previousServer: [], queue: local).queue
    }
}

/// Single-flight coordination for the per-PR upload loop, closing two
/// gaps in a bare "already syncing" guard:
/// - a change noted during an in-flight run's final pass triggers one
///   more pass instead of sitting un-uploaded until a manual retry, and
/// - callers that need the queue drained (submit) wait for the in-flight
///   run to finish instead of silently skipping and misreading
///   mid-upload comments as failures.
@MainActor
final class PendingSyncGate {
    private var inFlight: Set<String> = []
    private var generations: [String: Int] = [:]
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    /// Records a change (e.g. a newly queued comment). Call synchronously
    /// with the change itself, before kicking off a run.
    func noteChange(_ key: String) {
        generations[key, default: 0] += 1
    }

    /// Runs `pass` repeatedly until no change was noted during the last
    /// pass. When a run is already in flight for this key, waits for it
    /// to finish and returns — every change noted before this call is
    /// covered either by that run's re-pass or by a later run (there is
    /// no suspension between its last generation check and its exit).
    func run(_ key: String, pass: @MainActor () async -> Void) async {
        if inFlight.contains(key) {
            await waitUntilIdle(key)
            return
        }
        inFlight.insert(key)
        defer {
            inFlight.remove(key)
            for waiter in waiters.removeValue(forKey: key) ?? [] { waiter.resume() }
        }
        var seen = -1
        while seen != generations[key, default: 0] {
            seen = generations[key, default: 0]
            await pass()
        }
    }

    /// Suspends until no run is in flight for the key.
    func waitUntilIdle(_ key: String) async {
        while inFlight.contains(key) {
            await withCheckedContinuation { waiters[key, default: []].append($0) }
        }
    }

    /// Drops bookkeeping for a key (session closed).
    func forget(_ key: String) {
        generations[key] = nil
    }

    // Test hooks — deterministic sequencing needs observable state.
    func isRunning(_ key: String) -> Bool { inFlight.contains(key) }
    func waiterCount(_ key: String) -> Int { waiters[key]?.count ?? 0 }
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
        let queues = decodeQueues(UserDefaults.pullmark.data(forKey: DefaultsKeys.pendingCommentQueues))
        return queues[queueKey(ref: ref, headSHA: headSHA)]?.comments ?? []
    }

    static func saveQueue(_ comments: [PendingComment], ref: PullRequestRef, headSHA: String) {
        let current = decodeQueues(UserDefaults.pullmark.data(forKey: DefaultsKeys.pendingCommentQueues))
        let updated = updatedQueues(current, key: queueKey(ref: ref, headSHA: headSHA),
                                    comments: comments)
        UserDefaults.pullmark.set(encodeQueues(updated), forKey: DefaultsKeys.pendingCommentQueues)
    }

    static func loadSummary(ref: PullRequestRef) -> String? {
        let all = UserDefaults.pullmark.dictionary(forKey: DefaultsKeys.pendingReviewSummaries)
            as? [String: String]
        return all?[summaryKey(ref: ref)]
    }

    /// Nil or empty text removes the entry.
    static func saveSummary(_ text: String?, ref: PullRequestRef) {
        var all = UserDefaults.pullmark.dictionary(forKey: DefaultsKeys.pendingReviewSummaries)
            as? [String: String] ?? [:]
        all[summaryKey(ref: ref)] = (text?.isEmpty == false) ? text : nil
        UserDefaults.pullmark.set(all, forKey: DefaultsKeys.pendingReviewSummaries)
    }
}
