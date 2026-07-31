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
    private var cachedViewer: ViewerIdentity?
    private var viewerResolved = false
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
        try await request("GET", "/repos/\(ref.owner)/\(ref.repo)/contents/\(path)",
                          query: [URLQueryItem(name: "ref", value: sha)],
                          accept: "application/vnd.github.raw+json")
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
    /// root comment id (REST databaseId). Resolution is GraphQL-only.
    func reviewThreadMeta(_ ref: PullRequestRef) async throws -> [Int: ThreadMeta] {
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
            struct Comment: Decodable { let databaseId: Int? }
            let data: DataBox?
        }
        let query = """
        query($owner: String!, $repo: String!, $number: Int!, $after: String) {
          repository(owner: $owner, name: $repo) {
            pullRequest(number: $number) {
              reviewThreads(first: 100, after: $after) {
                pageInfo { hasNextPage endCursor }
                nodes { id isResolved comments(first: 1) { nodes { databaseId } } }
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
            let response = try JSONDecoder().decode(Response.self, from: data)
            guard let threads = response.data?.repository?.pullRequest?.reviewThreads else { break }
            for node in threads.nodes {
                if let rootID = node.comments.nodes.first?.databaseId {
                    meta[rootID] = ThreadMeta(nodeID: node.id, isResolved: node.isResolved)
                }
            }
            guard threads.pageInfo.hasNextPage, let next = threads.pageInfo.endCursor else { break }
            cursor = next
        }
        return meta
    }

    func setThreadResolved(nodeID: String, resolved: Bool) async throws {
        let mutation = resolved
            ? "mutation($id: ID!) { resolveReviewThread(input: { threadId: $id }) { thread { isResolved } } }"
            : "mutation($id: ID!) { unresolveReviewThread(input: { threadId: $id }) { thread { isResolved } } }"
        _ = try await graphQL(mutation, variables: ["id": nodeID])
    }

    /// Replies within an existing review thread.
    func replyToReviewComment(_ ref: PullRequestRef, rootID: Int, body: String) async throws {
        let payload = try JSONSerialization.data(withJSONObject: ["body": body, "in_reply_to": rootID])
        _ = try await request("POST", "/repos/\(ref.owner)/\(ref.repo)/pulls/\(ref.number)/comments",
                              jsonBody: payload)
    }

    /// Per-line blame ranges for a repo file at a commit (GraphQL; requires auth).
    func blame(ref: PullRequestRef, path: String, sha: String) async throws -> [BlameRange] {
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
        if viewerResolved { return cachedViewer }
        viewerResolved = true
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
        let data = try await graphQL(GitHubHistory.query,
                                     variables: ["owner": ref.owner, "repo": ref.repo,
                                                 "expr": sha, "path": path, "first": limit])
        return try GitHubHistory.parse(data)
    }

    /// SHAs of the commits on the PR branch (REST, paginated). Used to split
    /// the History panel between PR-branch and base-branch commits.
    func prCommitSHAs(_ ref: PullRequestRef) async throws -> [String] {
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
    func createReview(_ ref: PullRequestRef, commitID: String, body: String?,
                      event: String?, comments: [PendingComment]) async throws {
        let payload = try Self.reviewRequestBody(commitID: commitID, body: body,
                                                 event: event, comments: comments)
        _ = try await request("POST", "/repos/\(ref.owner)/\(ref.repo)/pulls/\(ref.number)/reviews",
                              jsonBody: payload)
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

    /// Comments belonging to one review (paginated). The viewer's pending
    /// comments come back only through here — the PR-wide comment list
    /// omits them.
    func reviewComments(_ ref: PullRequestRef, reviewID: Int) async throws -> [ReviewComment] {
        var all: [ReviewComment] = []
        for page in 1...30 {
            let data = try await request(
                "GET", "/repos/\(ref.owner)/\(ref.repo)/pulls/\(ref.number)/reviews/\(reviewID)/comments",
                query: [URLQueryItem(name: "per_page", value: "100"),
                        URLQueryItem(name: "page", value: "\(page)")])
            let batch = try Self.decoder.decode([ReviewComment].self, from: data)
            all.append(contentsOf: batch)
            if batch.count < 100 { break }
        }
        return all
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
    func createIssueComment(_ ref: PullRequestRef, body: String) async throws {
        let payload = try Self.issueCommentRequestBody(body: body)
        _ = try await request("POST", "/repos/\(ref.owner)/\(ref.repo)/issues/\(ref.number)/comments",
                              jsonBody: payload)
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

    // MARK: - Transport

    private func request(_ method: String, _ path: String,
                         query: [URLQueryItem] = [],
                         accept: String = "application/vnd.github+json",
                         jsonBody: Data? = nil) async throws -> Data {
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
        if let jsonBody {
            request.httpBody = jsonBody
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError(status: -1, message: "No HTTP response")
        }
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

    private struct APIMessage: Decodable {
        struct Detail: Decodable { let message: String? }
        let message: String?
        let errors: [Detail]?
    }

    private nonisolated static func errorMessage(from data: Data) -> String {
        if let parsed = try? JSONDecoder().decode(APIMessage.self, from: data) {
            let parts = ([parsed.message] + (parsed.errors?.map(\.message) ?? [])).compactMap { $0 }
            if !parts.isEmpty { return parts.joined(separator: " — ") }
        }
        return String(data: data.prefix(300), encoding: .utf8) ?? "Unknown error"
    }
}
