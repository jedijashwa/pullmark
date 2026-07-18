import Foundation
import Testing
@testable import PullMark

@Suite struct ReviewThreadsTests {
    private func comment(id: Int, path: String = "a.md", line: Int? = 5, side: String? = "RIGHT",
                         originalLine: Int? = nil, replyTo: Int? = nil) -> ReviewComment {
        ReviewComment(id: id, path: path, body: "c\(id)", line: line, side: side,
                      startLine: nil, originalLine: originalLine, inReplyToId: replyTo,
                      user: .init(login: "alice"), createdAt: "2026-07-18T12:00:00Z", htmlUrl: nil)
    }

    private func segment(_ kind: String, _ start: Int, _ end: Int, side: String = "RIGHT") -> DiffSegmentPayload {
        DiffSegmentPayload(kind: kind, text: "t", oldText: nil, lineStart: start, lineEnd: end, side: side)
    }

    @Test func groupsRepliesUnderRoot() {
        let threads = ReviewThreads.group([
            comment(id: 1),
            comment(id: 2, replyTo: 1),
            comment(id: 3),
            comment(id: 4, replyTo: 1),
        ])
        #expect(threads.count == 2)
        #expect(threads[0].root.id == 1)
        #expect(threads[0].replies.map(\.id) == [2, 4])
        #expect(threads[1].root.id == 3)
    }

    @Test func orphanReplyBecomesRoot() {
        let threads = ReviewThreads.group([comment(id: 7, replyTo: 99)])
        #expect(threads.count == 1)
        #expect(threads[0].root.id == 7)
    }

    @Test func placesThreadInContainingSegment() {
        let segments = [segment("unchanged", 1, 3), segment("added", 4, 8), segment("unchanged", 9, 12)]
        let placed = ReviewThreads.place(ReviewThreads.group([comment(id: 1, line: 6)]), in: segments)
        #expect(placed.segments[1].threads?.count == 1)
        #expect(placed.segments[0].threads == nil)
        #expect(placed.outdated.isEmpty)
    }

    @Test func fallsBackToNearestSegment() {
        let segments = [segment("unchanged", 1, 3), segment("added", 10, 12)]
        let placed = ReviewThreads.place(ReviewThreads.group([comment(id: 1, line: 9)]), in: segments)
        #expect(placed.segments[1].threads?.count == 1)
    }

    @Test func leftSideCommentGoesToRemovedSegment() {
        let segments = [segment("removed", 5, 7, side: "LEFT"), segment("added", 5, 7, side: "RIGHT")]
        let placed = ReviewThreads.place(
            ReviewThreads.group([comment(id: 1, line: 6, side: "LEFT")]), in: segments)
        #expect(placed.segments[0].threads?.count == 1)
        #expect(placed.segments[1].threads == nil)
    }

    @Test func outdatedThreadsAreSeparated() {
        let segments = [segment("unchanged", 1, 3)]
        let placed = ReviewThreads.place(
            ReviewThreads.group([comment(id: 1, line: nil, originalLine: 4)]), in: segments)
        #expect(placed.segments[0].threads == nil)
        #expect(placed.outdated.count == 1)
        #expect(placed.outdated[0].lineLabel == "Outdated — was line 4")
    }

    @Test func decodesGitHubReviewCommentJSON() throws {
        let json = """
        [{
          "id": 123,
          "path": "docs/a.md",
          "body": "Nice change",
          "line": 12,
          "side": "RIGHT",
          "start_line": null,
          "original_line": 12,
          "in_reply_to_id": null,
          "user": { "login": "octocat" },
          "created_at": "2026-07-01T10:30:00Z",
          "html_url": "https://github.com/o/r/pull/1#discussion_r123"
        }]
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let comments = try decoder.decode([ReviewComment].self, from: Data(json.utf8))
        #expect(comments.count == 1)
        #expect(comments[0].id == 123)
        #expect(comments[0].line == 12)
        #expect(comments[0].author == "octocat")
        #expect(comments[0].inReplyToId == nil)
        #expect(!comments[0].dateLabel.isEmpty)
    }
}
