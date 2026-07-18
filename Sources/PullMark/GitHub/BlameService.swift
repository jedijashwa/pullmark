import Foundation

/// Assembles per-block blame payloads for the views. Pure pieces (porcelain
/// parsing, range→block mapping) live in Core; this file only orchestrates
/// git subprocesses and the GraphQL call.
@MainActor
enum BlameService {
    /// PR files and browsed repo documents: GraphQL blame at a known commit.
    static func remotePayloads(client: GitHubClient, ref: PullRequestRef,
                               path: String, sha: String,
                               markdown: String) async throws -> [BlockBlamePayload] {
        let ranges = try await client.blame(ref: ref, path: path, sha: sha)
        return BlameMapper.annotations(blocks: MarkdownBlocks.split(markdown), ranges: ranges)
    }

    /// Local files: `git blame --porcelain` is authoritative for the working
    /// tree (uncommitted lines included); when the repo has a github.com
    /// remote, GraphQL blame at HEAD enriches matching commits with avatar
    /// and commit URLs. Nil when the file is untracked / not in a repo.
    static func localPayloads(client: GitHubClient, fileURL: URL,
                              markdown: String) async -> [BlockBlamePayload]? {
        struct RepoInfo {
            let ranges: [BlameRange]
            let remote: (owner: String, repo: String)?
            let headSHA: String?
            let relativePath: String?
        }
        let info = await Task.detached(priority: .userInitiated) { () -> RepoInfo? in
            guard let ranges = LocalGit.blame(of: fileURL) else { return nil }
            guard let root = LocalGit.repoRoot(for: fileURL) else {
                return RepoInfo(ranges: ranges, remote: nil, headSHA: nil, relativePath: nil)
            }
            return RepoInfo(ranges: ranges,
                            remote: LocalGit.githubRemote(in: root),
                            headSHA: LocalGit.headSHA(in: root),
                            relativePath: LocalGit.relativePath(of: fileURL, in: root))
        }.value
        guard let info else { return nil }

        var ranges = info.ranges
        if let remote = info.remote {
            var enrichment: [String: BlameCommit] = [:]
            if let sha = info.headSHA, let rel = info.relativePath,
               let remoteRanges = try? await client.blame(
                   ref: PullRequestRef(owner: remote.owner, repo: remote.repo, number: 0),
                   path: rel, sha: sha) {
                for range in remoteRanges { enrichment[range.commit.sha] = range.commit }
            }
            ranges = ranges.map { range in
                var commit = range.commit
                if let rich = enrichment[commit.sha] {
                    commit.avatarUrl = rich.avatarUrl
                    commit.url = rich.url
                } else if !commit.isUncommitted {
                    // Even without GraphQL (no auth), link the commit page.
                    commit.url = "https://github.com/\(remote.owner)/\(remote.repo)/commit/\(commit.sha)"
                }
                return BlameRange(start: range.start, end: range.end, commit: commit)
            }
        }
        return BlameMapper.annotations(blocks: MarkdownBlocks.split(markdown), ranges: ranges)
    }
}
