import Foundation
import Testing
@testable import PullMark

@Suite struct PendingReviewTests {
    // MARK: - Decoding

    @Test func reviewListDecodesSnakeCaseFields() throws {
        let payload = """
        [
          {"id": 101, "node_id": "PRR_abc", "user": {"login": "octocat"},
           "body": "", "state": "PENDING", "commit_id": "deadbeef"},
          {"id": 88, "node_id": "PRR_old", "user": {"login": "reviewer"},
           "body": "LGTM", "state": "APPROVED", "commit_id": "cafe",
           "submitted_at": "2026-07-01T10:00:00Z"}
        ]
        """.data(using: .utf8)!
        let reviews = try GitHubClient.decodeReviews(payload)
        #expect(reviews.count == 2)
        #expect(reviews[0].id == 101)
        #expect(reviews[0].nodeId == "PRR_abc")
        #expect(reviews[0].user?.login == "octocat")
        #expect(reviews[0].state == "PENDING")
        #expect(reviews[0].commitId == "deadbeef")
        #expect(reviews[1].state == "APPROVED")
    }

    @Test func reviewDecodingSurvivesMissingOptionalFields() throws {
        // Ghost users (deleted accounts) come back as null.
        let payload = """
        [{"id": 5, "node_id": "PRR_g", "user": null, "body": null, "state": "PENDING"}]
        """.data(using: .utf8)!
        let reviews = try GitHubClient.decodeReviews(payload)
        #expect(reviews[0].user == nil)
        #expect(reviews[0].commitId == nil)
    }

    // MARK: - Server-comment mapping

    private func serverComment(id: Int, line: Int?, startLine: Int? = nil,
                               originalLine: Int? = nil, side: String? = "RIGHT",
                               body: String = "x") -> ReviewComment {
        ReviewComment(id: id, path: "docs/a.md", body: body, line: line, side: side,
                      startLine: startLine, originalLine: originalLine, subjectType: nil,
                      inReplyToId: nil, user: nil, createdAt: nil, htmlUrl: nil)
    }

    @Test func serverCommentMapsSingleLine() throws {
        let mapped = try #require(PendingComment(server: serverComment(id: 7, line: 12)))
        #expect(mapped.serverID == 7)
        #expect(mapped.lineStart == 12)
        #expect(mapped.lineEnd == 12)
        #expect(mapped.side == "RIGHT")
        #expect(mapped.id == "7", "server identity must be stable across refetches")
    }

    @Test func serverCommentMapsMultiLineRange() throws {
        let mapped = try #require(PendingComment(server: serverComment(id: 8, line: 9, startLine: 3)))
        #expect(mapped.lineStart == 3)
        #expect(mapped.lineEnd == 9)
    }

    @Test func serverCommentFallsBackToOriginalLine() throws {
        // The head moved under the pending review: line is nil, the
        // original anchor still names the comment in the list.
        let mapped = try #require(PendingComment(server: serverComment(id: 9, line: nil, originalLine: 4)))
        #expect(mapped.lineEnd == 4)
    }

    @Test func serverCommentWithoutAnyAnchorIsRejected() {
        #expect(PendingComment(server: serverComment(id: 10, line: nil)) == nil)
    }

    // MARK: - Pending-review selection

    private func review(id: Int, state: String, login: String?) -> PullRequestReview {
        PullRequestReview(id: id, nodeId: "PRR_\(id)",
                          user: login.map(PullRequestReview.User.init(login:)),
                          body: nil, state: state, commitId: nil)
    }

    @Test func pendingReviewPicksViewerAuthoredPendingOnly() {
        let reviews = [review(id: 1, state: "APPROVED", login: "me"),
                       review(id: 2, state: "PENDING", login: "someone-else"),
                       review(id: 3, state: "PENDING", login: "me")]
        #expect(PendingReviewSync.pendingReview(in: reviews, viewer: "me")?.id == 3)
    }

    @Test func pendingReviewNilWithoutViewerOrMatch() {
        let reviews = [review(id: 1, state: "PENDING", login: "me")]
        #expect(PendingReviewSync.pendingReview(in: reviews, viewer: nil) == nil)
        #expect(PendingReviewSync.pendingReview(in: [], viewer: "me") == nil)
        #expect(PendingReviewSync.pendingReview(
            in: [review(id: 2, state: "COMMENTED", login: "me")], viewer: "me") == nil)
    }

    // MARK: - Queue reconciliation

    private func local(_ body: String, line: Int = 5) -> PendingComment {
        PendingComment(path: "docs/a.md", lineStart: line, lineEnd: line, side: "RIGHT", body: body)
    }

    private func server(_ body: String, id: Int, line: Int = 5) -> PendingComment {
        PendingComment(serverID: id, path: "docs/a.md", lineStart: line, lineEnd: line,
                       side: "RIGHT", body: body)
    }

    @Test func acceptedQueuedCommentsAreDroppedFromTheQueue() {
        let queue = [local("uploaded"), local("still waiting")]
        let remaining = PendingReviewSync.remainingQueue(
            local: queue, server: [server("uploaded", id: 1)])
        #expect(remaining.map(\.body) == ["still waiting"])
    }

    @Test func failedUploadsAreRetainedVerbatim() {
        let queue = [local("a"), local("b")]
        let remaining = PendingReviewSync.remainingQueue(local: queue, server: [])
        #expect(remaining == queue, "a failed sync must never lose authored comments")
    }

    @Test func matchRequiresAnchorAndBody() {
        let queue = [local("same words", line: 5)]
        let differentAnchor = [server("same words", id: 1, line: 9)]
        #expect(PendingReviewSync.remainingQueue(local: queue, server: differentAnchor) == queue)
    }

    @Test func eachServerCommentClaimsOneQueuedTwin() {
        // The user deliberately queued the same comment twice; the server
        // holds one copy — exactly one queued twin survives for upload.
        let queue = [local("dup"), local("dup")]
        let remaining = PendingReviewSync.remainingQueue(local: queue, server: [server("dup", id: 1)])
        #expect(remaining.count == 1)
    }

    // MARK: - Disk store (pure encode/decode/update)

    private let ref = PullRequestRef(owner: "acme", repo: "docs", number: 12)

    @Test func storeKeysCarryRepoPRAndCommit() {
        #expect(PendingReviewStore.queueKey(ref: ref, headSHA: "abc") == "acme/docs#12@abc")
        #expect(PendingReviewStore.summaryKey(ref: ref) == "acme/docs#12")
    }

    @Test func queueRoundTripsThroughEncoding() throws {
        let key = PendingReviewStore.queueKey(ref: ref, headSHA: "abc")
        let comments = [local("persist me"),
                        PendingComment(path: "b.md", lineStart: 1, lineEnd: 3, side: "LEFT", body: "old side")]
        let stored = PendingReviewStore.updatedQueues([:], key: key, comments: comments)
        let data = try #require(PendingReviewStore.encodeQueues(stored))
        let decoded = PendingReviewStore.decodeQueues(data)
        #expect(decoded[key]?.comments == comments)
    }

    @Test func emptyQueueRemovesItsKey() {
        let key = PendingReviewStore.queueKey(ref: ref, headSHA: "abc")
        let stored = PendingReviewStore.updatedQueues([:], key: key, comments: [local("x")])
        let cleared = PendingReviewStore.updatedQueues(stored, key: key, comments: [])
        #expect(cleared[key] == nil)
    }

    @Test func storeCapsAtMaxQueuesDroppingOldest() {
        var queues: [String: PendingReviewStore.StoredQueue] = [:]
        let base = Date(timeIntervalSince1970: 1_000_000)
        for i in 0...PendingReviewStore.maxQueues {
            queues = PendingReviewStore.updatedQueues(
                queues, key: "k\(i)", comments: [local("c\(i)")],
                now: base.addingTimeInterval(Double(i)))
        }
        #expect(queues.count == PendingReviewStore.maxQueues)
        #expect(queues["k0"] == nil, "the oldest entry is pruned first")
        #expect(queues["k\(PendingReviewStore.maxQueues)"] != nil)
    }

    @Test func decodeToleratesGarbageAndNil() {
        #expect(PendingReviewStore.decodeQueues(nil).isEmpty)
        #expect(PendingReviewStore.decodeQueues(Data("not json".utf8)).isEmpty)
    }
}
