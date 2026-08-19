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

    // MARK: - Pending comments come from GraphQL (REST cannot anchor them)

    /// REGRESSION (live-verified): GET …/reviews/{id}/comments returns
    /// ONLY legacy diff-position fields for a pending review's comments —
    /// no line/original_line/side/start_line. Anything decoded from it can
    /// never anchor a PendingComment, so reconciliation never matched and
    /// every sync re-uploaded the whole queue. This fixture mirrors the
    /// real payload shape so the REST path can never silently return.
    private static let realRESTPendingCommentsPayload = """
    [{"id": 111, "pull_request_review_id": 42, "node_id": "PRRC_a",
      "diff_hunk": "@@ -1,3 +1,4 @@\\n context",
      "path": "docs/a.md",
      "position": 4, "original_position": 4,
      "commit_id": "beef", "original_commit_id": "beef",
      "user": {"login": "me"}, "body": "note",
      "created_at": "2026-07-30T10:00:00Z"}]
    """.data(using: .utf8)!

    @Test func restPendingCommentsPayloadCarriesNoLineAnchors() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let comments = try decoder.decode([ReviewComment].self,
                                          from: Self.realRESTPendingCommentsPayload)
        #expect(comments.count == 1)
        #expect(comments[0].line == nil)
        #expect(comments[0].startLine == nil)
        #expect(comments[0].originalLine == nil)
        #expect(comments[0].side == nil)
    }

    @Test func pendingCommentsParserRejectsTheRESTShapeOutright() {
        // The production parser only accepts the GraphQL reviewThreads
        // envelope — feeding it the REST payload must throw, never decode
        // to an empty (or worse, plausible) result.
        #expect(throws: Error.self) {
            try GitHubClient.parsePendingCommentsPage(Self.realRESTPendingCommentsPayload,
                                                      reviewID: 42)
        }
    }

    // MARK: - GraphQL pending-comments decoding

    private func threadsPage(nodes: String, hasNextPage: Bool = false,
                             endCursor: String? = nil) -> Data {
        """
        {"data": {"repository": {"pullRequest": {"reviewThreads": {
          "pageInfo": {"hasNextPage": \(hasNextPage),
                       "endCursor": \(endCursor.map { "\"\($0)\"" } ?? "null")},
          "nodes": [\(nodes)]
        }}}}}
        """.data(using: .utf8)!
    }

    @Test func graphQLSingleLinePendingCommentDecodes() throws {
        let page = threadsPage(nodes: """
        {"diffSide": "RIGHT", "line": 12, "startLine": null,
         "originalLine": 12, "originalStartLine": null, "path": "docs/a.md",
         "comments": {"nodes": [
           {"databaseId": 7, "body": "note", "state": "PENDING",
            "pullRequestReview": {"databaseId": 42}}]}}
        """)
        let parsed = try GitHubClient.parsePendingCommentsPage(page, reviewID: 42)
        #expect(parsed.nextCursor == nil)
        let comment = try #require(parsed.comments.first)
        #expect(comment.serverID == 7)
        #expect(comment.path == "docs/a.md")
        #expect(comment.lineStart == 12)
        #expect(comment.lineEnd == 12)
        #expect(comment.side == "RIGHT")
        #expect(comment.body == "note")
    }

    @Test func graphQLMultiLineLeftSideRangeDecodes() throws {
        let page = threadsPage(nodes: """
        {"diffSide": "LEFT", "line": 9, "startLine": 3,
         "originalLine": 9, "originalStartLine": 3, "path": "docs/b.md",
         "comments": {"nodes": [
           {"databaseId": 8, "body": "old side", "state": "PENDING",
            "pullRequestReview": {"databaseId": 42}}]}}
        """)
        let comment = try #require(
            try GitHubClient.parsePendingCommentsPage(page, reviewID: 42).comments.first)
        #expect(comment.lineStart == 3)
        #expect(comment.lineEnd == 9)
        #expect(comment.side == "LEFT")
    }

    @Test func graphQLOutdatedThreadFallsBackToOriginalLines() throws {
        // The head moved under the pending review: line/startLine are null,
        // the original anchor still names the comment.
        let page = threadsPage(nodes: """
        {"diffSide": "RIGHT", "line": null, "startLine": null,
         "originalLine": 6, "originalStartLine": 4, "path": "docs/a.md",
         "comments": {"nodes": [
           {"databaseId": 9, "body": "moved", "state": "PENDING",
            "pullRequestReview": {"databaseId": 42}}]}}
        """)
        let comment = try #require(
            try GitHubClient.parsePendingCommentsPage(page, reviewID: 42).comments.first)
        #expect(comment.lineStart == 4)
        #expect(comment.lineEnd == 6)
    }

    @Test func graphQLFiltersToPendingCommentsOfTheGivenReview() throws {
        let page = threadsPage(nodes: """
        {"diffSide": "RIGHT", "line": 5, "startLine": null,
         "originalLine": 5, "originalStartLine": null, "path": "docs/a.md",
         "comments": {"nodes": [
           {"databaseId": 1, "body": "submitted earlier", "state": "SUBMITTED",
            "pullRequestReview": {"databaseId": 42}},
           {"databaseId": 2, "body": "someone else's pending", "state": "PENDING",
            "pullRequestReview": {"databaseId": 99}},
           {"databaseId": null, "body": "no id", "state": "PENDING",
            "pullRequestReview": {"databaseId": 42}},
           {"databaseId": 3, "body": "mine", "state": "PENDING",
            "pullRequestReview": {"databaseId": 42}}]}}
        """)
        let parsed = try GitHubClient.parsePendingCommentsPage(page, reviewID: 42)
        #expect(parsed.comments.map(\.body) == ["mine"])
    }

    @Test func graphQLFileLevelThreadWithoutLineAnchorIsSkipped() throws {
        let page = threadsPage(nodes: """
        {"diffSide": "RIGHT", "line": null, "startLine": null,
         "originalLine": null, "originalStartLine": null, "path": "docs/a.md",
         "comments": {"nodes": [
           {"databaseId": 4, "body": "file-level", "state": "PENDING",
            "pullRequestReview": {"databaseId": 42}}]}}
        """)
        let parsed = try GitHubClient.parsePendingCommentsPage(page, reviewID: 42)
        #expect(parsed.comments.isEmpty)
    }

    @Test func graphQLPaginationCursorSurfacesOnlyWithNextPage() throws {
        let more = threadsPage(nodes: "", hasNextPage: true, endCursor: "abc")
        #expect(try GitHubClient.parsePendingCommentsPage(more, reviewID: 1).nextCursor == "abc")
        let done = threadsPage(nodes: "", hasNextPage: false, endCursor: "abc")
        #expect(try GitHubClient.parsePendingCommentsPage(done, reviewID: 1).nextCursor == nil)
    }

    @Test func graphQLMalformedResponseThrowsRatherThanDecodingEmpty() {
        // An empty result must always mean "genuinely no pending comments";
        // a null repository (bad access, wrong repo) must fail loudly.
        let bad = Data(#"{"data": {"repository": null}}"#.utf8)
        #expect(throws: Error.self) {
            try GitHubClient.parsePendingCommentsPage(bad, reviewID: 1)
        }
    }

    // MARK: - Pending-review selection

    private func review(id: Int, state: String, login: String?) -> PullRequestReview {
        PullRequestReview(id: id, nodeId: "PRR_\(id)",
                          user: login.map { PullRequestReview.User(login: $0) },
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

    // MARK: - Row identity across upload and refetch

    @Test func pendingCommentIdentityNeverFlipsToTheServerID() {
        var comment = local("x")
        let before = comment.id
        comment.serverID = 99
        #expect(comment.id == before,
                "gaining a serverID must not rebuild the SwiftUI row")
    }

    @Test func uploadedQueuedCommentKeepsItsRowIdentity() {
        let queued = local("note")
        // The server copy comes back from GraphQL with a fresh UUID.
        let result = PendingReviewSync.reconcile(server: [server("note", id: 7)],
                                                 previousServer: [], queue: [queued])
        #expect(result.queue.isEmpty)
        #expect(result.server.first?.localID == queued.localID)
        #expect(result.server.first?.id == queued.id)
        #expect(result.server.first?.serverID == 7)
    }

    @Test func refetchedServerCommentKeepsIdentityViaServerID() {
        let firstSeen = PendingReviewSync.reconcile(server: [server("note", id: 7)],
                                                    previousServer: [], queue: []).server
        // Next adoption returns the same comment (body edited on
        // github.com in the meantime) under a fresh UUID.
        let again = PendingReviewSync.reconcile(server: [server("note, edited", id: 7)],
                                                previousServer: firstSeen, queue: []).server
        #expect(again.first?.localID == firstSeen.first?.localID)
    }

    @Test func externalServerCommentLeavesTheQueueAlone() {
        let queued = local("mine, not uploaded yet", line: 3)
        let external = server("added on github.com", id: 50, line: 8)
        let result = PendingReviewSync.reconcile(server: [external],
                                                 previousServer: [], queue: [queued])
        #expect(result.queue == [queued])
        #expect(result.server.first?.localID == external.localID)
    }

    @Test func reconciliationWorksAgainstGraphQLShapedData() throws {
        // End to end over real decoding: a queued comment uploads, the
        // GraphQL fetch returns it — the queue drains and the server copy
        // wears the queued comment's identity.
        let queued = PendingComment(path: "docs/a.md", lineStart: 12, lineEnd: 12,
                                    side: "RIGHT", body: "note")
        let page = threadsPage(nodes: """
        {"diffSide": "RIGHT", "line": 12, "startLine": null,
         "originalLine": 12, "originalStartLine": null, "path": "docs/a.md",
         "comments": {"nodes": [
           {"databaseId": 7, "body": "note", "state": "PENDING",
            "pullRequestReview": {"databaseId": 42}}]}}
        """)
        let fetched = try GitHubClient.parsePendingCommentsPage(page, reviewID: 42).comments
        let result = PendingReviewSync.reconcile(server: fetched,
                                                 previousServer: [], queue: [queued])
        #expect(result.queue.isEmpty, "the uploaded comment must not re-upload forever")
        #expect(result.server.first?.id == queued.id)
    }

    // MARK: - Create-authoritative sync (the no-second-create rule)

    // A successful atomic create is its own proof: the sent comments move
    // into the adopted state from the response, with no re-fetch of
    // GitHub's lagging reviews list. The create branch is guarded on
    // `pendingReview == nil`, so a non-nil state out of stateAfterCreate
    // IS the no-second-create rule — the same pass can never re-enter the
    // create path and 422 against the review it just created.

    @Test func createResponseBecomesTheAdoptedStateAndDrainsTheQueue() {
        let sent = [local("first"), local("second")]
        let created = PullRequestReview(id: 42, nodeId: "PRR_42",
                                        user: .init(login: "me"),
                                        body: nil, state: "PENDING",
                                        commitId: "abc123")
        let outcome = PendingReviewSync.stateAfterCreate(
            review: created, sent: sent, queue: sent, fallbackCommitID: "head999")
        #expect(outcome.state.reviewID == 42)
        #expect(outcome.state.nodeID == "PRR_42")
        #expect(outcome.state.commitID == "abc123")
        #expect(outcome.state.comments == sent,
                "every sent comment was accepted with the atomic create")
        #expect(outcome.queue.isEmpty)
    }

    @Test func stateAfterCreateKeepsMidFlightAdditionsQueued() {
        let sent = [local("sent while creating")]
        let midFlight = local("typed during the create round-trip")
        let created = PullRequestReview(id: 1, nodeId: "PRR_1", user: nil,
                                        body: nil, state: "PENDING", commitId: nil)
        let outcome = PendingReviewSync.stateAfterCreate(
            review: created, sent: sent, queue: sent + [midFlight],
            fallbackCommitID: "head999")
        #expect(outcome.queue == [midFlight])
        #expect(outcome.state.commitID == "head999",
                "a response without commit_id falls back to the loaded head")
    }

    @Test func createResponseDecodesAndToleratesDrift() {
        let body = Data("""
        {"id": 7, "node_id": "PRR_7", "user": {"login": "me"},
         "body": "", "state": "PENDING", "commit_id": "abc"}
        """.utf8)
        let decoded = GitHubClient.decodeCreatedReview(body)
        #expect(decoded?.id == 7)
        #expect(decoded?.nodeId == "PRR_7")
        #expect(decoded?.commitId == "abc")
        // Shape drift degrades to nil (the caller adopts instead) rather
        // than throwing — the review already exists server-side.
        #expect(GitHubClient.decodeCreatedReview(Data("not json".utf8)) == nil)
    }

    @Test func laterAdoptionIdentifiesIdlessCreatedCommentsByAuthoring() {
        // Comments landed by the atomic create carry no serverID until a
        // normal adoption sees them; the fresh fetch must hand ids to the
        // known copies without rebuilding their row identity.
        let created = local("note")
        let again = PendingReviewSync.reconcile(server: [server("note", id: 7)],
                                                previousServer: [created], queue: [])
        #expect(again.server.first?.localID == created.localID)
        #expect(again.server.first?.serverID == 7)
    }

    @Test func idlessIdentityMatchClaimsEachKnownCommentOnce() {
        let one = local("dup")
        let two = local("dup")
        let again = PendingReviewSync.reconcile(
            server: [server("dup", id: 1), server("dup", id: 2)],
            previousServer: [one, two], queue: [])
        #expect(Set(again.server.map(\.localID)) == Set([one.localID, two.localID]))
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

/// Single-flight semantics for the upload loop: changes during a pass
/// re-run it, and concurrent callers wait instead of silently skipping.
@Suite @MainActor struct PendingSyncGateTests {
    /// Mutable state shared with @Sendable Task closures (everything runs
    /// on the main actor, so access is serialized).
    @MainActor private final class Box {
        var passes = 0
        var events: [String] = []
        var release: CheckedContinuation<Void, Never>?
    }

    @Test func runsExactlyOnePassWhenNothingChanges() async {
        let gate = PendingSyncGate()
        let box = Box()
        await gate.run("k") { box.passes += 1 }
        #expect(box.passes == 1)
    }

    @Test func changeDuringTheFinalPassTriggersOneMorePass() async {
        // Finding: a comment added during an in-flight sync's final pass
        // was swallowed by the single-flight guard until a manual retry.
        let gate = PendingSyncGate()
        let box = Box()
        await gate.run("k") {
            box.passes += 1
            if box.passes == 1 { gate.noteChange("k") }
        }
        #expect(box.passes == 2)
    }

    @Test func changeNotedWhilePassIsSuspendedGetsAnotherPass() async {
        let gate = PendingSyncGate()
        let box = Box()
        let run = Task { @MainActor in
            await gate.run("k") {
                box.passes += 1
                if box.passes == 1 {
                    await withCheckedContinuation { box.release = $0 }
                }
            }
        }
        while box.release == nil { await Task.yield() }
        gate.noteChange("k") // a comment lands mid-upload
        box.release?.resume()
        await run.value
        #expect(box.passes == 2)
    }

    @Test func concurrentCallerWaitsForTheInFlightRunInsteadOfSkipping() async {
        // Finding: submitReview's pre-submit sync was a no-op while another
        // sync was in flight, producing a spurious upload error mid-upload.
        let gate = PendingSyncGate()
        let box = Box()
        let first = Task { @MainActor in
            await gate.run("k") {
                box.events.append("first-begin")
                await withCheckedContinuation { box.release = $0 }
                box.events.append("first-end")
            }
        }
        while box.release == nil { await Task.yield() }
        let second = Task { @MainActor in
            await gate.run("k") { box.events.append("second-pass") }
            box.events.append("second-returned")
        }
        // Deterministic: wait until the second caller is provably parked.
        while gate.waiterCount("k") == 0 { await Task.yield() }
        box.release?.resume()
        await first.value
        await second.value
        #expect(box.events == ["first-begin", "first-end", "second-returned"],
                "the second caller must not run its own pass, and must return only after the first run finished")
        #expect(gate.isRunning("k") == false)
    }

    @Test func waitUntilIdleReturnsImmediatelyWhenNothingIsInFlight() async {
        let gate = PendingSyncGate()
        await gate.waitUntilIdle("k")
        #expect(gate.isRunning("k") == false)
    }

    @Test func differentKeysDoNotBlockEachOther() async {
        let gate = PendingSyncGate()
        let box = Box()
        let blocked = Task { @MainActor in
            await gate.run("a") {
                await withCheckedContinuation { box.release = $0 }
            }
        }
        while box.release == nil { await Task.yield() }
        await gate.run("b") { box.passes += 1 }
        #expect(box.passes == 1, "an in-flight run for one PR must not stall another PR's sync")
        box.release?.resume()
        await blocked.value
    }
}

/// GitHub error payloads come in two `errors` shapes; both must render as
/// readable messages, never raw JSON (finding: the self-approval 422).
@Suite struct GitHubErrorMessageTests {
    @Test func objectShapedErrorsJoinTheirMessages() {
        let data = Data("""
        {"message": "Validation Failed",
         "errors": [{"resource": "PullRequestReview", "code": "custom",
                     "message": "Something specific went wrong"}]}
        """.utf8)
        #expect(GitHubClient.errorMessage(from: data)
            == "Validation Failed — Something specific went wrong")
    }

    @Test func stringShapedErrorsDecodeToo() {
        // Live-verified shape of the self-approval 422.
        let data = Data("""
        {"message": "Unprocessable Entity",
         "errors": ["Can not approve your own pull request"],
         "documentation_url": "https://docs.github.com/rest"}
        """.utf8)
        #expect(GitHubClient.errorMessage(from: data)
            == "Unprocessable Entity — Can not approve your own pull request")
    }

    @Test func messagelessErrorEntriesAreSkippedNotFatal() {
        let data = Data("""
        {"message": "Validation Failed",
         "errors": [{"resource": "Review", "code": "custom"}, "plain text detail"]}
        """.utf8)
        #expect(GitHubClient.errorMessage(from: data)
            == "Validation Failed — plain text detail")
    }

    @Test func nonJSONBodyFallsBackToRawText() {
        #expect(GitHubClient.errorMessage(from: Data("upstream said no".utf8))
            == "upstream said no")
    }
}
