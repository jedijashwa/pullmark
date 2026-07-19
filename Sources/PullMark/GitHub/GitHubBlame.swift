import Foundation

/// Commit node shape shared by the GraphQL blame and file-history queries.
/// `author.user.avatarUrl` is the account avatar (tier 1);
/// `author.avatarUrl` is GitHub's commit-email-derived avatar (fallback tier).
struct GraphQLCommitNode: Decodable {
    struct Author: Decodable {
        let name: String?
        let email: String?
        let avatarUrl: String?
        let user: User?
    }
    struct User: Decodable {
        let login: String?
        let avatarUrl: String?
    }

    let oid: String
    let messageHeadline: String?
    let committedDate: String?
    let url: String?
    let author: Author?

    static let queryFields = """
    oid
    messageHeadline
    committedDate
    url
    author { name email avatarUrl user { login avatarUrl } }
    """

    func blameCommit(iso: ISO8601DateFormatter) -> BlameCommit {
        BlameCommit(
            sha: oid,
            authorName: author?.name ?? author?.user?.login ?? "unknown",
            authorEmail: author?.email,
            date: committedDate.flatMap { iso.date(from: $0) },
            summary: messageHeadline ?? "",
            userAvatarUrl: author?.user?.avatarUrl,
            actorAvatarUrl: author?.avatarUrl,
            url: url
        )
    }
}

/// GraphQL blame: query text plus a pure response parser (unit-tested with a
/// fixture) shared by PR files and local files whose repo lives on github.com.
enum GitHubBlame {
    static let query = """
    query($owner: String!, $repo: String!, $expr: String!, $path: String!) {
      repository(owner: $owner, name: $repo) {
        object(expression: $expr) {
          ... on Commit {
            blame(path: $path) {
              ranges {
                startingLine
                endingLine
                commit {
                  \(GraphQLCommitNode.queryFields)
                }
              }
            }
          }
        }
      }
    }
    """

    struct ParseError: LocalizedError {
        var errorDescription: String? { "GitHub returned no blame data for this file." }
    }

    private struct Response: Decodable {
        struct DataBox: Decodable { let repository: Repo? }
        struct Repo: Decodable { let object: Object? }
        struct Object: Decodable { let blame: Blame? }
        struct Blame: Decodable { let ranges: [RangeNode] }
        struct RangeNode: Decodable {
            let startingLine: Int
            let endingLine: Int
            let commit: GraphQLCommitNode
        }
        let data: DataBox?
    }

    static func parse(_ data: Data) throws -> [BlameRange] {
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard let ranges = response.data?.repository?.object?.blame?.ranges else {
            throw ParseError()
        }
        let iso = ISO8601DateFormatter()
        return ranges.map { node in
            BlameRange(start: node.startingLine, end: node.endingLine,
                       commit: node.commit.blameCommit(iso: iso))
        }
    }
}

/// GraphQL file-level history at a commit — GitHub has no line-history API,
/// so the History panel for PR files shows commits touching the whole file.
enum GitHubHistory {
    static let query = """
    query($owner: String!, $repo: String!, $expr: String!, $path: String!, $first: Int!) {
      repository(owner: $owner, name: $repo) {
        object(expression: $expr) {
          ... on Commit {
            history(first: $first, path: $path) {
              nodes {
                \(GraphQLCommitNode.queryFields)
              }
            }
          }
        }
      }
    }
    """

    struct ParseError: LocalizedError {
        var errorDescription: String? { "GitHub returned no history for this file." }
    }

    private struct Response: Decodable {
        struct DataBox: Decodable { let repository: Repo? }
        struct Repo: Decodable { let object: Object? }
        struct Object: Decodable { let history: History? }
        struct History: Decodable { let nodes: [GraphQLCommitNode] }
        let data: DataBox?
    }

    static func parse(_ data: Data) throws -> [BlameCommit] {
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard let nodes = response.data?.repository?.object?.history?.nodes else {
            throw ParseError()
        }
        let iso = ISO8601DateFormatter()
        return nodes.map { $0.blameCommit(iso: iso) }
    }
}
