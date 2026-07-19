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
    func createComment(_ ref: PullRequestRef, commitID: String, comment: DraftComment) async throws {
        let body = try Self.commentRequestBody(commitID: commitID, comment: comment)
        _ = try await request("POST", "/repos/\(ref.owner)/\(ref.repo)/pulls/\(ref.number)/comments",
                              jsonBody: body)
    }

    /// Creates a review carrying all draft comments. With `event` nil the
    /// review is left PENDING on GitHub (a draft review); otherwise it is
    /// submitted with that event (COMMENT / APPROVE / REQUEST_CHANGES).
    func createReview(_ ref: PullRequestRef, commitID: String, body: String?,
                      event: String?, drafts: [DraftComment]) async throws {
        let payload = try Self.reviewRequestBody(commitID: commitID, body: body, event: event, drafts: drafts)
        _ = try await request("POST", "/repos/\(ref.owner)/\(ref.repo)/pulls/\(ref.number)/reviews",
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
        let comments: [Comment]
    }

    nonisolated static func commentRequestBody(commitID: String, comment: DraftComment) throws -> Data {
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
                                              event: String?, drafts: [DraftComment]) throws -> Data {
        let comments = drafts.map { draft in
            let multiLine = draft.lineStart < draft.lineEnd
            return ReviewBody.Comment(
                path: draft.path,
                body: draft.body,
                side: draft.side,
                line: draft.lineEnd,
                startLine: multiLine ? draft.lineStart : nil,
                startSide: multiLine ? draft.side : nil
            )
        }
        return try encoder.encode(ReviewBody(commitId: commitID, body: body, event: event, comments: comments))
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
