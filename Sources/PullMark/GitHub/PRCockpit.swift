import Foundation

// MARK: - Review state (spec: pr-cockpit)

/// GitHub's standing verdict on a pull request (GraphQL
/// `reviewDecision`). The API returns null on repos with no
/// required-review rule and no standing opinion — the header renders
/// nothing for null rather than inventing a state.
enum ReviewDecision: String, Equatable {
    case approved = "APPROVED"
    case changesRequested = "CHANGES_REQUESTED"
    case reviewRequired = "REVIEW_REQUIRED"
}

/// One reviewer's standing opinion (GraphQL `latestOpinionatedReviews`
/// — one row per user, APPROVED or CHANGES_REQUESTED only).
struct ReviewerState: Equatable, Identifiable {
    let login: String
    let avatarUrl: URL?
    let approved: Bool
    /// ISO-8601 submission stamp for the tooltip's relative time.
    let submittedAt: String?

    var id: String { login }
}

/// An outstanding review request. Requested-reviewer nodes can be null
/// in live data (code-owner and Copilot rows) — the parser drops those
/// rather than failing the query.
struct ReviewRequestEntry: Equatable, Identifiable {
    let name: String
    let avatarUrl: URL?
    let isTeam: Bool

    var id: String { name }
}

// MARK: - Checks

/// One CI row on the head commit — a CheckRun or a commit
/// StatusContext, normalized to a single display taxonomy.
struct CheckItem: Equatable, Identifiable {
    /// Row taxonomy; also the capsule classifier's input. `waiting` is
    /// the deployment-approval gate — never "running" (spec rule: a
    /// gate that can sit for days must not read as activity).
    enum State: Equatable {
        case passed
        case failed
        case running
        case queued
        case waiting
        case skipped
        case neutral
    }

    let name: String
    /// Workflow (or app) name for CheckRuns; nil for plain statuses.
    let group: String?
    let state: State
    /// CheckRun `detailsUrl` / StatusContext `targetUrl` — the log link.
    let detailsUrl: URL?
    let isRequired: Bool
    /// "1m 23s" from startedAt/completedAt; nil while unfinished.
    let durationLabel: String?

    var id: String { (group.map { "\($0)/" } ?? "") + name }

    /// CheckRun mapping: conclusion decides for COMPLETED runs, status
    /// for everything still moving. Unknown future enum members land on
    /// `neutral` — a gray row, never a crash or a false "failed".
    static func state(status: String?, conclusion: String?) -> State {
        switch conclusion {
        case "SUCCESS": return .passed
        case "FAILURE", "TIMED_OUT", "CANCELLED", "STARTUP_FAILURE", "ACTION_REQUIRED":
            return .failed
        case "SKIPPED": return .skipped
        case "NEUTRAL", "STALE": return .neutral
        default: break
        }
        switch status {
        case "IN_PROGRESS": return .running
        case "QUEUED", "PENDING", "REQUESTED": return .queued
        case "WAITING": return .waiting
        default: return .neutral
        }
    }

    /// StatusContext mapping. External CI has no queued/running
    /// distinction — PENDING reads as queued. EXPECTED is a required
    /// context that never reported.
    static func state(contextState: String?) -> State {
        switch contextState {
        case "SUCCESS": return .passed
        case "FAILURE", "ERROR": return .failed
        case "PENDING", "EXPECTED": return .queued
        default: return .neutral
        }
    }

    /// "58s" / "3m 12s" / "1h 4m" between two ISO-8601 stamps.
    static func durationLabel(startedAt: String?, completedAt: String?) -> String? {
        guard let startedAt, let completedAt,
              let start = GitHubDate.parse(startedAt),
              let end = GitHubDate.parse(completedAt) else { return nil }
        let seconds = Int(end.timeIntervalSince(start).rounded())
        guard seconds >= 0 else { return nil }
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m \(seconds % 60)s" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }
}

/// The checks capsule, derived from the rows. Precedence: failed >
/// running > awaiting approval > passed — and no contexts at all means
/// NO capsule: repos without CI and fork PRs whose workflows await
/// approval both present an empty rollup, and "passed" would be a lie.
enum ChecksSummary: Equatable {
    case none
    case failed(failing: Int, total: Int)
    case running(done: Int, total: Int)
    case awaitingApproval
    case passed(passed: Int, skipped: Int)

    static func classify(_ checks: [CheckItem]) -> ChecksSummary {
        guard !checks.isEmpty else { return .none }
        let failing = checks.filter { $0.state == .failed }.count
        if failing > 0 { return .failed(failing: failing, total: checks.count) }
        let moving = checks.filter { $0.state == .running || $0.state == .queued }.count
        if moving > 0 {
            return .running(done: checks.count - moving, total: checks.count)
        }
        if checks.contains(where: { $0.state == .waiting }) { return .awaitingApproval }
        let skipped = checks.filter { $0.state == .skipped }.count
        return .passed(passed: checks.count - skipped, skipped: skipped)
    }
}

extension CheckItem {
    /// Popover order: failures first, then whatever is still moving,
    /// then the rest — alphabetical within each band (GitHub's own
    /// grouping order, flattened).
    static func displayOrder(_ items: [CheckItem]) -> [CheckItem] {
        func rank(_ state: State) -> Int {
            switch state {
            case .failed: return 0
            case .running, .queued: return 1
            case .waiting: return 2
            case .passed, .skipped, .neutral: return 3
            }
        }
        return items.sorted {
            (rank($0.state), $0.name.lowercased(), $0.name)
                < (rank($1.state), $1.name.lowercased(), $1.name)
        }
    }
}

/// Everything the overview header shows about where the PR stands.
struct PRCockpitState: Equatable {
    var reviewDecision: ReviewDecision?
    var reviewers: [ReviewerState] = []
    var reviewRequests: [ReviewRequestEntry] = []
    var checks: [CheckItem] = []
    /// True context count on the head commit; the query fetches 50 —
    /// the popover footer says "and N more on GitHub" past that.
    var checksTotal: Int = 0
}

// MARK: - Conversation timeline

/// Shared ISO-8601 parsing for GitHub timestamps ("…T12:00:00Z").
enum GitHubDate {
    private static let parser = ISO8601DateFormatter()
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    static func parse(_ iso: String?) -> Date? {
        guard let iso else { return nil }
        return parser.date(from: iso)
    }

    /// "Jul 18, 2026" from an ISO stamp, or empty.
    static func dayLabel(_ iso: String?) -> String {
        guard let date = parse(iso) else { return "" }
        return dayFormatter.string(from: date)
    }
}

/// The PR conversation timeline: issue comments interleaved with
/// submitted review verdicts, chronological, with the noise filtered
/// (spec: pr-cockpit). Pure assembly; the overview page renders it.
enum PRConversation {
    enum Entry: Equatable {
        case comment(IssueComment)
        case review(PullRequestReview)

        var sortStamp: String {
            switch self {
            case .comment(let comment): return comment.createdAt ?? ""
            case .review(let review): return review.submittedAt ?? ""
            }
        }
    }

    /// A review earns a timeline card when it says something: every
    /// APPROVED / CHANGES_REQUESTED / DISMISSED, but COMMENTED only
    /// with a non-empty body — inline-only submissions generate one
    /// empty COMMENTED row each (3–5 per PR observed live), and an
    /// unfiltered timeline is mostly blank cards. PENDING is the
    /// viewer's own unsubmitted review; the popover owns it.
    static func includesReview(state: String, body: String?) -> Bool {
        switch state {
        case "APPROVED", "CHANGES_REQUESTED", "DISMISSED": return true
        case "COMMENTED":
            let trimmed = body?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false
        default: return false
        }
    }

    /// GitHub's ISO stamps share one format, so the lexicographic sort
    /// is the chronological one; ids tie-break so same-second entries
    /// keep a stable order across refreshes.
    static func timeline(comments: [IssueComment],
                         reviews: [PullRequestReview]) -> [Entry] {
        var entries: [(Entry, String, Int)] =
            comments.map { (.comment($0), $0.createdAt ?? "", $0.id) }
        entries.append(contentsOf: reviews
            .filter { includesReview(state: $0.state, body: $0.body) }
            .map { (.review($0), $0.submittedAt ?? "", $0.id) })
        return entries
            .sorted { ($0.1, $0.2) < ($1.1, $1.2) }
            .map(\.0)
    }
}

/// One rendered timeline card. `kind` is "comment" or the review
/// verdict lowercased ("approved" / "changes_requested" / "dismissed"
/// / "commented") — the page builds the verdict headline from it.
struct ConversationEntryPayload: Encodable, Equatable {
    let kind: String
    let card: CommentPayload
}

extension PRConversation {
    /// Payload assembly with viewer-relative state. `commentMeta` keys
    /// issue-comment ids; `reviewMeta`/`reviewReactions` key review ids
    /// (REST has no reaction data for review bodies — both counts and
    /// viewer state come from GraphQL). Review cards render read-only
    /// bodies (editing a review summary stays on GitHub) but keep
    /// reaction chips.
    static func payload(comments: [IssueComment],
                        reviews: [PullRequestReview],
                        commentMeta: [Int: ReviewCommentMeta],
                        reviewMeta: [Int: ReviewCommentMeta] = [:],
                        reviewReactions: [Int: ReactionRollup] = [:],
                        viewer: String?) -> [ConversationEntryPayload] {
        timeline(comments: comments, reviews: reviews).map { entry in
            switch entry {
            case .comment(let comment):
                return ConversationEntryPayload(
                    kind: "comment",
                    card: CommentPayload(comment, meta: commentMeta[comment.id],
                                         viewer: viewer))
            case .review(let review):
                let meta = reviewMeta[review.id]
                var card = CommentPayload(
                    author: review.user?.login ?? "unknown",
                    dateLabel: GitHubDate.dayLabel(review.submittedAt),
                    body: review.body ?? "")
                card.id = review.id
                card.avatarUrl = review.user?.avatarUrl?.absoluteString
                card.canReact = viewer != nil && meta != nil
                card.reactions = CommentReactions.chips(
                    rollup: reviewReactions[review.id],
                    viewerReacted: meta?.viewerReacted ?? [],
                    reactors: meta?.reactors ?? [:],
                    viewer: viewer)
                return ConversationEntryPayload(kind: review.state.lowercased(),
                                                card: card)
            }
        }
    }
}

extension CommentPayload {
    /// An issue comment enriched with viewer-relative state — the
    /// conversation twin of the ReviewComment initializer above it in
    /// ReviewThreads.swift; nil meta degrades to counts-only chips.
    init(_ comment: IssueComment, meta: ReviewCommentMeta?, viewer: String?) {
        self.init(author: comment.user?.login ?? "unknown",
                  dateLabel: GitHubDate.dayLabel(comment.createdAt),
                  body: comment.body ?? "")
        id = comment.id
        edited = meta?.edited ?? false
        viewerOwned = CommentAuthorship.viewerOwns(author: comment.user?.login,
                                                   viewer: viewer)
        canReact = viewer != nil && meta != nil
        bot = comment.user?.type == "Bot"
        avatarUrl = comment.user?.avatarUrl?.absoluteString
        reactions = CommentReactions.chips(rollup: comment.reactions,
                                           viewerReacted: meta?.viewerReacted ?? [],
                                           reactors: meta?.reactors ?? [:],
                                           viewer: viewer)
    }
}
