import Foundation

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
                  oid
                  abbreviatedOid
                  messageHeadline
                  committedDate
                  url
                  author { name avatarUrl user { login url } }
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
            let commit: CommitNode
        }
        struct CommitNode: Decodable {
            let oid: String
            let messageHeadline: String?
            let committedDate: String?
            let url: String?
            let author: Author?
        }
        struct Author: Decodable {
            let name: String?
            let avatarUrl: String?
            let user: User?
        }
        struct User: Decodable { let login: String? }
        let data: DataBox?
    }

    static func parse(_ data: Data) throws -> [BlameRange] {
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard let ranges = response.data?.repository?.object?.blame?.ranges else {
            throw ParseError()
        }
        let iso = ISO8601DateFormatter()
        return ranges.map { node in
            BlameRange(
                start: node.startingLine,
                end: node.endingLine,
                commit: BlameCommit(
                    sha: node.commit.oid,
                    authorName: node.commit.author?.name
                        ?? node.commit.author?.user?.login ?? "unknown",
                    date: node.commit.committedDate.flatMap { iso.date(from: $0) },
                    summary: node.commit.messageHeadline ?? "",
                    avatarUrl: node.commit.author?.avatarUrl,
                    url: node.commit.url
                )
            )
        }
    }
}
