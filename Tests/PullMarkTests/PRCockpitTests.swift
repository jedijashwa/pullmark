import Foundation
import Testing
@testable import PullMark

@Suite struct CheckItemTests {
    @Test func conclusionDecidesCompletedRuns() {
        #expect(CheckItem.state(status: "COMPLETED", conclusion: "SUCCESS") == .passed)
        for failing in ["FAILURE", "TIMED_OUT", "CANCELLED", "STARTUP_FAILURE", "ACTION_REQUIRED"] {
            #expect(CheckItem.state(status: "COMPLETED", conclusion: failing) == .failed)
        }
        #expect(CheckItem.state(status: "COMPLETED", conclusion: "SKIPPED") == .skipped)
        #expect(CheckItem.state(status: "COMPLETED", conclusion: "NEUTRAL") == .neutral)
        #expect(CheckItem.state(status: "COMPLETED", conclusion: "STALE") == .neutral)
    }

    @Test func statusDecidesMovingRuns() {
        #expect(CheckItem.state(status: "IN_PROGRESS", conclusion: nil) == .running)
        #expect(CheckItem.state(status: "QUEUED", conclusion: nil) == .queued)
        #expect(CheckItem.state(status: "PENDING", conclusion: nil) == .queued)
        #expect(CheckItem.state(status: "REQUESTED", conclusion: nil) == .queued)
        // The deployment-approval gate is NOT activity — it can sit for
        // days and must never read as running (spec rule).
        #expect(CheckItem.state(status: "WAITING", conclusion: nil) == .waiting)
    }

    @Test func unknownFutureStatesDegradeToNeutral() {
        // New enum members must render a gray row, never a false verdict.
        #expect(CheckItem.state(status: "SOME_FUTURE_THING", conclusion: nil) == .neutral)
        #expect(CheckItem.state(status: nil, conclusion: "SOME_FUTURE_THING") == .neutral)
    }

    @Test func statusContextMapping() {
        #expect(CheckItem.state(contextState: "SUCCESS") == .passed)
        #expect(CheckItem.state(contextState: "FAILURE") == .failed)
        #expect(CheckItem.state(contextState: "ERROR") == .failed)
        // External CI has no queued/running distinction.
        #expect(CheckItem.state(contextState: "PENDING") == .queued)
        #expect(CheckItem.state(contextState: "EXPECTED") == .queued)
        #expect(CheckItem.state(contextState: nil) == .neutral)
    }

    @Test func durationLabels() {
        #expect(CheckItem.durationLabel(startedAt: "2026-08-19T10:00:00Z",
                                        completedAt: "2026-08-19T10:00:58Z") == "58s")
        #expect(CheckItem.durationLabel(startedAt: "2026-08-19T10:00:00Z",
                                        completedAt: "2026-08-19T10:03:12Z") == "3m 12s")
        #expect(CheckItem.durationLabel(startedAt: "2026-08-19T10:00:00Z",
                                        completedAt: "2026-08-19T11:04:00Z") == "1h 4m")
        #expect(CheckItem.durationLabel(startedAt: nil,
                                        completedAt: "2026-08-19T10:00:58Z") == nil)
        // A clock skew that runs backwards must not print "-3s".
        #expect(CheckItem.durationLabel(startedAt: "2026-08-19T10:00:10Z",
                                        completedAt: "2026-08-19T10:00:00Z") == nil)
    }
}

@Suite struct ChecksSummaryTests {
    private func item(_ state: CheckItem.State, name: String = "build") -> CheckItem {
        CheckItem(name: name, group: nil, state: state,
                  detailsUrl: nil, isRequired: false, durationLabel: nil)
    }

    @Test func emptyMeansNoCapsule() {
        // Repos without CI and approval-gated fork PRs both present an
        // empty rollup — "passed" would be a lie (spec rule).
        #expect(ChecksSummary.classify([]) == .none)
    }

    @Test func failureWinsOverEverything() {
        let summary = ChecksSummary.classify([
            item(.failed), item(.running), item(.waiting), item(.passed),
        ])
        #expect(summary == .failed(failing: 1, total: 4))
    }

    @Test func movingWinsOverWaitingAndPassed() {
        #expect(ChecksSummary.classify([item(.running), item(.waiting), item(.passed)])
            == .running(done: 2, total: 3))
        // Queued counts as moving too — it resolves on its own.
        #expect(ChecksSummary.classify([item(.queued), item(.passed)])
            == .running(done: 1, total: 2))
    }

    @Test func onlyWaitingGatesOutstanding() {
        #expect(ChecksSummary.classify([item(.waiting), item(.passed)])
            == .awaitingApproval)
    }

    @Test func skippedChecksDontBreakGreen() {
        // Verified live: 5 SKIPPED + 2 SUCCESS ⇒ rollup SUCCESS.
        #expect(ChecksSummary.classify([
            item(.passed), item(.passed), item(.skipped), item(.neutral),
        ]) == .passed(passed: 3, skipped: 1))
        #expect(ChecksSummary.classify([item(.skipped)]) == .passed(passed: 0, skipped: 1))
    }
}

@Suite struct PRConversationTests {
    private func comment(_ id: Int, body: String = "hello", at: String,
                         login: String = "sam-ortega", type: String? = nil) -> IssueComment {
        IssueComment(id: id, body: body,
                     user: .init(login: login, avatarUrl: nil, type: type),
                     createdAt: at, htmlUrl: nil, reactions: nil)
    }

    private func review(_ id: Int, state: String, body: String?, at: String?,
                        login: String = "riley-chen") -> PullRequestReview {
        PullRequestReview(id: id, nodeId: "R_\(id)", user: .init(login: login),
                          body: body, state: state, commitId: nil,
                          submittedAt: at, htmlUrl: nil)
    }

    @Test func reviewFilterKeepsVerdictsAndSpokenComments() {
        #expect(PRConversation.includesReview(state: "APPROVED", body: nil))
        #expect(PRConversation.includesReview(state: "CHANGES_REQUESTED", body: ""))
        #expect(PRConversation.includesReview(state: "DISMISSED", body: nil))
        #expect(PRConversation.includesReview(state: "COMMENTED", body: "real words"))
        // The noise case observed live: inline-only submissions leave
        // 3–5 empty COMMENTED rows per PR.
        #expect(!PRConversation.includesReview(state: "COMMENTED", body: ""))
        #expect(!PRConversation.includesReview(state: "COMMENTED", body: nil))
        #expect(!PRConversation.includesReview(state: "COMMENTED", body: "  \n"))
        // The viewer's unsubmitted review belongs to the popover.
        #expect(!PRConversation.includesReview(state: "PENDING", body: "draft"))
    }

    @Test func timelineInterleavesChronologically() {
        let entries = PRConversation.timeline(
            comments: [comment(2, at: "2026-08-19T12:00:00Z"),
                       comment(1, at: "2026-08-19T10:00:00Z")],
            reviews: [review(7, state: "APPROVED", body: nil, at: "2026-08-19T11:00:00Z"),
                      review(8, state: "COMMENTED", body: "", at: "2026-08-19T11:30:00Z")])
        #expect(entries.count == 3)
        guard case .comment(let first) = entries[0], first.id == 1,
              case .review(let mid) = entries[1], mid.id == 7,
              case .comment(let last) = entries[2], last.id == 2 else {
            Issue.record("wrong order: \(entries)")
            return
        }
    }

    @Test func sameStampOrdersById() {
        let entries = PRConversation.timeline(
            comments: [comment(9, at: "2026-08-19T12:00:00Z"),
                       comment(3, at: "2026-08-19T12:00:00Z")],
            reviews: [])
        guard case .comment(let first) = entries[0] else {
            Issue.record("expected comments"); return
        }
        #expect(first.id == 3)
    }

    @Test func commentPayloadCarriesViewerState() {
        var meta = ReviewCommentMeta(nodeID: "IC_1")
        meta.viewerReacted = ["heart"]
        meta.edited = true
        var rolled = comment(1, at: "2026-08-19T10:00:00Z", login: "sam-ortega")
        rolled.reactions = ReactionRollup(heart: 2)
        let payload = PRConversation.payload(
            comments: [rolled], reviews: [],
            commentMeta: [1: meta], viewer: "sam-ortega")
        #expect(payload.count == 1)
        #expect(payload[0].kind == "comment")
        #expect(payload[0].card.viewerOwned)
        #expect(payload[0].card.edited)
        #expect(payload[0].card.canReact)
        // No roster in the meta → no "who" tooltip, chips still carry
        // counts and the viewer's own tint.
        #expect(payload[0].card.reactions == [ReactionChipPayload(
            content: "heart", count: 2, mine: true, who: nil)])
    }

    @Test func botsAreTaggedAndMetalessCommentsDegrade() {
        let payload = PRConversation.payload(
            comments: [comment(1, at: "2026-08-19T10:00:00Z",
                               login: "docs-ci[bot]", type: "Bot")],
            reviews: [], commentMeta: [:], viewer: "sam-ortega")
        #expect(payload[0].card.bot)
        #expect(!payload[0].card.canReact)
        #expect(!payload[0].card.viewerOwned)
    }

    @Test func reviewCardsAreReadOnlyWithGraphQLChips() {
        var meta = ReviewCommentMeta(nodeID: "PRR_7")
        meta.viewerReacted = ["+1"]
        let payload = PRConversation.payload(
            comments: [],
            reviews: [review(7, state: "CHANGES_REQUESTED", body: "Needs a pass.",
                             at: "2026-08-19T11:00:00Z", login: "riley-chen")],
            commentMeta: [:],
            reviewMeta: [7: meta],
            reviewReactions: [7: ReactionRollup(plusOne: 3)],
            viewer: "riley-chen")
        #expect(payload[0].kind == "changes_requested")
        // Even the author's own review body renders read-only — editing
        // a review summary stays on GitHub (spec decision).
        #expect(!payload[0].card.viewerOwned)
        #expect(payload[0].card.canReact)
        #expect(payload[0].card.reactions.first?.count == 3)
        #expect(payload[0].card.reactions.first?.mine == true)
    }
}

@Suite struct IssueCommentDecodingTests {
    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    @Test func decodesRESTShape() throws {
        let json = Data("""
        [{
          "id": 314,
          "body": "Looks good overall.",
          "user": {"login": "docs-ci[bot]", "avatar_url": "https://avatars.example/u/1", "type": "Bot"},
          "created_at": "2026-08-19T10:00:00Z",
          "html_url": "https://github.com/o/r/pull/1#issuecomment-314",
          "reactions": {"+1": 2, "heart": 1}
        }]
        """.utf8)
        let comments = try decoder.decode([IssueComment].self, from: json)
        #expect(comments.count == 1)
        #expect(comments[0].id == 314)
        #expect(comments[0].user?.type == "Bot")
        #expect(comments[0].user?.avatarUrl?.absoluteString == "https://avatars.example/u/1")
        #expect(comments[0].reactions?.plusOne == 2)
        #expect(comments[0].reactions?.heart == 1)
    }

    @Test func reviewRowDecodesSubmittedAt() throws {
        let json = Data("""
        [{
          "id": 9, "node_id": "PRR_9",
          "user": {"login": "riley-chen", "avatar_url": "https://avatars.example/u/2"},
          "body": "", "state": "APPROVED", "commit_id": "abc",
          "submitted_at": "2026-08-19T11:00:00Z",
          "html_url": "https://github.com/o/r/pull/1#pullrequestreview-9"
        }]
        """.utf8)
        let reviews = try decoder.decode([PullRequestReview].self, from: json)
        #expect(reviews[0].submittedAt == "2026-08-19T11:00:00Z")
        #expect(reviews[0].user?.avatarUrl != nil)
    }
}

@Suite struct CockpitParserTests {
    /// A live-shaped page: null decision would be legal too — here
    /// REVIEW_REQUIRED, one opinion, one null requested reviewer (the
    /// code-owner/Copilot shape observed on cli/cli), one team request,
    /// a CheckRun + StatusContext mix, review meta, one comments page.
    private let fixture = Data("""
    {"data": {"repository": {"pullRequest": {
      "reviewDecision": "REVIEW_REQUIRED",
      "latestOpinionatedReviews": {"nodes": [
        {"state": "APPROVED", "submittedAt": "2026-08-18T09:00:00Z",
         "author": {"login": "riley-chen", "avatarUrl": "https://avatars.example/u/2"}},
        {"state": "DISMISSED", "submittedAt": "2026-08-17T09:00:00Z",
         "author": {"login": "gone", "avatarUrl": null}}
      ]},
      "reviewRequests": {"nodes": [
        {"requestedReviewer": null},
        {"requestedReviewer": {"__typename": "User", "login": "sam-ortega",
                               "avatarUrl": "https://avatars.example/u/3"}},
        {"requestedReviewer": {"__typename": "Team", "name": "docs-team", "avatarUrl": null}}
      ]},
      "statusCheckRollup": {"contexts": {"totalCount": 3, "nodes": [
        {"__typename": "CheckRun", "name": "build", "status": "COMPLETED",
         "conclusion": "SUCCESS", "detailsUrl": "https://github.com/o/r/runs/1",
         "startedAt": "2026-08-19T10:00:00Z", "completedAt": "2026-08-19T10:01:30Z",
         "isRequired": true,
         "checkSuite": {"workflowRun": {"workflow": {"name": "CI"}}, "app": {"name": "GitHub Actions"}}},
        {"__typename": "CheckRun", "name": "deploy", "status": "WAITING",
         "conclusion": null, "detailsUrl": null, "startedAt": null, "completedAt": null,
         "isRequired": false, "checkSuite": {"workflowRun": null, "app": {"name": "GitHub Actions"}}},
        {"__typename": "StatusContext", "context": "license/cla", "state": "SUCCESS",
         "targetUrl": "https://cla.example/check", "isRequired": false}
      ]}},
      "reviews": {"nodes": [
        {"id": "PRR_9", "databaseId": 9, "lastEditedAt": null,
         "reactionGroups": [{"content": "THUMBS_UP", "viewerHasReacted": true,
           "reactors": {"totalCount": 2, "nodes": [{"login": "sam-ortega"}, {"login": "riley-chen"}]}}]}
      ]},
      "comments": {
        "pageInfo": {"hasNextPage": true, "endCursor": "CURSOR1"},
        "nodes": [
          {"id": "IC_314", "databaseId": 314, "lastEditedAt": "2026-08-19T11:00:00Z",
           "reactionGroups": [{"content": "HEART", "viewerHasReacted": false,
             "reactors": {"totalCount": 1, "nodes": [{"login": "riley-chen"}]}}]}
        ]
      }
    }}}}
    """.utf8)

    @Test func parsesTheFullPage() throws {
        let page = try GitHubClient.parseCockpitPage(fixture)
        #expect(page.state.reviewDecision == .reviewRequired)
        // DISMISSED drops off the strip; the timeline still shows it.
        #expect(page.state.reviewers == [ReviewerState(
            login: "riley-chen",
            avatarUrl: URL(string: "https://avatars.example/u/2"),
            approved: true, submittedAt: "2026-08-18T09:00:00Z")])
        // The null requested-reviewer node is dropped, not fatal.
        #expect(page.state.reviewRequests.count == 2)
        #expect(page.state.reviewRequests[0] == ReviewRequestEntry(
            name: "sam-ortega", avatarUrl: URL(string: "https://avatars.example/u/3"),
            isTeam: false))
        #expect(page.state.reviewRequests[1].isTeam)
        #expect(page.state.checksTotal == 3)
        #expect(page.state.checks.count == 3)
        #expect(page.state.checks[0].state == .passed)
        #expect(page.state.checks[0].group == "CI")
        #expect(page.state.checks[0].isRequired)
        #expect(page.state.checks[0].durationLabel == "1m 30s")
        #expect(page.state.checks[1].state == .waiting)
        // No workflow run (gated) — the app name still groups the row.
        #expect(page.state.checks[1].group == "GitHub Actions")
        #expect(page.state.checks[2].state == .passed)
        #expect(page.state.checks[2].group == nil)
        #expect(page.nextCursor == "CURSOR1")
    }

    @Test func commentAndReviewMetaCarryViewerState() throws {
        let page = try GitHubClient.parseCockpitPage(fixture)
        let comment = try #require(page.commentMeta[314])
        #expect(comment.nodeID == "IC_314")
        #expect(comment.edited)
        #expect(comment.viewerReacted.isEmpty)
        #expect(comment.reactors["heart"]?.totalCount == 1)
        let review = try #require(page.reviewMeta[9])
        #expect(review.viewerReacted == ["+1"])
        // REST has no reaction rollup for review bodies — synthesized
        // from the GraphQL reactor totals.
        #expect(page.reviewReactions[9]?.plusOne == 2)
    }

    @Test func emptyAndShapelessPagesDegrade() throws {
        let empty = Data(#"{"data": {"repository": {"pullRequest": null}}}"#.utf8)
        let page = try GitHubClient.parseCockpitPage(empty)
        #expect(page.state == PRCockpitState())
        #expect(page.nextCursor == nil)
    }
}

@Suite struct CheckDisplayOrderTests {
    private func item(_ name: String, _ state: CheckItem.State) -> CheckItem {
        CheckItem(name: name, group: nil, state: state,
                  detailsUrl: nil, isRequired: false, durationLabel: nil)
    }

    @Test func failuresThenMovingThenAlphabetical() {
        let ordered = CheckItem.displayOrder([
            item("zeta-lint", .passed),
            item("build", .running),
            item("alpha-docs", .passed),
            item("deploy", .waiting),
            item("unit-tests", .failed),
            item("audit", .queued),
        ])
        #expect(ordered.map(\.name) ==
            ["unit-tests", "audit", "build", "deploy", "alpha-docs", "zeta-lint"])
    }
}
