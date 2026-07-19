import Foundation

/// Assembles blame gutter runs and History panel data for the views. Pure
/// pieces (porcelain/log parsing, run coalescing, avatar tiering) live in
/// Core; this file only orchestrates git subprocesses and GraphQL/REST calls.
@MainActor
enum BlameService {
    // MARK: - Gutter runs

    /// PR files and browsed repo documents: GraphQL blame at a known commit.
    static func remotePayloads(client: GitHubClient, ref: PullRequestRef,
                               path: String, sha: String,
                               markdown: String) async throws -> [BlameRunPayload] {
        let ranges = try await client.blame(ref: ref, path: path, sha: sha)
        let viewer = await client.viewerIdentity()
        return BlameMapper.runs(blocks: MarkdownBlocks.split(markdown),
                                ranges: ranges, viewer: viewer)
    }

    /// Local files: `git blame --porcelain` is authoritative for the working
    /// tree (uncommitted lines included); when the repo has a github.com
    /// remote, GraphQL blame at HEAD enriches matching commits with avatar
    /// and commit URLs. Nil when the file is untracked / not in a repo.
    static func localPayloads(client: GitHubClient, fileURL: URL,
                              markdown: String) async -> [BlameRunPayload]? {
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
                    commit.userAvatarUrl = rich.userAvatarUrl
                    commit.actorAvatarUrl = rich.actorAvatarUrl
                    commit.url = rich.url
                } else if !commit.isUncommitted {
                    // Even without GraphQL (no auth), link the commit page.
                    commit.url = "https://github.com/\(remote.owner)/\(remote.repo)/commit/\(commit.sha)"
                }
                return BlameRange(start: range.start, end: range.end, commit: commit)
            }
        }
        let viewer = await client.viewerIdentity()
        return BlameMapper.runs(blocks: MarkdownBlocks.split(markdown),
                                ranges: ranges, viewer: viewer)
    }

    // MARK: - History panel

    /// PR files: GitHub has no line-history API, so the panel honestly shows
    /// file-level history at the PR's head commit, split into commits on the
    /// PR branch vs commits already on the base branch (divider omitted when
    /// the PR-commit fetch fails).
    static func remoteHistory(client: GitHubClient, ref: PullRequestRef,
                              path: String, sha: String) async throws -> HistoryPanelData {
        let commits = try await client.fileHistory(ref: ref, path: path, sha: sha)
        let viewer = await client.viewerIdentity()
        var entries = HistoryBuilder.entries(from: commits, viewer: viewer)
        var baseStart: Int?
        if ref.number > 0, let prSHAs = try? await client.prCommitSHAs(ref) {
            (entries, baseStart) = HistoryBuilder.partition(entries: entries,
                                                            prSHAs: Set(prSHAs))
        }
        return HistoryPanelData(
            title: "File history",
            subtitle: (path as NSString).lastPathComponent,
            note: "GitHub has no line-level history — showing the latest commits that touched this file.",
            entries: entries,
            baseStart: baseStart)
    }

    /// Local files: true line history via `git log -L`; falls back to
    /// file-level history when the line range doesn't resolve (e.g. the
    /// working tree drifted from HEAD).
    static func localHistory(client: GitHubClient, fileURL: URL,
                             lineStart: Int, lineEnd: Int) async -> HistoryPanelData {
        struct Info {
            let lineCommits: [BlameCommit]?
            let fileCommits: [BlameCommit]?
            let remote: (owner: String, repo: String)?
        }
        let info = await Task.detached(priority: .userInitiated) { () -> Info in
            let lineCommits = LocalGit.lineHistory(of: fileURL, start: lineStart, end: lineEnd)
            let fileCommits = lineCommits == nil ? LocalGit.fileHistory(of: fileURL) : nil
            let remote = LocalGit.repoRoot(for: fileURL).flatMap { LocalGit.githubRemote(in: $0) }
            return Info(lineCommits: lineCommits, fileCommits: fileCommits, remote: remote)
        }.value

        var commits = info.lineCommits ?? info.fileCommits ?? []
        if let remote = info.remote {
            commits = commits.map { commit in
                var linked = commit
                linked.url = "https://github.com/\(remote.owner)/\(remote.repo)/commit/\(commit.sha)"
                return linked
            }
        }
        let viewer = await client.viewerIdentity()
        let entries = HistoryBuilder.entries(from: commits, viewer: viewer)
        let file = fileURL.lastPathComponent
        if info.lineCommits != nil {
            return HistoryPanelData(title: "Line history",
                                    subtitle: "\(file) — lines \(lineStart)–\(lineEnd)",
                                    note: nil, entries: entries)
        }
        if info.fileCommits != nil {
            return HistoryPanelData(
                title: "File history",
                subtitle: file,
                note: "Line-level history was unavailable for lines \(lineStart)–\(lineEnd) — showing commits that touched the whole file.",
                entries: entries)
        }
        return HistoryPanelData(title: "History", subtitle: file,
                                note: "History unavailable — the file may not be tracked by git.",
                                entries: [])
    }
}
