import SwiftUI

/// Capsule "attention" color: `Color.yellow` text on a light tint is
/// ~1.5:1 contrast (design-review catch) — GitHub's attention palette
/// pairs a pale yellow field with dark amber text, and so does this.
private let capsuleAmber = Color(nsColor: NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(red: 0.83, green: 0.65, blue: 0.17, alpha: 1)   // #D4A72C
        : NSColor(red: 0.60, green: 0.40, blue: 0.00, alpha: 1)   // #9A6700
})

/// The cockpit row in the PR overview header (spec: pr-cockpit):
/// review-decision capsule, checks capsule with its per-check popover,
/// and the reviewer strip. Renders nothing until the first cockpit
/// fetch lands — absence is honest, never a placeholder.
struct PRCockpitRow: View {
    let cockpit: PRCockpitState
    /// The PR's page on GitHub — the checks popover's footer link.
    let prURL: URL

    var body: some View {
        let summary = cockpit.checksSummary
        HStack(spacing: 8) {
            if let decision = cockpit.reviewDecision {
                ReviewDecisionCapsule(decision: decision)
            }
            if summary != .none {
                ChecksCapsule(summary: summary, checks: cockpit.checks,
                              checksTotal: cockpit.checksTotal, prURL: prURL)
            }
            ReviewerStrip(reviewers: cockpit.reviewers,
                          requests: cockpit.reviewRequests)
            Spacer(minLength: 0)
        }
        .font(.callout)
    }
}

// MARK: - Review decision

private struct ReviewDecisionCapsule: View {
    let decision: ReviewDecision

    var body: some View {
        Label(label, systemImage: symbol)
            .font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var label: String {
        switch decision {
        case .approved: return String(localized: "Approved")
        case .changesRequested: return String(localized: "Changes requested")
        case .reviewRequired: return String(localized: "Review required")
        }
    }

    private var symbol: String {
        switch decision {
        case .approved: return "checkmark.circle.fill"
        case .changesRequested: return "plusminus.circle.fill"
        case .reviewRequired: return "clock"
        }
    }

    private var color: Color {
        switch decision {
        case .approved: return .green
        case .changesRequested: return .red
        case .reviewRequired: return capsuleAmber
        }
    }
}

// MARK: - Checks capsule + popover

private struct ChecksCapsule: View {
    let summary: ChecksSummary
    let checks: [CheckItem]
    let checksTotal: Int
    let prURL: URL

    @State private var popoverVisible = false

    var body: some View {
        Button {
            popoverVisible = true
        } label: {
            HStack(spacing: 4) {
                if case .running = summary {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: symbol)
                }
                Text(label)
                // The capsule opens a popover and its inert neighbor
                // doesn't — the disclosure chevron earns the click
                // (the compare button's own idiom).
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(tint.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
        }
        .buttonStyle(.plain)
        .help(detail)
        .popover(isPresented: $popoverVisible, arrowEdge: .bottom) {
            ChecksPopover(checks: checks, checksTotal: checksTotal, prURL: prURL)
        }
    }

    private var label: String {
        switch summary {
        case .none: return ""
        case .failed: return String(localized: "Checks failed")
        case .running: return String(localized: "Checks running")
        case .awaitingApproval: return String(localized: "Checks awaiting approval")
        case .passed: return String(localized: "Checks passed")
        }
    }

    private var detail: String {
        switch summary {
        case .none: return ""
        case .failed(let failing, let total):
            return "\(failing) of \(total) failing"
        case .running(let done, let total):
            return "\(done) of \(total) done"
        case .awaitingApproval:
            return "A workflow is waiting for approval"
        case .passed(let passed, let skipped):
            return skipped > 0 ? "\(passed) passed, \(skipped) skipped"
                               : "\(passed) passed"
        }
    }

    private var symbol: String {
        switch summary {
        case .failed: return "xmark.circle.fill"
        case .passed: return "checkmark.circle.fill"
        case .awaitingApproval: return "hourglass"
        case .none, .running: return "circle"
        }
    }

    private var color: Color {
        switch summary {
        case .failed: return .red
        case .running: return capsuleAmber
        case .awaitingApproval: return .gray
        case .passed: return .green
        case .none: return .secondary
        }
    }

    /// The capsule field keeps the familiar hue even where the text
    /// needed the darker amber — amber at 18% reads muddy.
    private var tint: Color {
        if case .running = summary { return .yellow }
        return color
    }
}

private struct ChecksPopover: View {
    let checks: [CheckItem]
    let checksTotal: Int
    let prURL: URL

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(CheckItem.displayOrder(checks)) { check in
                        CheckRow(check: check)
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 320)
            Divider()
            HStack {
                if checksTotal > checks.count {
                    Text("and \(checksTotal - checks.count) more")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Link("View all checks on GitHub",
                     destination: prURL.appendingPathComponent("checks"))
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(minWidth: 340)
    }
}

private struct CheckRow: View {
    let check: CheckItem

    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            if let url = check.detailsUrl { openURL(url) }
        } label: {
            HStack(spacing: 8) {
                stateIcon
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(check.name)
                        .lineLimit(1)
                    if let group = check.group {
                        Text(group)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 12)
                if check.isRequired {
                    Text("Required")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                if let duration = check.durationLabel {
                    Text(duration)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .background(hovering && check.detailsUrl != nil
                        ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 5))
        .help(check.detailsUrl == nil ? "" : "Open on GitHub")
    }

    @State private var hovering = false

    @ViewBuilder private var stateIcon: some View {
        switch check.state {
        case .passed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .running:
            ProgressView().controlSize(.small).scaleEffect(0.7)
        case .queued:
            Image(systemName: "clock").foregroundStyle(.yellow)
        case .waiting:
            Image(systemName: "hourglass").foregroundStyle(.secondary)
        case .skipped:
            Image(systemName: "slash.circle").foregroundStyle(.secondary)
        case .neutral:
            Image(systemName: "minus.circle").foregroundStyle(.secondary)
        }
    }
}

// MARK: - Reviewer strip

private struct ReviewerStrip: View {
    let reviewers: [ReviewerState]
    let requests: [ReviewRequestEntry]

    /// Avatars shown before folding into "+N" — the strip answers "who
    /// approved, who blocked, who's awaited," not "everyone ever."
    private static let capacity = 8

    var body: some View {
        let shownReviewers = Array(reviewers.prefix(Self.capacity))
        let shownRequests = Array(requests.prefix(max(0, Self.capacity - shownReviewers.count)))
        let overflow = (reviewers.count - shownReviewers.count)
            + (requests.count - shownRequests.count)
        HStack(spacing: 4) {
            ForEach(shownReviewers) { reviewer in
                CockpitAvatar(name: reviewer.login, url: reviewer.avatarUrl)
                    .overlay(alignment: .bottomTrailing) {
                        StateBadge(approved: reviewer.approved)
                    }
                    .help(reviewerHelp(reviewer))
                    // The strip's whole point — who approved, who
                    // blocked — must reach VoiceOver, not just color.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(reviewer.login), \(reviewer.approved ? "approved" : "requested changes")")
            }
            ForEach(shownRequests) { request in
                if request.isTeam {
                    TeamChip(name: request.name)
                        .help("Review requested from \(request.name)")
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(request.name) team, review requested")
                } else {
                    CockpitAvatar(name: request.name, url: request.avatarUrl)
                        .opacity(0.45)
                        .overlay(alignment: .bottomTrailing) {
                            AwaitingBadge()
                        }
                        .help("Awaiting review from \(request.name)")
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(request.name), awaiting review")
                }
            }
            if overflow > 0 {
                Text("+\(overflow)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(overflow == 1
                        ? Text("1 more reviewer") : Text("\(overflow) more reviewers"))
            }
        }
    }

    private func reviewerHelp(_ reviewer: ReviewerState) -> String {
        guard let date = GitHubDate.parse(reviewer.submittedAt) else {
            return reviewer.approved
                ? String(localized: "\(reviewer.login) approved")
                : String(localized: "\(reviewer.login) requested changes")
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let when = formatter.localizedString(for: date, relativeTo: Date())
        return reviewer.approved
            ? String(localized: "\(reviewer.login) approved \(when)")
            : String(localized: "\(reviewer.login) requested changes \(when)")
    }
}

private struct StateBadge: View {
    let approved: Bool

    var body: some View {
        Image(systemName: approved ? "checkmark.circle.fill" : "plusminus.circle.fill")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(approved ? Color.green : Color.red)
            .background(Circle().fill(Color(nsColor: .windowBackgroundColor))
                .frame(width: 11, height: 11))
            .offset(x: 2, y: 2)
    }
}

private struct AwaitingBadge: View {
    var body: some View {
        // A solid pending dot — GitHub's own marker; the dotted ring
        // read as a broken image at badge size (design-review catch).
        Image(systemName: "circle.fill")
            .font(.system(size: 7, weight: .bold))
            .foregroundStyle(capsuleAmber)
            .background(Circle().fill(Color(nsColor: .windowBackgroundColor))
                .frame(width: 11, height: 11))
            .offset(x: 2, y: 2)
    }
}

private struct TeamChip: View {
    let name: String

    var body: some View {
        Label(name, systemImage: "person.2")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
            .opacity(0.8)
    }
}

/// Avatar with the app's standard fallback: remote image when a URL is
/// on hand (demo mode routes data-URIs through the same pipeline),
/// else the deterministic initials circle (same hash → same hue as the
/// page's blame initials). Fetches ride an ephemeral session by
/// standing policy — AsyncImage would write real reviewers' avatars
/// into the shared on-disk URLCache (code-review catch).
private struct CockpitAvatar: View {
    let name: String
    let url: URL?

    @State private var image: NSImage?

    private static let session = URLSession(configuration: .ephemeral)

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                initials
            }
        }
        .frame(width: 22, height: 22)
        .clipShape(Circle())
        .task(id: url) {
            guard let url else { image = nil; return }
            let data = try? await Self.session.data(from: url).0
            image = data.flatMap(NSImage.init(data:))
        }
    }

    private var initials: some View {
        var hash: UInt32 = 0
        for scalar in name.unicodeScalars {
            hash = hash &* 31 &+ scalar.value
        }
        return ZStack {
            Circle().fill(Color(hue: Double(hash % 360) / 360, saturation: 0.45, brightness: 0.55))
            Text(String(name.prefix(1)).uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
        }
    }
}
