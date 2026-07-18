import Foundation
import Testing
@testable import PullMark

@Suite struct GitHubRequestBodyTests {
    private func json(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func singleLineCommentBody() throws {
        let draft = DraftComment(path: "docs/a.md", lineStart: 12, lineEnd: 12, side: "RIGHT", body: "typo")
        let object = try json(GitHubClient.commentRequestBody(commitID: "abc123", comment: draft))
        #expect(object["body"] as? String == "typo")
        #expect(object["commit_id"] as? String == "abc123")
        #expect(object["path"] as? String == "docs/a.md")
        #expect(object["line"] as? Int == 12)
        #expect(object["side"] as? String == "RIGHT")
        #expect(object["start_line"] == nil)
        #expect(object["start_side"] == nil)
    }

    @Test func multiLineCommentBodyIncludesStart() throws {
        let draft = DraftComment(path: "a.md", lineStart: 3, lineEnd: 9, side: "LEFT", body: "hm")
        let object = try json(GitHubClient.commentRequestBody(commitID: "sha", comment: draft))
        #expect(object["line"] as? Int == 9)
        #expect(object["start_line"] as? Int == 3)
        #expect(object["start_side"] as? String == "LEFT")
    }

    @Test func pendingReviewBodyOmitsEvent() throws {
        let drafts = [DraftComment(path: "a.md", lineStart: 1, lineEnd: 1, side: "RIGHT", body: "one")]
        let object = try json(GitHubClient.reviewRequestBody(commitID: "sha", body: nil, event: nil, drafts: drafts))
        #expect(object["commit_id"] as? String == "sha")
        #expect(object["event"] == nil, "omitting event keeps the review pending (draft)")
        let comments = try #require(object["comments"] as? [[String: Any]])
        #expect(comments.count == 1)
        #expect(comments[0]["path"] as? String == "a.md")
        #expect(comments[0]["line"] as? Int == 1)
    }

    @Test func submittedReviewBodyCarriesEventAndSummary() throws {
        let object = try json(GitHubClient.reviewRequestBody(
            commitID: "sha", body: "Looks good", event: "APPROVE", drafts: []))
        #expect(object["event"] as? String == "APPROVE")
        #expect(object["body"] as? String == "Looks good")
    }
}
