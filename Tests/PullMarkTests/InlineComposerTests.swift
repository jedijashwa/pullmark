import Foundation
import Testing
@testable import PullMark

@Suite struct InlineComposerTests {
    private let patch = """
    @@ -1,4 +1,5 @@
     # Title
    -old intro
    +new intro
    +second added line
     context
     tail
    @@ -20,3 +21,3 @@
     late context
    -removed late
    +added late
     closing
    """

    // MARK: - Commentable runs (inline validation, spec §5)

    @Test func runsComeStraightFromHunkHeaders() {
        let runs = CommentableLines.runs(patch: patch)
        #expect(runs.right == [1...5, 21...23])
        #expect(runs.left == [1...4, 20...22])
    }

    @Test func runsDefaultOmittedCountsToOne() {
        let runs = CommentableLines.runs(patch: "@@ -3 +7 @@\n-x\n+y")
        #expect(runs.left == [3...3])
        #expect(runs.right == [7...7])
    }

    @Test func runsSkipZeroCountSides() {
        // A pure-deletion hunk has no new-side lines at all.
        let runs = CommentableLines.runs(patch: "@@ -4,2 +3,0 @@\n-a\n-b")
        #expect(runs.left == [4...5])
        #expect(runs.right.isEmpty)
    }

    @Test func runsIgnoreHunkLookalikesInContent() {
        // A context line that merely contains "@@" is not a header.
        let runs = CommentableLines.runs(patch: "@@ -1,1 +1,1 @@\n context @@ -9,9 +9,9 @@")
        #expect(runs.right == [1...1])
    }

    @Test func validityRequiresTheRangeInsideOneRun() {
        let runs = CommentableLines.runs(patch: patch).right // [1...5, 21...23]
        #expect(CommentableLines.isValid(2...4, in: runs))
        #expect(CommentableLines.isValid(21...23, in: runs))
        #expect(CommentableLines.isValid(5...5, in: runs))
        #expect(!CommentableLines.isValid(5...21, in: runs))   // spans hunks
        #expect(!CommentableLines.isValid(6...8, in: runs))    // between hunks
        #expect(!CommentableLines.isValid(4...6, in: runs))    // pokes out
    }

    @Test func clampPicksTheLargestSingleRunIntersection() {
        let runs = CommentableLines.runs(patch: patch).right // [1...5, 21...23]
        #expect(CommentableLines.clamp(3...30, to: runs) == 3...5)
        #expect(CommentableLines.clamp(20...23, to: runs) == 21...23)
        #expect(CommentableLines.clamp(6...20, to: runs) == nil)
        #expect(CommentableLines.clamp(22...40, to: runs) == 22...23)
    }

    @Test func clampTiesKeepTheEarlierRun() {
        let runs: [ClosedRange<Int>] = [1...5, 21...23]
        #expect(CommentableLines.clamp(4...22, to: runs) == 4...5)
    }

    @Test func payloadIsNilWithoutAPatch() {
        #expect(CommentableLines.payload(patch: nil) == nil)
        #expect(CommentableLines.payload(patch: "") == nil)
        #expect(CommentableLines.payload(patch: "no hunks here") == nil)
    }

    @Test func payloadEncodesRunsAsPairs() {
        let payload = CommentableLines.payload(patch: patch)
        #expect(payload?.right == [[1, 5], [21, 23]])
        #expect(payload?.left == [[1, 4], [20, 22]])
    }

    // MARK: - Patch line payloads (Source Diff line numbers)

    @Test func patchLinePayloadsMirrorLineOrigins() {
        let lines = PatchComposerLines.payloads(patch: "@@ -1,2 +1,2 @@\n context\n-old\n+new")
        #expect(lines == [
            PatchLinePayload(index: 1, old: 1, new: 1),
            PatchLinePayload(index: 2, old: 2, new: nil),
            PatchLinePayload(index: 3, old: nil, new: 2),
        ])
    }

    // MARK: - Review-in-progress labeling state

    private func session(pending: PendingReviewState? = nil,
                         queued: [PendingComment] = []) -> PRSession {
        var session = PRSession(
            ref: PullRequestRef(owner: "o", repo: "r", number: 1),
            details: PullRequestDetails(
                number: 1, title: "t", body: nil, state: "open",
                draft: nil, merged: nil,
                head: .init(sha: "h", ref: "f"), base: .init(sha: "b", ref: "main"),
                htmlUrl: URL(string: "https://github.com/o/r/pull/1")!, user: nil),
            mergeBaseSHA: "b", files: [])
        session.pendingReview = pending
        session.queuedComments = queued
        return session
    }

    @Test func reviewInProgressFollowsPendingReviewAndQueue() {
        #expect(!session().reviewInProgress)
        #expect(session(pending: PendingReviewState(
            reviewID: 1, nodeID: "n", commitID: nil, summary: nil, comments: []))
            .reviewInProgress)
        #expect(session(queued: [PendingComment(
            path: "a.md", lineStart: 1, lineEnd: 1, side: "RIGHT", body: "b")])
            .reviewInProgress)
    }

    // MARK: - Draft store

    private let ref = PullRequestRef(owner: "octo", repo: "docs", number: 7)

    @Test func lineDraftKeysIncludeTheHeadReplyKeysDoNot() {
        #expect(ComposerDraftStore.storageKey(ref: ref, headSHA: "abc", path: "a.md",
                                              jsKey: "RIGHT:12-14")
            == "octo/docs#7@abc|a.md|RIGHT:12-14")
        #expect(ComposerDraftStore.storageKey(ref: ref, headSHA: "abc", path: "a.md",
                                              jsKey: "reply:99")
            == "octo/docs#7|a.md|reply:99")
    }

    @Test func updateStoresRemovesAndCaps() {
        var stored = ComposerDraftStore.updated([:], key: "k1", text: "hello",
                                                now: Date(timeIntervalSince1970: 1))
        #expect(stored["k1"]?.text == "hello")
        stored = ComposerDraftStore.updated(stored, key: "k1", text: "")
        #expect(stored.isEmpty)

        var many: [String: ComposerDraftStore.StoredDraft] = [:]
        for i in 0..<ComposerDraftStore.maxDrafts {
            many = ComposerDraftStore.updated(many, key: "k\(i)", text: "t",
                                              now: Date(timeIntervalSince1970: Double(i)))
        }
        many = ComposerDraftStore.updated(many, key: "fresh", text: "t",
                                          now: Date(timeIntervalSince1970: 10_000))
        #expect(many.count == ComposerDraftStore.maxDrafts)
        #expect(many["k0"] == nil)         // oldest evicted
        #expect(many["fresh"] != nil)
    }

    @Test func draftsFilterByPRHeadAndPathAndStripPrefixes() {
        var stored: [String: ComposerDraftStore.StoredDraft] = [:]
        func put(_ key: String, _ text: String) {
            stored = ComposerDraftStore.updated(stored, key: key, text: text)
        }
        put(ComposerDraftStore.storageKey(ref: ref, headSHA: "abc", path: "a.md",
                                          jsKey: "RIGHT:3-6"), "mine")
        put(ComposerDraftStore.storageKey(ref: ref, headSHA: "abc", path: "a.md",
                                          jsKey: "reply:42"), "reply text")
        put(ComposerDraftStore.storageKey(ref: ref, headSHA: "old", path: "a.md",
                                          jsKey: "RIGHT:3-6"), "stale head")
        put(ComposerDraftStore.storageKey(ref: ref, headSHA: "abc", path: "b.md",
                                          jsKey: "RIGHT:1-1"), "other file")

        let drafts = ComposerDraftStore.drafts(in: stored, ref: ref,
                                               headSHA: "abc", path: "a.md")
        #expect(drafts == ["RIGHT:3-6": "mine", "reply:42": "reply text"])
    }

    @Test func replyDraftsSurviveHeadMoves() {
        let stored = ComposerDraftStore.updated(
            [:],
            key: ComposerDraftStore.storageKey(ref: ref, headSHA: "abc", path: "a.md",
                                               jsKey: "reply:42"),
            text: "kept")
        let afterMove = ComposerDraftStore.drafts(in: stored, ref: ref,
                                                  headSHA: "moved", path: "a.md")
        #expect(afterMove == ["reply:42": "kept"])
    }

    @Test func draftsRoundTripThroughEncoding() {
        let stored = ComposerDraftStore.updated([:], key: "k", text: "text",
                                                now: Date(timeIntervalSince1970: 5))
        let decoded = ComposerDraftStore.decode(ComposerDraftStore.encode(stored))
        #expect(decoded == stored)
    }
}
