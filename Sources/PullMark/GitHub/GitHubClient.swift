import Foundation

@MainActor
final class GitHubClient {
    static let shared = GitHubClient()

    struct APIError: LocalizedError {
        let status: Int
        let message: String
        var errorDescription: String? { "GitHub API error (\(status)): \(message)" }
    }

    private var cachedToken: String?
    private var tokenResolved = false
    /// Cached only on success — a transient resolution failure must retry
    /// on the next call, never latch into "no viewer" for the whole
    /// session (that silently disabled pending-review adoption).
    private var cachedViewer: ViewerIdentity?
    /// Ephemeral so no repo content or API response is ever cached to disk —
    /// everything fetched lives in memory only.
    private let session = URLSession(configuration: .ephemeral)

    private nonisolated static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    private nonisolated static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }

    // MARK: - Auth

    func authToken() async -> String? {
        // Demo mode never resolves credentials: no subprocess, no token,
        // and every auth-gated path reads as cleanly unauthenticated.
        if DemoMode.active { return nil }
        if !tokenResolved {
            cachedToken = await Task.detached(priority: .userInitiated) {
                SystemGitCredentials.resolveToken()
            }.value
            tokenResolved = true
        }
        return cachedToken
    }

    // MARK: - Endpoints

    func pullRequest(_ ref: PullRequestRef) async throws -> PullRequestDetails {
        let data = try await request("GET", "/repos/\(ref.owner)/\(ref.repo)/pulls/\(ref.number)")
        return try Self.decoder.decode(PullRequestDetails.self, from: data)
    }

    func files(_ ref: PullRequestRef) async throws -> [PullRequestFile] {
        // 30 pages × 100 = 3,000 files — the PR files API's own hard limit,
        // so pagination can never silently drop anything the API would list.
        var all: [PullRequestFile] = []
        for page in 1...30 {
            let data = try await request("GET", "/repos/\(ref.owner)/\(ref.repo)/pulls/\(ref.number)/files",
                                         query: [URLQueryItem(name: "per_page", value: "100"),
                                                 URLQueryItem(name: "page", value: "\(page)")])
            let batch = try Self.decoder.decode([PullRequestFile].self, from: data)
            all.append(contentsOf: batch)
            if batch.count < 100 { break }
        }
        return all
    }

    /// The PR files API diffs against the merge base (three-dot diff), not the
    /// base branch tip, so old-file contents must come from the merge base too.
    func mergeBaseSHA(_ ref: PullRequestRef, base: String, head: String) async throws -> String {
        struct Compare: Decodable {
            struct Commit: Decodable { let sha: String }
            let mergeBaseCommit: Commit
        }
        let data = try await request("GET", "/repos/\(ref.owner)/\(ref.repo)/compare/\(base)...\(head)",
                                     query: [URLQueryItem(name: "per_page", value: "1")])
        return try Self.decoder.decode(Compare.self, from: data).mergeBaseCommit.sha
    }

    func fileContent(_ ref: PullRequestRef, path: String, at sha: String) async throws -> String {
        let data = try await fileData(ref, path: path, at: sha)
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Raw bytes of a repo file (used for images referenced by PR Markdown).
    func fileData(_ ref: PullRequestRef, path: String, at sha: String) async throws -> Data {
        // Demo mode serves the fixture texts; anything unknown surfaces
        // the same error shape a real 404 would.
        if DemoMode.active {
            guard let text = DemoSession.fileContent(path: path, at: sha) else {
                throw APIError(status: 404, message: "No demo content for \(path)")
            }
            return Data(text.utf8)
        }
        return try await request("GET", "/repos/\(ref.owner)/\(ref.repo)/contents/\(path)",
                                 query: [URLQueryItem(name: "ref", value: sha)],
                                 accept: "application/vnd.github.raw+json")
    }

    // MARK: - Repo browsing (GitHub Markdown links; ref.number is 0 here)

    /// Commit SHA a branch, tag, or SHA-ish string resolves to right now —
    /// remote docs pin to this at open time so the provenance display and a
    /// later reload can detect that the friendly ref moved.
    func commitSHA(_ ref: PullRequestRef, atRef refName: String) async throws -> String {
        struct Commit: Decodable { let sha: String }
        let data = try await request("GET", "/repos/\(ref.owner)/\(ref.repo)/commits/\(refName)")
        return try Self.decoder.decode(Commit.self, from: data).sha
    }

    func defaultBranch(_ ref: PullRequestRef) async throws -> String {
        struct Repo: Decodable { let defaultBranch: String }
        let data = try await request("GET", "/repos/\(ref.owner)/\(ref.repo)")
        return try Self.decoder.decode(Repo.self, from: data).defaultBranch
    }

    /// Branch names for the compare picker (first 300 by API order —
    /// enough for a picker; not a completeness-critical listing).
    func branchNames(_ ref: PullRequestRef) async throws -> [String] {
        struct Branch: Decodable { let name: String }
        var all: [String] = []
        for page in 1...3 {
            let data = try await request("GET", "/repos/\(ref.owner)/\(ref.repo)/branches",
                                         query: [URLQueryItem(name: "per_page", value: "100"),
                                                 URLQueryItem(name: "page", value: "\(page)")])
            let batch = try Self.decoder.decode([Branch].self, from: data)
            all.append(contentsOf: batch.map(\.name))
            if batch.count < 100 { break }
        }
        return all
    }

    /// Markdown file paths in the repo tree at a commit, for the sidebar
    /// tree. One recursive Trees API call; GitHub truncates giant repos
    /// (~100k entries) and says so — surfaced so the UI never presents a
    /// truncated tree as complete.
    func markdownTreePaths(_ ref: PullRequestRef, at sha: String) async throws -> (paths: [String], truncated: Bool) {
        struct Tree: Decodable {
            struct Entry: Decodable {
                let path: String
                let type: String
            }
            let tree: [Entry]
            let truncated: Bool
        }
        let data = try await request("GET", "/repos/\(ref.owner)/\(ref.repo)/git/trees/\(sha)",
                                     query: [URLQueryItem(name: "recursive", value: "1")])
        let tree = try Self.decoder.decode(Tree.self, from: data)
        let paths = tree.tree.filter {
            $0.type == "blob" && MarkdownFileType.matches(($0.path as NSString).pathExtension)
        }.map(\.path)
        return (paths, tree.truncated)
    }

    func reviewComments(_ ref: PullRequestRef) async throws -> [ReviewComment] {
        var all: [ReviewComment] = []
        for page in 1...30 {
            let data = try await request("GET", "/repos/\(ref.owner)/\(ref.repo)/pulls/\(ref.number)/comments",
                                         query: [URLQueryItem(name: "per_page", value: "100"),
                                                 URLQueryItem(name: "page", value: "\(page)")])
            let batch = try Self.decoder.decode([ReviewComment].self, from: data)
            all.append(contentsOf: batch)
            if batch.count < 100 { break }
        }
        return all
    }

    /// Resolution state and GraphQL node id per thread, keyed by the thread's
    /// root comment id (REST databaseId), plus per-comment viewer state
    /// (reactionGroups.viewerHasReacted, lastEditedAt, comment node ids) —
    /// all GraphQL-only signals REST cannot provide.
    func reviewThreadMeta(_ ref: PullRequestRef) async throws -> [Int: ThreadMeta] {
        let query = """
        query($owner: String!, $repo: String!, $number: Int!, $after: String) {
          repository(owner: $owner, name: $repo) {
            pullRequest(number: $number) {
              reviewThreads(first: 100, after: $after) {
                pageInfo { hasNextPage endCursor }
                nodes {
                  id isResolved
                  comments(first: 100) {
                    nodes {
                      id databaseId lastEditedAt
                      reactionGroups {
                        content viewerHasReacted
                        reactors(first: 10) {
                          totalCount
                          nodes {
                            ... on User { login }
                            ... on Bot { login }
                            ... on Organization { login }
                            ... on Mannequin { login }
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }
        """
        var meta: [Int: ThreadMeta] = [:]
        var cursor: String?
        // Cursor pagination so PRs with more than 100 review threads keep
        // their resolution state; 30 pages bounds a pathological PR.
        for _ in 1...30 {
            var variables: [String: Any] = ["owner": ref.owner, "repo": ref.repo, "number": ref.number]
            if let cursor { variables["after"] = cursor }
            let data = try await graphQL(query, variables: variables)
            let page = try Self.parseThreadMetaPage(data)
            meta.merge(page.meta) { _, new in new }
            guard let next = page.nextCursor else { break }
            cursor = next
        }
        return meta
    }

    /// One page of the thread-meta query. A thread's comments cap at 100
    /// per page (a longer thread degrades to counts-only chips for the
    /// tail, never a failure).
    nonisolated static func parseThreadMetaPage(_ data: Data) throws
        -> (meta: [Int: ThreadMeta], nextCursor: String?) {
        struct Response: Decodable {
            struct DataBox: Decodable { let repository: Repo? }
            struct Repo: Decodable { let pullRequest: PR? }
            struct PR: Decodable { let reviewThreads: Threads }
            struct Threads: Decodable {
                let pageInfo: PageInfo
                let nodes: [Node]
            }
            struct PageInfo: Decodable {
                let hasNextPage: Bool
                let endCursor: String?
            }
            struct Node: Decodable {
                let id: String
                let isResolved: Bool
                let comments: Comments
            }
            struct Comments: Decodable { let nodes: [Comment] }
            struct Comment: Decodable {
                struct ReactionGroup: Decodable {
                    struct Reactors: Decodable {
                        struct Node: Decodable { let login: String? }
                        let totalCount: Int
                        let nodes: [Node]?
                    }
                    let content: String
                    let viewerHasReacted: Bool
                    let reactors: Reactors?
                }
                let id: String
                let databaseId: Int?
                let lastEditedAt: String?
                let reactionGroups: [ReactionGroup]?
            }
            let data: DataBox?
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard let threads = response.data?.repository?.pullRequest?.reviewThreads else {
            return ([:], nil)
        }
        var meta: [Int: ThreadMeta] = [:]
        for node in threads.nodes {
            guard let rootID = node.comments.nodes.first?.databaseId else { continue }
            var comments: [Int: ReviewCommentMeta] = [:]
            for comment in node.comments.nodes {
                guard let id = comment.databaseId else { continue }
                let reacted = (comment.reactionGroups ?? [])
                    .filter(\.viewerHasReacted)
                    .compactMap { ReactionKind(graphQL: $0.content)?.rawValue }
                var reactors: [String: ReactorRoster] = [:]
                for group in comment.reactionGroups ?? [] {
                    guard let kind = ReactionKind(graphQL: group.content),
                          let who = group.reactors, who.totalCount > 0 else { continue }
                    reactors[kind.rawValue] = ReactorRoster(
                        logins: (who.nodes ?? []).compactMap(\.login),
                        totalCount: who.totalCount)
                }
                comments[id] = ReviewCommentMeta(nodeID: comment.id,
                                                 viewerReacted: Set(reacted),
                                                 edited: comment.lastEditedAt != nil,
                                                 reactors: reactors)
            }
            meta[rootID] = ThreadMeta(nodeID: node.id, isResolved: node.isResolved,
                                      comments: comments)
        }
        let nextCursor = threads.pageInfo.hasNextPage ? threads.pageInfo.endCursor : nil
        return (meta, nextCursor)
    }

    // MARK: - Cockpit (spec: pr-cockpit)

    /// Everything the cockpit query returns: where the PR stands, plus
    /// the GraphQL-only per-comment state for the conversation timeline
    /// (node ids for reaction mutations, viewer reactions, edit
    /// signals) — for issue comments AND review summaries. REST carries
    /// no reaction data at all for review bodies and no viewer state
    /// anywhere, so both chips and tints come from here.
    struct CockpitPayload {
        var state = PRCockpitState()
        var commentMeta: [Int: ReviewCommentMeta] = [:]
        var reviewMeta: [Int: ReviewCommentMeta] = [:]
        var reviewReactions: [Int: ReactionRollup] = [:]
    }

    /// One measured rate-limit point per page (probed live). This is
    /// deliberately a SEPARATE query from reviewThreadMeta: that
    /// query's failure mode — a shape error silently blanking all
    /// thread state through the caller's `try?` — must not couple to
    /// cockpit state. Neither can take the other down.
    func cockpit(_ ref: PullRequestRef) async throws -> CockpitPayload {
        let query = """
        query($owner: String!, $repo: String!, $number: Int!, $after: String) {
          repository(owner: $owner, name: $repo) {
            pullRequest(number: $number) {
              reviewDecision
              latestOpinionatedReviews(first: 20, writersOnly: false) {
                nodes { state submittedAt author { login avatarUrl } }
              }
              reviewRequests(first: 20) {
                nodes {
                  requestedReviewer {
                    __typename
                    ... on User { login avatarUrl }
                    ... on Team { name avatarUrl }
                    ... on Bot { login avatarUrl }
                    ... on Mannequin { login avatarUrl }
                  }
                }
              }
              statusCheckRollup {
                contexts(first: 50) {
                  totalCount
                  nodes {
                    __typename
                    ... on CheckRun {
                      name status conclusion detailsUrl startedAt completedAt
                      isRequired(pullRequestNumber: $number)
                      checkSuite { workflowRun { workflow { name } } app { name } }
                    }
                    ... on StatusContext {
                      context state targetUrl
                      isRequired(pullRequestNumber: $number)
                    }
                  }
                }
              }
              reviews(first: 100) {
                nodes {
                  id databaseId lastEditedAt
                  reactionGroups {
                    content viewerHasReacted
                    reactors(first: 10) {
                      totalCount
                      nodes {
                        ... on User { login }
                        ... on Bot { login }
                        ... on Organization { login }
                        ... on Mannequin { login }
                      }
                    }
                  }
                }
              }
              comments(first: 100, after: $after) {
                pageInfo { hasNextPage endCursor }
                nodes {
                  id databaseId lastEditedAt
                  reactionGroups {
                    content viewerHasReacted
                    reactors(first: 10) {
                      totalCount
                      nodes {
                        ... on User { login }
                        ... on Bot { login }
                        ... on Organization { login }
                        ... on Mannequin { login }
                      }
                    }
                  }
                }
              }
            }
          }
        }
        """
        var payload = CockpitPayload()
        var cursor: String?
        // Cursor pagination walks the comments connection only; header
        // state and review meta come from the first page (identical on
        // every page — re-parsing them is harmless). Reviews cap at 100
        // with no pagination: chips degrade past that, never a failure.
        for _ in 1...30 {
            var variables: [String: Any] = ["owner": ref.owner, "repo": ref.repo,
                                            "number": ref.number]
            if let cursor { variables["after"] = cursor }
            let data = try await graphQL(query, variables: variables)
            let page = try Self.parseCockpitPage(data)
            if cursor == nil {
                payload.state = page.state
                payload.reviewMeta = page.reviewMeta
                payload.reviewReactions = page.reviewReactions
            }
            payload.commentMeta.merge(page.commentMeta) { _, new in new }
            guard let next = page.nextCursor else { break }
            cursor = next
        }
        return payload
    }

    /// One page of the cockpit query, decoded defensively: nullable
    /// requested reviewers (code-owner/Copilot rows arrive null in live
    /// data), unknown check states, and missing connections all degrade
    /// to empty rather than failing the page.
    nonisolated static func parseCockpitPage(_ data: Data) throws
        -> (state: PRCockpitState,
            commentMeta: [Int: ReviewCommentMeta],
            reviewMeta: [Int: ReviewCommentMeta],
            reviewReactions: [Int: ReactionRollup],
            nextCursor: String?) {
        struct Response: Decodable {
            struct DataBox: Decodable { let repository: Repo? }
            struct Repo: Decodable { let pullRequest: PR? }
            struct PR: Decodable {
                let reviewDecision: String?
                let latestOpinionatedReviews: Opinions?
                let reviewRequests: Requests?
                let statusCheckRollup: Rollup?
                let reviews: MetaNodes?
                let comments: CommentsPage?
            }
            struct Opinions: Decodable { let nodes: [Opinion]? }
            struct Opinion: Decodable {
                struct Author: Decodable {
                    let login: String?
                    let avatarUrl: String?
                }
                let state: String?
                let submittedAt: String?
                let author: Author?
            }
            struct Requests: Decodable { let nodes: [Request]? }
            struct Request: Decodable {
                struct Reviewer: Decodable {
                    let __typename: String?
                    let login: String?
                    let name: String?
                    let avatarUrl: String?
                }
                let requestedReviewer: Reviewer?
            }
            struct Rollup: Decodable { let contexts: Contexts? }
            struct Contexts: Decodable {
                let totalCount: Int?
                let nodes: [Context]?
            }
            struct Context: Decodable {
                struct Suite: Decodable {
                    struct Run: Decodable {
                        struct Workflow: Decodable { let name: String? }
                        let workflow: Workflow?
                    }
                    struct App: Decodable { let name: String? }
                    let workflowRun: Run?
                    let app: App?
                }
                let __typename: String?
                // CheckRun fields
                let name: String?
                let status: String?
                let conclusion: String?
                let detailsUrl: String?
                let startedAt: String?
                let completedAt: String?
                let isRequired: Bool?
                let checkSuite: Suite?
                // StatusContext fields
                let context: String?
                let state: String?
                let targetUrl: String?
            }
            struct MetaNodes: Decodable { let nodes: [MetaNode]? }
            struct CommentsPage: Decodable {
                struct PageInfo: Decodable {
                    let hasNextPage: Bool
                    let endCursor: String?
                }
                let pageInfo: PageInfo?
                let nodes: [MetaNode]?
            }
            struct MetaNode: Decodable {
                struct ReactionGroup: Decodable {
                    struct Reactors: Decodable {
                        struct Node: Decodable { let login: String? }
                        let totalCount: Int
                        let nodes: [Node]?
                    }
                    let content: String
                    let viewerHasReacted: Bool
                    let reactors: Reactors?
                }
                let id: String
                let databaseId: Int?
                let lastEditedAt: String?
                let reactionGroups: [ReactionGroup]?
            }
            let data: DataBox?
        }

        func meta(from node: Response.MetaNode) -> ReviewCommentMeta {
            let reacted = (node.reactionGroups ?? [])
                .filter(\.viewerHasReacted)
                .compactMap { ReactionKind(graphQL: $0.content)?.rawValue }
            var reactors: [String: ReactorRoster] = [:]
            for group in node.reactionGroups ?? [] {
                guard let kind = ReactionKind(graphQL: group.content),
                      let who = group.reactors, who.totalCount > 0 else { continue }
                reactors[kind.rawValue] = ReactorRoster(
                    logins: (who.nodes ?? []).compactMap(\.login),
                    totalCount: who.totalCount)
            }
            return ReviewCommentMeta(nodeID: node.id,
                                     viewerReacted: Set(reacted),
                                     edited: node.lastEditedAt != nil,
                                     reactors: reactors)
        }

        func rollup(from node: Response.MetaNode) -> ReactionRollup? {
            var rollup = ReactionRollup()
            var any = false
            for group in node.reactionGroups ?? [] {
                guard let kind = ReactionKind(graphQL: group.content),
                      let count = group.reactors?.totalCount, count > 0 else { continue }
                rollup.setCount(count, for: kind)
                any = true
            }
            return any ? rollup : nil
        }

        let response = try JSONDecoder().decode(Response.self, from: data)
        guard let pr = response.data?.repository?.pullRequest else {
            return (PRCockpitState(), [:], [:], [:], nil)
        }

        var state = PRCockpitState()
        state.reviewDecision = pr.reviewDecision.flatMap(ReviewDecision.init(rawValue:))
        state.reviewers = (pr.latestOpinionatedReviews?.nodes ?? []).compactMap { opinion in
            // DISMISSED and future states drop off the strip; the
            // timeline still carries their cards.
            guard let login = opinion.author?.login,
                  opinion.state == "APPROVED" || opinion.state == "CHANGES_REQUESTED"
            else { return nil }
            return ReviewerState(login: login,
                                 avatarUrl: opinion.author?.avatarUrl.flatMap(URL.init(string:)),
                                 approved: opinion.state == "APPROVED",
                                 submittedAt: opinion.submittedAt)
        }
        state.reviewRequests = (pr.reviewRequests?.nodes ?? []).compactMap { request in
            guard let reviewer = request.requestedReviewer,
                  let name = reviewer.login ?? reviewer.name else { return nil }
            return ReviewRequestEntry(name: name,
                                      avatarUrl: reviewer.avatarUrl.flatMap(URL.init(string:)),
                                      isTeam: reviewer.__typename == "Team")
        }
        let contexts = pr.statusCheckRollup?.contexts
        state.checksTotal = contexts?.totalCount ?? 0
        state.checks = (contexts?.nodes ?? []).compactMap { node in
            if node.__typename == "StatusContext" {
                guard let name = node.context else { return nil }
                return CheckItem(name: name, group: nil,
                                 state: CheckItem.state(contextState: node.state),
                                 detailsUrl: node.targetUrl.flatMap(URL.init(string:)),
                                 isRequired: node.isRequired ?? false,
                                 durationLabel: nil)
            }
            guard let name = node.name else { return nil }
            return CheckItem(name: name,
                             group: node.checkSuite?.workflowRun?.workflow?.name
                                 ?? node.checkSuite?.app?.name,
                             state: CheckItem.state(status: node.status,
                                                    conclusion: node.conclusion),
                             detailsUrl: node.detailsUrl.flatMap(URL.init(string:)),
                             isRequired: node.isRequired ?? false,
                             durationLabel: CheckItem.durationLabel(
                                 startedAt: node.startedAt,
                                 completedAt: node.completedAt))
        }

        var commentMeta: [Int: ReviewCommentMeta] = [:]
        for node in pr.comments?.nodes ?? [] {
            guard let id = node.databaseId else { continue }
            commentMeta[id] = meta(from: node)
        }
        var reviewMeta: [Int: ReviewCommentMeta] = [:]
        var reviewReactions: [Int: ReactionRollup] = [:]
        for node in pr.reviews?.nodes ?? [] {
            guard let id = node.databaseId else { continue }
            reviewMeta[id] = meta(from: node)
            reviewReactions[id] = rollup(from: node)
        }
        let page = pr.comments?.pageInfo
        let nextCursor = page?.hasNextPage == true ? page?.endCursor : nil
        return (state, commentMeta, reviewMeta, reviewReactions, nextCursor)
    }

    /// Adds or removes the viewer's reaction on a comment.
    ///
    /// API choice: GraphQL, not REST. REST's remove route
    /// (DELETE …/pulls/comments/{id}/reactions/{reaction_id}) needs the
    /// viewer's reaction id, which would take an extra listing call to
    /// find; addReaction/removeReaction take subject node id + content
    /// symmetrically, and the thread-meta query already carries every
    /// comment's node id.
    func setReaction(subjectID: String, content: ReactionKind, add: Bool) async throws {
        let mutation = add
            ? "mutation($id: ID!, $content: ReactionContent!) { addReaction(input: { subjectId: $id, content: $content }) { reaction { id } } }"
            : "mutation($id: ID!, $content: ReactionContent!) { removeReaction(input: { subjectId: $id, content: $content }) { reaction { id } } }"
        _ = try await graphQL(mutation, variables: ["id": subjectID,
                                                    "content": content.graphQLName])
    }

    /// Edits the body of a review comment (the viewer's own).
    func updateReviewComment(_ ref: PullRequestRef, commentID: Int, body: String) async throws {
        let payload = try Self.editCommentRequestBody(body: body)
        _ = try await request("PATCH", "/repos/\(ref.owner)/\(ref.repo)/pulls/comments/\(commentID)",
                              jsonBody: payload)
    }

    func setThreadResolved(nodeID: String, resolved: Bool) async throws {
        let mutation = resolved
            ? "mutation($id: ID!) { resolveReviewThread(input: { threadId: $id }) { thread { isResolved } } }"
            : "mutation($id: ID!) { unresolveReviewThread(input: { threadId: $id }) { thread { isResolved } } }"
        _ = try await graphQL(mutation, variables: ["id": nodeID])
    }

    /// Replies within an existing review thread.
    /// Returns the created comment: callers fold it into the loaded
    /// model directly — the list endpoint can lag a fresh write, so an
    /// immediate refetch may not contain the reply just posted.
    @discardableResult
    func replyToReviewComment(_ ref: PullRequestRef, rootID: Int, body: String) async throws -> ReviewComment {
        let payload = try JSONSerialization.data(withJSONObject: ["body": body, "in_reply_to": rootID])
        let data = try await request("POST", "/repos/\(ref.owner)/\(ref.repo)/pulls/\(ref.number)/comments",
                                     jsonBody: payload)
        return try Self.decoder.decode(ReviewComment.self, from: data)
    }

    /// Per-line blame ranges for a repo file at a commit (GraphQL; requires auth).
    func blame(ref: PullRequestRef, path: String, sha: String) async throws -> [BlameRange] {
        // Demo mode: fixture blame with locally generated data-URI avatars
        // — the same pipeline real GitHub avatar URLs feed.
        if DemoMode.active { return DemoSession.blameRanges(path: path) }
        let data = try await graphQL(GitHubBlame.query,
                                     variables: ["owner": ref.owner, "repo": ref.repo,
                                                 "expr": sha, "path": path])
        return try GitHubBlame.parse(data)
    }

    /// The signed-in user's identity, fetched once per session (GraphQL).
    /// Nil without credentials — avatar tiering then skips the viewer tier.
    struct InboxPR: Identifiable, Equatable {
        let ref: PullRequestRef
        let title: String
        let author: String?
        let draft: Bool
        /// ISO timestamp from the search API — drives unread state.
        let updatedAt: String
        var id: String { "\(ref.owner)/\(ref.repo)#\(ref.number)" }
    }

    /// Open PRs where the viewer's review is requested, newest first.
    /// Returns [] when unauthenticated (the inbox simply stays hidden).
    func reviewRequests() async throws -> [InboxPR] {
        guard let viewer = await viewerIdentity()?.login else { return [] }
        struct Response: Decodable {
            struct Item: Decodable {
                struct User: Decodable { let login: String }
                let number: Int
                let title: String
                let repositoryUrl: String
                let updatedAt: String
                let user: User?
                let draft: Bool?
            }
            let items: [Item]
        }
        let data = try await request(
            "GET", "/search/issues",
            query: [URLQueryItem(name: "q",
                                 value: "is:open is:pr review-requested:\(viewer) archived:false"),
                    URLQueryItem(name: "sort", value: "updated"),
                    URLQueryItem(name: "per_page", value: "25")])
        let response = try Self.decoder.decode(Response.self, from: data)
        return response.items.compactMap { item in
            // repository_url: https://api.github.com/repos/{owner}/{repo}
            let parts = item.repositoryUrl.components(separatedBy: "/repos/").last?
                .components(separatedBy: "/") ?? []
            guard parts.count == 2 else { return nil }
            return InboxPR(ref: PullRequestRef(owner: parts[0], repo: parts[1], number: item.number),
                           title: item.title,
                           author: item.user?.login,
                           draft: item.draft ?? false,
                           updatedAt: item.updatedAt)
        }
    }

    /// How many Markdown files a PR touches — the inbox badge. Cheap-ish
    /// (one files page is enough for a badge; capped at 100).
    func markdownFileCount(_ ref: PullRequestRef) async throws -> Int {
        let data = try await request("GET", "/repos/\(ref.owner)/\(ref.repo)/pulls/\(ref.number)/files",
                                     query: [URLQueryItem(name: "per_page", value: "100")])
        let files = try Self.decoder.decode([PullRequestFile].self, from: data)
        return files.filter {
            MarkdownFileType.matches(($0.filename as NSString).pathExtension)
        }.count
    }

    func viewerIdentity() async -> ViewerIdentity? {
        if let cachedViewer { return cachedViewer }
        struct Response: Decodable {
            struct DataBox: Decodable { let viewer: Viewer? }
            struct Viewer: Decodable {
                let login: String
                let name: String?
                let email: String?
                let avatarUrl: String?
            }
            let data: DataBox?
        }
        // The email field needs the user:email/read:user scope, which gh
        // tokens frequently lack — fall back to a scope-free query (the
        // noreply-address match still identifies the viewer's commits).
        var viewer: Response.Viewer?
        for query in ["query { viewer { login name email avatarUrl } }",
                      "query { viewer { login name avatarUrl } }"] {
            if let data = try? await graphQL(query, variables: [:]),
               let decoded = try? JSONDecoder().decode(Response.self, from: data).data?.viewer {
                viewer = decoded
                break
            }
        }
        guard let viewer else { return nil }
        cachedViewer = ViewerIdentity(login: viewer.login, name: viewer.name,
                                      email: viewer.email, avatarUrl: viewer.avatarUrl)
        return cachedViewer
    }

    /// Latest commits that touched a repo file at a commit (GraphQL; the
    /// History panel's data for PR files — GitHub has no line-history API).
    func fileHistory(ref: PullRequestRef, path: String, sha: String,
                     limit: Int = 15) async throws -> [BlameCommit] {
        if DemoMode.active { return DemoSession.historyCommits() }
        let data = try await graphQL(GitHubHistory.query,
                                     variables: ["owner": ref.owner, "repo": ref.repo,
                                                 "expr": sha, "path": path, "first": limit])
        return try GitHubHistory.parse(data)
    }

    /// SHAs of the commits on the PR branch (REST, paginated). Used to split
    /// the History panel between PR-branch and base-branch commits.
    func prCommitSHAs(_ ref: PullRequestRef) async throws -> [String] {
        if DemoMode.active { return DemoSession.prCommitSHAs }
        struct CommitRow: Decodable { let sha: String }
        var all: [String] = []
        for page in 1...3 {
            let data = try await request("GET", "/repos/\(ref.owner)/\(ref.repo)/pulls/\(ref.number)/commits",
                                         query: [URLQueryItem(name: "per_page", value: "100"),
                                                 URLQueryItem(name: "page", value: "\(page)")])
            let batch = try Self.decoder.decode([CommitRow].self, from: data)
            all.append(contentsOf: batch.map(\.sha))
            if batch.count < 100 { break }
        }
        return all
    }

    private func graphQL(_ query: String, variables: [String: Any]) async throws -> Data {
        guard await authToken() != nil else {
            throw APIError(status: 401, message: "GitHub authentication is required for this action. "
                + "Sign in with `gh auth login` or configure a git credential helper.")
        }
        let body = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        let data = try await request("POST", "/graphql", jsonBody: body)
        struct ErrorEnvelope: Decodable {
            struct GQLError: Decodable { let message: String }
            let errors: [GQLError]?
        }
        if let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data),
           let first = envelope.errors?.first {
            throw APIError(status: 200, message: first.message)
        }
        return data
    }

    /// Posts a single review comment immediately (visible right away).
    /// Platform caveat: while the viewer has a pending review, GitHub may
    /// absorb comments from this endpoint into it instead of publishing them
    /// — callers re-adopt the pending review afterwards so the app never
    /// claims a comment posted when it actually went pending.
    func createComment(_ ref: PullRequestRef, commitID: String, comment: PendingComment) async throws {
        let body = try Self.commentRequestBody(commitID: commitID, comment: comment)
        _ = try await request("POST", "/repos/\(ref.owner)/\(ref.repo)/pulls/\(ref.number)/comments",
                              jsonBody: body)
    }

    // MARK: - Pending review (GitHub is the source of truth — spec §4)
    //
    // API mix, resolved after a docs/community spike: REST creates the
    // pending review — one atomic POST /pulls/{n}/reviews with `event`
    // omitted carries the whole first batch plus an explicit commit_id, so
    // anchors are validated against the exact head the line numbers were
    // computed on. REST cannot add to an existing pending review (there is
    // no …/reviews/{id}/comments endpoint; community discussion #168380 is
    // the open feature request), so incremental adds use GraphQL
    // addPullRequestReviewThread with the review's node id. That mutation
    // takes no commit SHA — GitHub anchors against the PR's current head —
    // which is safe here because the refresh loop never swaps the loaded
    // head under an in-progress review. Adds drain FIFO, one mutation per
    // comment, so server order follows authorship order.

    /// Creates a review carrying the given comments. With `event` nil the
    /// review is left PENDING on GitHub; otherwise it is submitted with
    /// that event (COMMENT / APPROVE / REQUEST_CHANGES). Fails with 422
    /// when the viewer already has a pending review on the PR.
    ///
    /// Returns the created review when the response decodes (it is the
    /// authoritative read: GitHub's reviews *list* lags reads-after-writes,
    /// so a re-fetch right after a create can miss the new review — see
    /// AppState.performPendingSyncPass). A decode failure returns nil
    /// rather than throwing: the HTTP success already means the review
    /// exists, and surfacing a shape drift as a create failure would
    /// re-run a create that must not run twice.
    @discardableResult
    func createReview(_ ref: PullRequestRef, commitID: String, body: String?,
                      event: String?, comments: [PendingComment]) async throws
        -> PullRequestReview? {
        let payload = try Self.reviewRequestBody(commitID: commitID, body: body,
                                                 event: event, comments: comments)
        let data = try await request("POST", "/repos/\(ref.owner)/\(ref.repo)/pulls/\(ref.number)/reviews",
                                     jsonBody: payload)
        return Self.decodeCreatedReview(data)
    }

    /// The review object POST …/reviews echoes back, or nil on shape drift.
    nonisolated static func decodeCreatedReview(_ data: Data) -> PullRequestReview? {
        try? decoder.decode(PullRequestReview.self, from: data)
    }

    /// All reviews on the PR (paginated; includes the viewer's own PENDING
    /// review, which no other endpoint reveals).
    func reviews(_ ref: PullRequestRef) async throws -> [PullRequestReview] {
        var all: [PullRequestReview] = []
        for page in 1...30 {
            let data = try await request("GET", "/repos/\(ref.owner)/\(ref.repo)/pulls/\(ref.number)/reviews",
                                         query: [URLQueryItem(name: "per_page", value: "100"),
                                                 URLQueryItem(name: "page", value: "\(page)")])
            let batch = try Self.decodeReviews(data)
            all.append(contentsOf: batch)
            if batch.count < 100 { break }
        }
        return all
    }

    /// The viewer's pending comments on a review, resolved through GraphQL
    /// review threads. This must NOT use REST: GET …/reviews/{id}/comments
    /// returns only legacy diff-position fields for pending comments — no
    /// line/original_line/side — so a REST fetch decodes to zero anchored
    /// comments, reconciliation never matches, and every sync re-uploads
    /// the whole queue (see the REST-shape regression fixture in
    /// PendingReviewTests).
    func pendingReviewComments(_ ref: PullRequestRef, reviewID: Int) async throws -> [PendingComment] {
        let query = """
        query($owner: String!, $repo: String!, $number: Int!, $after: String) {
          repository(owner: $owner, name: $repo) {
            pullRequest(number: $number) {
              reviewThreads(first: 100, after: $after) {
                pageInfo { hasNextPage endCursor }
                nodes {
                  diffSide line startLine originalLine originalStartLine path
                  comments(first: 100) {
                    nodes { databaseId body state pullRequestReview { databaseId } }
                  }
                }
              }
            }
          }
        }
        """
        var all: [PendingComment] = []
        var cursor: String?
        for _ in 1...30 {
            var variables: [String: Any] = ["owner": ref.owner, "repo": ref.repo, "number": ref.number]
            if let cursor { variables["after"] = cursor }
            let data = try await graphQL(query, variables: variables)
            let page = try Self.parsePendingCommentsPage(data, reviewID: reviewID)
            all.append(contentsOf: page.comments)
            guard let next = page.nextCursor else { break }
            cursor = next
        }
        // Threads arrive in file/position order; the UI wants authorship
        // order, which server comment ids approximate monotonically.
        return all.sorted { ($0.serverID ?? 0) < ($1.serverID ?? 0) }
    }

    /// One page of the pending-comments query: the review's pending
    /// comments (line-anchored threads only — file-level threads have no
    /// line to anchor a PendingComment) plus the next-page cursor. Throws
    /// on an unexpected shape rather than decoding to an empty list — an
    /// empty result must always mean "genuinely no pending comments".
    nonisolated static func parsePendingCommentsPage(_ data: Data, reviewID: Int) throws
        -> (comments: [PendingComment], nextCursor: String?) {
        struct Response: Decodable {
            struct DataBox: Decodable { let repository: Repo? }
            struct Repo: Decodable { let pullRequest: PR? }
            struct PR: Decodable { let reviewThreads: Threads }
            struct Threads: Decodable {
                let pageInfo: PageInfo
                let nodes: [Node]
            }
            struct PageInfo: Decodable {
                let hasNextPage: Bool
                let endCursor: String?
            }
            struct Node: Decodable {
                let diffSide: String?
                let line: Int?
                let startLine: Int?
                let originalLine: Int?
                let originalStartLine: Int?
                let path: String
                let comments: Comments
            }
            struct Comments: Decodable { let nodes: [Comment] }
            struct Comment: Decodable {
                struct Review: Decodable { let databaseId: Int? }
                let databaseId: Int?
                let body: String
                let state: String?
                let pullRequestReview: Review?
            }
            let data: DataBox?
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard let threads = response.data?.repository?.pullRequest?.reviewThreads else {
            throw APIError(status: 200, message: "Unexpected reviewThreads response shape")
        }
        var comments: [PendingComment] = []
        for thread in threads.nodes {
            // line falls back to originalLine when the head moved under the
            // pending review (same anchoring the app shows for outdated
            // comments); threads with no line at all (file-level) are
            // skipped — PendingComment requires a line anchor.
            guard let lineEnd = thread.line ?? thread.originalLine else { continue }
            let lineStart = thread.startLine ?? thread.originalStartLine ?? lineEnd
            let side = thread.diffSide ?? "RIGHT"
            for comment in thread.comments.nodes {
                guard comment.state == "PENDING",
                      comment.pullRequestReview?.databaseId == reviewID,
                      let serverID = comment.databaseId else { continue }
                comments.append(PendingComment(serverID: serverID,
                                               path: thread.path,
                                               lineStart: min(lineStart, lineEnd),
                                               lineEnd: lineEnd,
                                               side: side,
                                               body: comment.body))
            }
        }
        let nextCursor = threads.pageInfo.hasNextPage ? threads.pageInfo.endCursor : nil
        return (comments, nextCursor)
    }

    /// Adds one comment to the viewer's existing pending review (GraphQL —
    /// see the API-mix note above).
    func addPendingComment(reviewNodeID: String, comment: PendingComment) async throws {
        let mutation = """
        mutation($input: AddPullRequestReviewThreadInput!) {
          addPullRequestReviewThread(input: $input) { thread { id } }
        }
        """
        _ = try await graphQL(mutation,
                              variables: ["input": Self.addThreadInput(reviewNodeID: reviewNodeID,
                                                                       comment: comment)])
    }

    /// Submits the server-side pending review with a verdict.
    func submitReview(_ ref: PullRequestRef, reviewID: Int, event: String, body: String?) async throws {
        let payload = try Self.submitReviewRequestBody(event: event, body: body)
        _ = try await request("POST",
                              "/repos/\(ref.owner)/\(ref.repo)/pulls/\(ref.number)/reviews/\(reviewID)/events",
                              jsonBody: payload)
    }

    /// Abandons (deletes) an unsubmitted pending review — GitHub's
    /// "Abandon review". Submitted reviews cannot be deleted.
    func deletePendingReview(_ ref: PullRequestRef, reviewID: Int) async throws {
        _ = try await request("DELETE",
                              "/repos/\(ref.owner)/\(ref.repo)/pulls/\(ref.number)/reviews/\(reviewID)")
    }

    /// Deletes a single review comment; works on the viewer's own pending
    /// comments too (discarding one from the pending review).
    func deleteReviewComment(_ ref: PullRequestRef, commentID: Int) async throws {
        _ = try await request("DELETE",
                              "/repos/\(ref.owner)/\(ref.repo)/pulls/comments/\(commentID)")
    }

    /// Posts a comment attached to a whole file (no line anchor). GitHub
    /// only supports subject_type on the standalone comment endpoint, so
    /// file-level comments post immediately and can't join a pending review.
    func createFileComment(_ ref: PullRequestRef, commitID: String,
                           path: String, body: String) async throws {
        let payload = try Self.fileCommentRequestBody(commitID: commitID, path: path, body: body)
        _ = try await request("POST", "/repos/\(ref.owner)/\(ref.repo)/pulls/\(ref.number)/comments",
                              jsonBody: payload)
    }

    /// Posts a general conversation comment on the pull request (the
    /// issue-comment timeline, not tied to any file or line).
    @discardableResult
    func createIssueComment(_ ref: PullRequestRef, body: String) async throws -> IssueComment {
        let payload = try Self.issueCommentRequestBody(body: body)
        let data = try await request("POST", "/repos/\(ref.owner)/\(ref.repo)/issues/\(ref.number)/comments",
                                     jsonBody: payload)
        // The echoed comment folds into the timeline locally — the
        // comments list lags fresh writes (0.31.0 lesson; never refetch
        // on mutation).
        return try Self.decoder.decode(IssueComment.self, from: data)
    }

    /// Every conversation comment on the PR (the issue-comment
    /// timeline — every pull request is an issue), ascending by id.
    /// 30 pages bounds a pathological PR.
    func issueComments(_ ref: PullRequestRef) async throws -> [IssueComment] {
        var all: [IssueComment] = []
        for page in 1...30 {
            let data = try await request("GET", "/repos/\(ref.owner)/\(ref.repo)/issues/\(ref.number)/comments",
                                         query: [URLQueryItem(name: "per_page", value: "100"),
                                                 URLQueryItem(name: "page", value: "\(page)")])
            let batch = try Self.decoder.decode([IssueComment].self, from: data)
            all.append(contentsOf: batch)
            if batch.count < 100 { break }
        }
        return all
    }

    /// The quiet-tick variant: conditional on the previous ETag; nil
    /// comments means unchanged (the 304 was free). The ETag contract
    /// only holds while the whole list fits one page — the list is
    /// ascending, so appends land on the LAST page and a page-1 ETag
    /// would miss them past 100. A spilled list returns etag nil,
    /// sending every following tick down the plain full-fetch path.
    func issueCommentsIfChanged(_ ref: PullRequestRef, etag: String?)
        async throws -> (comments: [IssueComment]?, etag: String?) {
        let path = "/repos/\(ref.owner)/\(ref.repo)/issues/\(ref.number)/comments"
        let (data, freshTag) = try await conditionalGET(
            path,
            query: [URLQueryItem(name: "per_page", value: "100"),
                    URLQueryItem(name: "page", value: "1")],
            etag: etag)
        guard let data else { return (nil, etag) }
        var all = try Self.decoder.decode([IssueComment].self, from: data)
        if all.count == 100 {
            for page in 2...30 {
                let more = try await request("GET", path,
                                             query: [URLQueryItem(name: "per_page", value: "100"),
                                                     URLQueryItem(name: "page", value: "\(page)")])
                let batch = try Self.decoder.decode([IssueComment].self, from: more)
                all.append(contentsOf: batch)
                if batch.count < 100 { break }
            }
            return (all, nil)
        }
        return (all, freshTag)
    }

    /// Edits the body of a conversation comment (the viewer's own).
    /// Same shape as updateReviewComment, different endpoint family —
    /// issue comments live under /issues/comments, not /pulls/comments.
    func updateIssueComment(_ ref: PullRequestRef, commentID: Int, body: String) async throws -> IssueComment {
        let payload = try Self.editCommentRequestBody(body: body)
        let data = try await request("PATCH", "/repos/\(ref.owner)/\(ref.repo)/issues/comments/\(commentID)",
                                     jsonBody: payload)
        return try Self.decoder.decode(IssueComment.self, from: data)
    }

    func deleteIssueComment(_ ref: PullRequestRef, commentID: Int) async throws {
        _ = try await request("DELETE",
                              "/repos/\(ref.owner)/\(ref.repo)/issues/comments/\(commentID)")
    }

    // MARK: - Request body builders (pure, unit-tested)

    struct CommentBody: Encodable {
        let body: String
        let commitId: String
        let path: String
        let side: String
        let line: Int
        let startLine: Int?
        let startSide: String?
    }

    struct ReviewBody: Encodable {
        struct Comment: Encodable {
            let path: String
            let body: String
            let side: String
            let line: Int
            let startLine: Int?
            let startSide: String?
        }
        let commitId: String
        let body: String?
        let event: String?
        /// nil (omitted) when there are no drafts — the endpoint documents
        /// the parameter as optional, and omitting beats sending [].
        let comments: [Comment]?
    }

    nonisolated static func commentRequestBody(commitID: String, comment: PendingComment) throws -> Data {
        let multiLine = comment.lineStart < comment.lineEnd
        return try encoder.encode(CommentBody(
            body: comment.body,
            commitId: commitID,
            path: comment.path,
            side: comment.side,
            line: comment.lineEnd,
            startLine: multiLine ? comment.lineStart : nil,
            startSide: multiLine ? comment.side : nil
        ))
    }

    nonisolated static func reviewRequestBody(commitID: String, body: String?,
                                              event: String?, comments: [PendingComment]) throws -> Data {
        let rows = comments.map { comment in
            let multiLine = comment.lineStart < comment.lineEnd
            return ReviewBody.Comment(
                path: comment.path,
                body: comment.body,
                side: comment.side,
                line: comment.lineEnd,
                startLine: multiLine ? comment.lineStart : nil,
                startSide: multiLine ? comment.side : nil
            )
        }
        return try encoder.encode(ReviewBody(commitId: commitID, body: body, event: event,
                                             comments: rows.isEmpty ? nil : rows))
    }

    struct SubmitReviewBody: Encodable {
        let event: String
        let body: String?
    }

    nonisolated static func submitReviewRequestBody(event: String, body: String?) throws -> Data {
        try encoder.encode(SubmitReviewBody(event: event, body: body))
    }

    /// GraphQL variables for addPullRequestReviewThread. Line semantics
    /// match REST (file line numbers + side; start* only for ranges).
    nonisolated static func addThreadInput(reviewNodeID: String, comment: PendingComment) -> [String: Any] {
        var input: [String: Any] = [
            "pullRequestReviewId": reviewNodeID,
            "path": comment.path,
            "body": comment.body,
            "line": comment.lineEnd,
            "side": comment.side,
        ]
        if comment.lineStart < comment.lineEnd {
            input["startLine"] = comment.lineStart
            input["startSide"] = comment.side
        }
        return input
    }

    nonisolated static func decodeReviews(_ data: Data) throws -> [PullRequestReview] {
        try decoder.decode([PullRequestReview].self, from: data)
    }

    struct FileCommentBody: Encodable {
        let body: String
        let commitId: String
        let path: String
        let subjectType: String
    }

    nonisolated static func fileCommentRequestBody(commitID: String, path: String,
                                                   body: String) throws -> Data {
        try encoder.encode(FileCommentBody(body: body, commitId: commitID,
                                           path: path, subjectType: "file"))
    }

    nonisolated static func issueCommentRequestBody(body: String) throws -> Data {
        try encoder.encode(["body": body])
    }

    nonisolated static func editCommentRequestBody(body: String) throws -> Data {
        try encoder.encode(["body": body])
    }

    // MARK: - Transport

    private func request(_ method: String, _ path: String,
                         query: [URLQueryItem] = [],
                         accept: String = "application/vnd.github+json",
                         jsonBody: Data? = nil) async throws -> Data {
        let (data, http) = try await perform(method, path, query: query,
                                             accept: accept, jsonBody: jsonBody)
        return try await validate(data, http)
    }

    /// Conditional GET on a previous ETag: a 304 returns nil data and
    /// costs no rate limit (verified live). Callers get the fresh ETag
    /// back for the next round trip.
    private func conditionalGET(_ path: String, query: [URLQueryItem] = [],
                                etag: String?) async throws -> (data: Data?, etag: String?) {
        var headers: [String: String] = [:]
        if let etag { headers["If-None-Match"] = etag }
        let (data, http) = try await perform("GET", path, query: query, headers: headers)
        if http.statusCode == 304 { return (nil, etag) }
        let validated = try await validate(data, http)
        return (validated, http.value(forHTTPHeaderField: "ETag"))
    }

    private func perform(_ method: String, _ path: String,
                         query: [URLQueryItem] = [],
                         accept: String = "application/vnd.github+json",
                         jsonBody: Data? = nil,
                         headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        // The one transport choke point (REST and GraphQL both land
        // here): demo mode is offline by construction, not by hoping
        // every caller remembered its own guard.
        guard !DemoMode.active else {
            throw APIError(status: -1, message: "PullMark is in demo mode — network access is disabled.")
        }
        var components = URLComponents(string: "https://api.github.com")!
        components.path = path
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else {
            throw APIError(status: -1, message: "Invalid URL for \(path)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("PullMark", forHTTPHeaderField: "User-Agent")
        if let token = await authToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        // Manual revalidation owns the 304 contract — URLSession's own
        // cache layer must not answer for the server.
        if headers["If-None-Match"] != nil {
            request.cachePolicy = .reloadIgnoringLocalCacheData
        }
        if let jsonBody {
            request.httpBody = jsonBody
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError(status: -1, message: "No HTTP response")
        }
        return (data, http)
    }

    private func validate(_ data: Data, _ http: HTTPURLResponse) async throws -> Data {
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 404 {
                let hasToken = await authToken() != nil
                if !hasToken {
                    throw APIError(status: http.statusCode,
                                   message: "\(Self.errorMessage(from: data)) — no GitHub credentials found. "
                                   + "Sign in with `gh auth login` or configure a git credential helper for github.com.")
                }
            }
            throw APIError(status: http.statusCode, message: Self.errorMessage(from: data))
        }
        return data
    }

    struct APIMessage: Decodable {
        /// GitHub mixes two `errors` shapes: `[{"message": …}]` objects
        /// (validation errors) and bare strings (`["Can not approve your
        /// own pull request"]`) — both must decode, or the alert shows
        /// the raw JSON body.
        struct Detail: Decodable {
            let message: String?

            private enum CodingKeys: String, CodingKey { case message }

            init(from decoder: Decoder) throws {
                if let single = try? decoder.singleValueContainer(),
                   let text = try? single.decode(String.self) {
                    message = text
                } else {
                    let keyed = try decoder.container(keyedBy: CodingKeys.self)
                    message = try keyed.decodeIfPresent(String.self, forKey: .message)
                }
            }
        }
        let message: String?
        let errors: [Detail]?
    }

    nonisolated static func errorMessage(from data: Data) -> String {
        if let parsed = try? JSONDecoder().decode(APIMessage.self, from: data) {
            let parts = ([parsed.message] + (parsed.errors?.map(\.message) ?? [])).compactMap { $0 }
            if !parts.isEmpty { return parts.joined(separator: " — ") }
        }
        return String(data: data.prefix(300), encoding: .utf8) ?? "Unknown error"
    }
}
