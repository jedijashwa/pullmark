import Foundation
import Testing
@testable import PullMark

@Suite struct ThreadVisibilityTests {
    private func comment(id: Int, path: String = "a.md", line: Int? = 5, side: String? = "RIGHT",
                         startLine: Int? = nil, originalLine: Int? = nil,
                         subjectType: String? = nil, replyTo: Int? = nil,
                         author: String = "alice") -> ReviewComment {
        ReviewComment(id: id, path: path, body: "c\(id)", line: line, side: side,
                      startLine: startLine, originalLine: originalLine, subjectType: subjectType,
                      inReplyToId: replyTo,
                      user: .init(login: author), createdAt: "2026-07-18T12:00:00Z", htmlUrl: nil)
    }

    private func pending(path: String = "a.md", start: Int = 3, end: Int = 4,
                         side: String = "RIGHT", uploaded: Bool = false) -> PendingComment {
        PendingComment(serverID: uploaded ? 99 : nil, path: path,
                       lineStart: start, lineEnd: end, side: side, body: "draft")
    }

    // MARK: - Result-view markers (spec §1)

    @Test func resultAnchoredKeepsOnlyLiveRightSideLineThreads() {
        let threads = ReviewThreads.group([
            comment(id: 1, line: 5),                                    // anchored RIGHT
            comment(id: 2, line: 8, side: "LEFT"),                      // old side: excluded
            comment(id: 3, line: nil, originalLine: 4),                 // outdated: excluded
            comment(id: 4, line: nil, side: nil, subjectType: "file"),  // file-level: excluded
        ])
        let anchored = ThreadVisibility.resultAnchored(threads, meta: [:])
        #expect(anchored.count == 1)
        #expect(anchored[0].rootID == 1)
        #expect(anchored[0].anchorStart == 5)
        #expect(anchored[0].anchorEnd == 5)
        #expect(anchored[0].resolved == nil)
    }

    @Test func resultAnchoredCarriesRangeAndResolvedState() {
        let threads = ReviewThreads.group([
            comment(id: 1, line: 14, startLine: 12),
            comment(id: 2, line: 20),
        ])
        let meta = [1: ThreadMeta(nodeID: "n1", isResolved: true),
                    2: ThreadMeta(nodeID: "n2", isResolved: false)]
        let anchored = ThreadVisibility.resultAnchored(threads, meta: meta)
        #expect(anchored.count == 2)
        #expect(anchored[0].anchorStart == 12)
        #expect(anchored[0].anchorEnd == 14)
        #expect(anchored[0].resolved == true)
        #expect(anchored[1].resolved == false)
    }

    @Test func resultAnchoredCountsRepliesInComments() {
        let threads = ReviewThreads.group([
            comment(id: 1, line: 5),
            comment(id: 2, replyTo: 1, author: "bob"),
        ])
        let anchored = ThreadVisibility.resultAnchored(threads, meta: [:])
        #expect(anchored[0].comments.count == 2)
        #expect(anchored[0].comments[0].author == "alice")
    }

    // MARK: - Presence signals (spec §2)

    @Test func unresolvedCountsGroupPerPathAndSkipResolved() {
        let comments = [
            comment(id: 1, path: "a.md", line: 5),
            comment(id: 2, path: "a.md", replyTo: 1),          // reply counts
            comment(id: 3, path: "a.md", line: 9),             // resolved below
            comment(id: 4, path: "b.md", line: nil, originalLine: 2),  // outdated still counts
            comment(id: 5, path: "b.md", line: nil, side: nil, subjectType: "file"),
            comment(id: 6, path: "c.md", line: 3, side: "LEFT"),       // old side still counts
        ]
        let meta = [3: ThreadMeta(nodeID: "n3", isResolved: true)]
        let counts = ThreadVisibility.unresolvedCommentCounts(comments: comments, meta: meta)
        #expect(counts["a.md"] == 2)
        #expect(counts["b.md"] == 2)
        #expect(counts["c.md"] == 1)
    }

    @Test func hiddenFileCommentCountIsCommentsOffTheShownPaths() {
        let comments = [
            comment(id: 1, path: "docs/a.md"),
            comment(id: 2, path: "src/main.swift"),
            comment(id: 3, path: "src/main.swift", replyTo: 2),
            comment(id: 4, path: "Package.swift"),
        ]
        let hidden = ThreadVisibility.hiddenFileCommentCount(
            comments: comments, meta: [:], visiblePaths: ["docs/a.md"])
        #expect(hidden == 3)
    }

    /// Same inclusion rule as the sidebar badges: a resolved conversation
    /// is settled and counts nowhere — including the overview's
    /// hidden-files honesty line.
    @Test func hiddenFileCommentCountSkipsResolvedThreads() {
        let comments = [
            comment(id: 1, path: "src/main.swift"),
            comment(id: 2, path: "src/main.swift", replyTo: 1),
            comment(id: 3, path: "Package.swift"),
        ]
        let meta = [1: ThreadMeta(nodeID: "n1", isResolved: true)]
        let hidden = ThreadVisibility.hiddenFileCommentCount(
            comments: comments, meta: meta, visiblePaths: ["docs/a.md"])
        #expect(hidden == 1)
    }

    // MARK: - Pending comments at anchors (spec §3)

    @Test func resultPendingFiltersPathAndSide() {
        let items = [
            pending(path: "a.md", start: 3, end: 4),
            pending(path: "a.md", side: "LEFT"),   // no old side in Result
            pending(path: "b.md"),
        ]
        let placed = ThreadVisibility.resultPending(items, path: "a.md",
                                                    queuedIDs: [items[0].id])
        #expect(placed.count == 1)
        #expect(placed[0].lineStart == 3)
        #expect(placed[0].lineLabel == "Lines 3–4 (new)")
        #expect(placed[0].uploaded == false)
    }

    /// "Uploaded" is membership in the adopted review (the queued set),
    /// not serverID presence — the atomic create lands comments before
    /// their ids echo back (PendingReviewSync.stateAfterCreate).
    @Test func pendingPayloadLabelsSingleLineAndUpload() {
        let payload = PendingPayload(pending(start: 7, end: 7), uploaded: true)
        #expect(payload.lineLabel == "Line 7 (new)")
        #expect(payload.uploaded)
    }

    private func segment(_ kind: String, _ start: Int, _ end: Int, side: String = "RIGHT",
                         oldStart: Int? = nil, oldEnd: Int? = nil) -> DiffSegmentPayload {
        DiffSegmentPayload(kind: kind, text: "t", oldText: nil,
                           lineStart: start, lineEnd: end, side: side,
                           oldLineStart: oldStart, oldLineEnd: oldEnd)
    }

    @Test func pendingAnchorsUseContainmentOnTheMatchingSide() {
        let segments = [
            segment("unchanged", 1, 2, oldStart: 1, oldEnd: 2),
            segment("added", 3, 6),
            segment("removed", 4, 5, side: "LEFT"),
        ]
        let placed = PendingAnchors.place(
            [pending(start: 3, end: 4),
             pending(start: 4, end: 4, side: "LEFT"),
             pending(start: 40, end: 41)],  // outside every block: dropped
            in: segments)
        #expect(placed[1].pending?.count == 1)
        #expect(placed[2].pending?.count == 1)
        #expect(placed[0].pending == nil)
    }

    @Test func pendingAnchorsLeftSideMatchesOldRangesOfDualSidedSegments() {
        let segments = [segment("unchanged", 10, 12, oldStart: 20, oldEnd: 22)]
        let placed = PendingAnchors.place([pending(start: 21, end: 21, side: "LEFT")],
                                          in: segments)
        #expect(placed[0].pending?.count == 1)
        // And an old-side line must never match a new-side range.
        let unplaced = PendingAnchors.place([pending(start: 11, end: 11, side: "LEFT")],
                                            in: [segment("added", 10, 12)])
        #expect(unplaced[0].pending == nil)
    }

    // MARK: - Source Diff gutter badges (spec §1, last bullet)

    private let patch = """
    @@ -1,3 +1,4 @@
     Intro line
    -Old heading
    +New heading
    +Added detail
     Outro line
    @@ -10,2 +11,2 @@
     Later context
    -gone
    """

    @Test func lineOriginsFollowHunkHeaders() {
        let origins = PatchAnchors.lineOrigins(patch: patch)
        // Index 1 = " Intro line": old 1, new 1.
        #expect(origins[0] == .init(index: 1, oldLine: 1, newLine: 1))
        // "-Old heading" is old 2 only; "+New heading" new 2 only.
        #expect(origins[1] == .init(index: 2, oldLine: 2, newLine: nil))
        #expect(origins[2] == .init(index: 3, oldLine: nil, newLine: 2))
        #expect(origins[3] == .init(index: 4, oldLine: nil, newLine: 3))
        #expect(origins[4] == .init(index: 5, oldLine: 3, newLine: 4))
        // Second hunk restarts the counters.
        #expect(origins[5] == .init(index: 7, oldLine: 10, newLine: 11))
        #expect(origins[6] == .init(index: 8, oldLine: 11, newLine: nil))
    }

    @Test func placeAnchorsThreadsAtExactPatchLines() {
        let threads = ReviewThreads.group([
            comment(id: 1, line: 2),                 // RIGHT new-line 2 → index 3
            comment(id: 2, line: 11, side: "LEFT"),  // LEFT old-line 11 → index 8
            comment(id: 3, line: nil, originalLine: 9),   // outdated: no patch line
            comment(id: 4, line: nil, side: nil, subjectType: "file"),
        ])
        let rows = PatchAnchors.place(threads: threads,
                                      meta: [1: ThreadMeta(nodeID: "n", isResolved: true)],
                                      pending: [pending(start: 4, end: 4)],
                                      patch: patch)
        #expect(rows.count == 3)
        #expect(rows[0].lineIndex == 3)
        #expect(rows[0].threads.first?.resolved == true)
        #expect(rows[1].lineIndex == 5)          // pending on new line 4
        #expect(rows[1].pending.count == 1)
        #expect(rows[2].lineIndex == 8)
        #expect(rows[2].threads.first?.rootID == 2)
    }

    @Test func placeMergesThreadsAndPendingOnOneLine() {
        let threads = ReviewThreads.group([comment(id: 1, line: 2)])
        let rows = PatchAnchors.place(threads: threads, meta: [:],
                                      pending: [pending(start: 2, end: 2)],
                                      patch: patch)
        #expect(rows.count == 1)
        #expect(rows[0].threads.count == 1)
        #expect(rows[0].pending.count == 1)
    }

    @Test func crlfPatchesStillAnchor() {
        let crlf = patch.replacingOccurrences(of: "\n", with: "\r\n")
        let rows = PatchAnchors.place(
            threads: ReviewThreads.group([comment(id: 1, line: 2)]),
            meta: [:], pending: [], patch: crlf)
        #expect(rows.count == 1)
        #expect(rows[0].lineIndex == 3)
    }
}
