import Foundation
import Testing
@testable import PullMark

@Suite struct GitHubRequestBodyTests {
    private func json(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func singleLineCommentBody() throws {
        let comment = PendingComment(path: "docs/a.md", lineStart: 12, lineEnd: 12, side: "RIGHT", body: "typo")
        let object = try json(GitHubClient.commentRequestBody(commitID: "abc123", comment: comment))
        #expect(object["body"] as? String == "typo")
        #expect(object["commit_id"] as? String == "abc123")
        #expect(object["path"] as? String == "docs/a.md")
        #expect(object["line"] as? Int == 12)
        #expect(object["side"] as? String == "RIGHT")
        #expect(object["start_line"] == nil)
        #expect(object["start_side"] == nil)
    }

    @Test func multiLineCommentBodyIncludesStart() throws {
        let comment = PendingComment(path: "a.md", lineStart: 3, lineEnd: 9, side: "LEFT", body: "hm")
        let object = try json(GitHubClient.commentRequestBody(commitID: "sha", comment: comment))
        #expect(object["line"] as? Int == 9)
        #expect(object["start_line"] as? Int == 3)
        #expect(object["start_side"] as? String == "LEFT")
    }

    @Test func pendingReviewBodyOmitsEvent() throws {
        let pending = [PendingComment(path: "a.md", lineStart: 1, lineEnd: 1, side: "RIGHT", body: "one")]
        let object = try json(GitHubClient.reviewRequestBody(commitID: "sha", body: nil, event: nil, comments: pending))
        #expect(object["commit_id"] as? String == "sha")
        #expect(object["event"] == nil, "omitting event keeps the review pending (draft)")
        let comments = try #require(object["comments"] as? [[String: Any]])
        #expect(comments.count == 1)
        #expect(comments[0]["path"] as? String == "a.md")
        #expect(comments[0]["line"] as? Int == 1)
    }

    @Test func submittedReviewBodyCarriesEventAndSummary() throws {
        let object = try json(GitHubClient.reviewRequestBody(
            commitID: "sha", body: "Looks good", event: "APPROVE", comments: []))
        #expect(object["event"] as? String == "APPROVE")
        #expect(object["body"] as? String == "Looks good")
        // A comment-less review (the overview's verdict-only path) must omit
        // the optional comments parameter, not send [].
        #expect(object["comments"] == nil)
    }

    @Test func submitReviewEventBodyCarriesEventAndBody() throws {
        let object = try json(GitHubClient.submitReviewRequestBody(
            event: "REQUEST_CHANGES", body: "Needs work"))
        #expect(object["event"] as? String == "REQUEST_CHANGES")
        #expect(object["body"] as? String == "Needs work")
    }

    @Test func submitReviewEventBodyOmitsNilBody() throws {
        let object = try json(GitHubClient.submitReviewRequestBody(event: "APPROVE", body: nil))
        #expect(object["event"] as? String == "APPROVE")
        #expect(object["body"] == nil)
    }

    @Test func addThreadInputSingleLineOmitsStart() {
        let comment = PendingComment(path: "docs/b.md", lineStart: 7, lineEnd: 7, side: "RIGHT", body: "nit")
        let input = GitHubClient.addThreadInput(reviewNodeID: "PRR_node", comment: comment)
        #expect(input["pullRequestReviewId"] as? String == "PRR_node")
        #expect(input["path"] as? String == "docs/b.md")
        #expect(input["body"] as? String == "nit")
        #expect(input["line"] as? Int == 7)
        #expect(input["side"] as? String == "RIGHT")
        #expect(input["startLine"] == nil)
        #expect(input["startSide"] == nil)
    }

    @Test func addThreadInputMultiLineCarriesStart() {
        let comment = PendingComment(path: "b.md", lineStart: 2, lineEnd: 5, side: "RIGHT", body: "range")
        let input = GitHubClient.addThreadInput(reviewNodeID: "PRR_x", comment: comment)
        #expect(input["line"] as? Int == 5)
        #expect(input["startLine"] as? Int == 2)
        #expect(input["startSide"] as? String == "RIGHT")
    }

    @Test func fileCommentBodyCarriesSubjectType() throws {
        let object = try json(GitHubClient.fileCommentRequestBody(
            commitID: "sha9", path: "docs/guide.md", body: "whole-file note"))
        #expect(object["body"] as? String == "whole-file note")
        #expect(object["commit_id"] as? String == "sha9")
        #expect(object["path"] as? String == "docs/guide.md")
        #expect(object["subject_type"] as? String == "file")
        #expect(object["line"] == nil)
    }

    @Test func issueCommentBodyIsJustTheBody() throws {
        let object = try json(GitHubClient.issueCommentRequestBody(body: "hello"))
        #expect(object.count == 1)
        #expect(object["body"] as? String == "hello")
    }
}
