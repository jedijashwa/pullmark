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

    // MARK: - Pending-list whole-row-plus-peek sizing

    @Test func pendingListUnmeasuredHasNoHeight() {
        #expect(ReviewControl.pendingListHeight(rowBottoms: [], cap: 180) == nil)
    }

    /// Everything visible: exact content height, no peek — there is
    /// nothing below the fold to advertise.
    @Test func pendingListFitsExactlyWhenUnderTheCap() {
        #expect(ReviewControl.pendingListHeight(rowBottoms: [60, 126], cap: 180) == 126)
        #expect(ReviewControl.pendingListHeight(rowBottoms: [60, 126, 180], cap: 180) == 180)
    }

    /// The live-verified defect: three rows at ~66pt each overflow a
    /// 180pt cap, and the list must end on the second row's boundary —
    /// never slicing the third mid-body — plus the peek, so the third
    /// row's top sliver signals there is more to scroll.
    @Test func pendingListSnapsToTheLastWholeRowPlusPeek() {
        #expect(ReviewControl.pendingListHeight(rowBottoms: [66, 132, 198], cap: 180) == 144)
        #expect(ReviewControl.pendingListHeight(rowBottoms: [50, 100, 150, 200, 250],
                                                cap: 180) == 162)
    }

    /// A boundary that fits alone but not with its peek steps back to the
    /// previous row — the peek must never be squeezed out.
    @Test func pendingListPeekAlwaysFitsUnderTheCap() {
        #expect(ReviewControl.pendingListHeight(rowBottoms: [60, 175, 240], cap: 180) == 72)
        #expect(ReviewControl.pendingListHeight(rowBottoms: [66, 132, 260], cap: 200,
                                                peek: 80) == 146)
    }

    @Test func pendingListSingleOversizeRowGetsTheCap() {
        #expect(ReviewControl.pendingListHeight(rowBottoms: [240], cap: 180) == 180)
        #expect(ReviewControl.pendingListHeight(rowBottoms: [240, 300], cap: 180) == 180)
        // First boundary too deep for boundary+peek: cap, not a negative
        // or zero height.
        #expect(ReviewControl.pendingListHeight(rowBottoms: [175, 350], cap: 180) == 180)
    }

    @Test func pendingListPeekDefaultIsTwelvePoints() {
        #expect(ReviewControl.pendingListPeek == 12)
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
