import Foundation
import Testing
@testable import PullMark

@Suite struct ReviewControlTests {
    // MARK: - Morphing control label

    @Test func buttonLabelQuietWithNothingPending() {
        #expect(ReviewControl.buttonLabel(pendingCount: 0) == "Review changes")
    }

    @Test func buttonLabelMorphsWithPendingCount() {
        #expect(ReviewControl.buttonLabel(pendingCount: 1) == "Finish your review · 1")
        #expect(ReviewControl.buttonLabel(pendingCount: 12) == "Finish your review · 12")
    }

    @Test func headerLabelSpellsOutTheCount() {
        #expect(ReviewControl.headerLabel(pendingCount: 0) == "Review changes")
        #expect(ReviewControl.headerLabel(pendingCount: 1)
            == "Finish your review — 1 pending comment")
        #expect(ReviewControl.headerLabel(pendingCount: 3)
            == "Finish your review — 3 pending comments")
    }

    // MARK: - Verdict vocabulary (GitHub's casing, spec §3)

    @Test func verdictLabelsMatchGitHubCasing() {
        #expect(ReviewVerdict.comment.label == "Comment")
        #expect(ReviewVerdict.approve.label == "Approve")
        #expect(ReviewVerdict.requestChanges.label == "Request changes")
    }

    @Test func verdictOrderIsCommentFirst() {
        #expect(ReviewVerdict.allCases == [.comment, .approve, .requestChanges])
    }

    @Test func verdictRawValuesAreTheAPIEvents() {
        #expect(ReviewVerdict.comment.rawValue == "COMMENT")
        #expect(ReviewVerdict.approve.rawValue == "APPROVE")
        #expect(ReviewVerdict.requestChanges.rawValue == "REQUEST_CHANGES")
    }

    // MARK: - Own-PR gating

    @Test func ownPRWhenLoginsMatch() {
        #expect(ReviewControl.isOwnPR(viewer: "octocat", author: "octocat"))
    }

    @Test func ownPRLoginComparisonIsCaseInsensitive() {
        #expect(ReviewControl.isOwnPR(viewer: "OctoCat", author: "octocat"))
    }

    @Test func notOwnPRWhenLoginsDiffer() {
        #expect(!ReviewControl.isOwnPR(viewer: "octocat", author: "hubot"))
    }

    /// Identity unresolved (e.g. offline before the first success): verdicts
    /// stay enabled and the server 422 surfaces — never block on a check.
    @Test func nilViewerNeverReadsAsOwnPR() {
        #expect(!ReviewControl.isOwnPR(viewer: nil, author: "octocat"))
    }

    @Test func nilAuthorNeverReadsAsOwnPR() {
        #expect(!ReviewControl.isOwnPR(viewer: "octocat", author: nil))
    }

    @Test func ownPRDisablesApproveAndRequestChangesOnly() {
        #expect(ReviewControl.verdictSelectable(.comment, ownPR: true))
        #expect(!ReviewControl.verdictSelectable(.approve, ownPR: true))
        #expect(!ReviewControl.verdictSelectable(.requestChanges, ownPR: true))
    }

    @Test func foreignPRLeavesAllVerdictsSelectable() {
        for verdict in ReviewVerdict.allCases {
            #expect(ReviewControl.verdictSelectable(verdict, ownPR: false))
        }
    }

    // MARK: - Submit-enabled rules

    @Test func approveSubmitsEvenEmpty() {
        #expect(ReviewControl.submitEnabled(verdict: .approve, hasSummary: false,
                                            pendingCount: 0))
    }

    @Test func commentNeedsSummaryOrComments() {
        #expect(!ReviewControl.submitEnabled(verdict: .comment, hasSummary: false,
                                             pendingCount: 0))
        #expect(ReviewControl.submitEnabled(verdict: .comment, hasSummary: true,
                                            pendingCount: 0))
        #expect(ReviewControl.submitEnabled(verdict: .comment, hasSummary: false,
                                            pendingCount: 2))
    }

    @Test func requestChangesNeedsSummaryOrComments() {
        #expect(!ReviewControl.submitEnabled(verdict: .requestChanges, hasSummary: false,
                                             pendingCount: 0))
        #expect(ReviewControl.submitEnabled(verdict: .requestChanges, hasSummary: true,
                                            pendingCount: 0))
        #expect(ReviewControl.submitEnabled(verdict: .requestChanges, hasSummary: false,
                                            pendingCount: 1))
    }
}
