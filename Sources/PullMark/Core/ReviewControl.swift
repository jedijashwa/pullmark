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
        case .comment: return String(localized: "Comment")
        case .approve: return String(localized: "Approve")
        case .requestChanges: return String(localized: "Request changes")
        }
    }

    var help: String {
        switch self {
        case .comment: return String(localized: "Submit general feedback without explicit approval")
        case .approve: return String(localized: "Approve merging these changes")
        case .requestChanges: return String(localized: "Ask for changes before this can merge")
        }
    }
}

/// Pure decisions behind the morphing review control and its popover
/// (spec §3), kept out of the views so they stay unit-testable.
enum ReviewControl {
    /// The toolbar control is both the status and the entry point: quiet
    /// when nothing is pending, a call to finish when something is.
    static func buttonLabel(pendingCount: Int) -> String {
        pendingCount == 0
            ? String(localized: "Review changes")
            : String(localized: "Finish your review · \(pendingCount)")
    }

    /// The popover's header, spelling the count out in words.
    static func headerLabel(pendingCount: Int) -> String {
        if pendingCount == 0 { return String(localized: "Review changes") }
        return pendingCount == 1
            ? String(localized: "Finish your review — 1 pending comment")
            : String(localized: "Finish your review — \(pendingCount) pending comments")
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
        "GitHub doesn’t allow approving your own pull request or requesting changes on it."

    /// How much of the first hidden row stays visible when the list
    /// overflows: a resting clip that ends on a clean card edge reads as
    /// "that's everything", so the next row peeks under the fade instead.
    static let pendingListPeek: CGFloat = 12

    /// Visible height for the popover's pending-comment list, from each
    /// row's measured bottom edge (ascending, content coordinates): the
    /// exact content height when everything fits under the cap, else the
    /// largest whole-row boundary whose peek still fits — plus the peek,
    /// so the next row's top sliver shows and the clip reads as
    /// scrollable instead of slicing a row through its body text. A
    /// single row taller than the cap gets the cap (scrolling reaches
    /// the rest). Nil when nothing has been measured yet.
    static func pendingListHeight(rowBottoms: [CGFloat], cap: CGFloat,
                                  peek: CGFloat = ReviewControl.pendingListPeek) -> CGFloat? {
        guard let last = rowBottoms.last else { return nil }
        if last <= cap { return last }
        guard let boundary = rowBottoms.last(where: { $0 + peek <= cap }) else { return cap }
        return boundary + peek
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
