import Foundation

/// The three review verdicts GitHub accepts, in the popover's display
/// order. Raw values are the REST `event` strings; labels use GitHub's
/// own casing verbatim (spec §3).
enum ReviewVerdict: String, CaseIterable, Identifiable {
    case comment = "COMMENT"
    case approve = "APPROVE"
    case requestChanges = "REQUEST_CHANGES"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .comment: return "Comment"
        case .approve: return "Approve"
        case .requestChanges: return "Request changes"
        }
    }

    var help: String {
        switch self {
        case .comment: return "Submit general feedback without explicit approval"
        case .approve: return "Approve merging these changes"
        case .requestChanges: return "Ask for changes before this can merge"
        }
    }
}

/// Pure decisions behind the morphing review control and its popover
/// (spec §3), kept out of the views so they stay unit-testable.
enum ReviewControl {
    /// The toolbar control is both the status and the entry point: quiet
    /// when nothing is pending, a call to finish when something is.
    static func buttonLabel(pendingCount: Int) -> String {
        pendingCount == 0 ? "Review changes" : "Finish your review · \(pendingCount)"
    }

    /// The popover's header, spelling the count out in words.
    static func headerLabel(pendingCount: Int) -> String {
        pendingCount == 0
            ? "Review changes"
            : "Finish your review — \(pendingCount) pending comment\(pendingCount == 1 ? "" : "s")"
    }

    /// True only when both logins are known and match. A nil viewer
    /// (identity never resolved — e.g. offline before the first success)
    /// deliberately reads as NOT own: the verdicts stay enabled and the
    /// server's 422 surfaces, rather than blocking on a network check.
    /// GitHub logins are case-insensitive.
    static func isOwnPR(viewer: String?, author: String?) -> Bool {
        guard let viewer, let author else { return false }
        return viewer.caseInsensitiveCompare(author) == .orderedSame
    }

    /// GitHub 422s both APPROVE and REQUEST_CHANGES on the author's own
    /// pull request (verified verbatim); only Comment remains selectable.
    static func verdictSelectable(_ verdict: ReviewVerdict, ownPR: Bool) -> Bool {
        verdict == .comment || !ownPR
    }

    /// One shared inline reason for both disabled options.
    static let ownPRRestrictionReason =
        "GitHub doesn't allow approving your own pull request or requesting changes on it."

    /// Visible height for the popover's pending-comment list, from each
    /// row's measured bottom edge (ascending, content coordinates): the
    /// exact content height when everything fits under the cap, else the
    /// largest whole-row boundary that does — the list never ends by
    /// slicing a row through its body text. A single row taller than the
    /// cap gets the cap (scrolling reaches the rest). Nil when nothing
    /// has been measured yet.
    static func pendingListHeight(rowBottoms: [CGFloat], cap: CGFloat) -> CGFloat? {
        guard let last = rowBottoms.last else { return nil }
        if last <= cap { return last }
        return rowBottoms.last(where: { $0 <= cap }) ?? cap
    }

    /// GitHub rejects a COMMENT or REQUEST_CHANGES review that carries
    /// neither a body nor comments; Approve stands on its own.
    static func submitEnabled(verdict: ReviewVerdict, hasSummary: Bool,
                              pendingCount: Int) -> Bool {
        switch verdict {
        case .approve:
            return true
        case .comment, .requestChanges:
            return hasSummary || pendingCount > 0
        }
    }
}
