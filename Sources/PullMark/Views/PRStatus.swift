import SwiftUI

/// GitHub-style pull request lifecycle states, plus `deleted` for PRs that
/// can no longer be fetched (repo removed or access lost).
enum PRStatus: String, Codable, CaseIterable {
    case draft
    case open
    case closed
    case merged
    case deleted

    init(details: PullRequestDetails) {
        if details.merged == true {
            self = .merged
        } else if details.state == "closed" {
            self = .closed
        } else if details.draft == true {
            self = .draft
        } else {
            self = .open
        }
    }

    var label: String {
        switch self {
        case .draft: return String(localized: "Draft")
        // Distinct key from the "Open" ACTION buttons: this is the PR
        // state, an adjective — German needs "Offen" here but "Öffnen"
        // there, and sharing one key made the chip conjugate wrong
        // (same collision ja carried as 開く). English falls back to
        // the value since there is no en.lproj.
        case .open: return NSLocalizedString("pr-status-open", value: "Open", comment: "PR state chip: the pull request is open")
        case .closed: return String(localized: "Closed")
        case .merged: return String(localized: "Merged")
        case .deleted: return String(localized: "Unavailable")
        }
    }

    var systemImage: String {
        switch self {
        case .draft, .open: return "arrow.triangle.pull"
        case .merged: return "arrow.triangle.merge"
        case .closed: return "xmark.circle"
        case .deleted: return "trash"
        }
    }

    var color: Color {
        switch self {
        case .draft: return .gray
        case .open: return .green
        case .merged: return .purple
        case .closed: return .red
        case .deleted: return .secondary
        }
    }
}
