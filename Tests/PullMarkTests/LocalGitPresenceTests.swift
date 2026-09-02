import Testing
import Foundation
@testable import PullMark

/// Integration tests for the GitHub-presence index against a real
/// throwaway repo with a bare "origin": every reason the menu subtitle
/// can give, produced by git itself (spec: copy-github-link §8).
@Suite("LocalGit presence index")
struct LocalGitPresenceTests {
    private struct Repo {
        let root: URL
        let remote: URL
        func git(_ args: [String]) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["git", "-C", root.path, "-c", "user.email=t@t", "-c", "user.name=t"] + args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
        }
        func write(_ path: String, _ text: String = "# doc\n") throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func makeRepo() throws -> Repo {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pm-presence-\(UUID().uuidString)")
        let root = base.appendingPathComponent("work")
        let remote = base.appendingPathComponent("origin.git")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repo = Repo(root: root, remote: remote)
        repo.git(["init", "-q", "-b", "main"])
        repo.git(["init", "-q", "--bare", remote.path])
        repo.git(["remote", "add", "origin", remote.path])
        try repo.write("README.md")
        try repo.write("docs/setup.md")
        try repo.write(".gitignore", "build/\n")
        repo.git(["add", "-A"])
        repo.git(["commit", "-q", "-m", "init"])
        repo.git(["push", "-q", "-u", "origin", "main"])
        // Every reason, one file each.
        try repo.write("docs/new-since-push.md")
        repo.git(["add", "docs/new-since-push.md"])
        repo.git(["commit", "-q", "-m", "unpushed"])
        try repo.write("docs/staged.md")
        repo.git(["add", "docs/staged.md"])
        try repo.write("scratch.md")
        try repo.write("build/out.md")
        try repo.write("notes/private.md")
        try "notes/\n".write(to: root.appendingPathComponent(".git/info/exclude"),
                             atomically: true, encoding: .utf8)
        return repo
    }

    private let paths = ["README.md", "docs/setup.md", "docs/new-since-push.md", "docs/staged.md",
                         "scratch.md", "build/out.md", "notes/private.md"]

    private func classify(_ info: LocalGit.RepoInfo?, _ path: String,
                          directory: Bool = false) -> GitHubPresence.State {
        GitHubPresence.classify(relativePath: path, isDirectory: directory, index: info?.presence)
    }

    @Test func everyReasonFromRealGit() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo.root.deletingLastPathComponent()) }
        let info = LocalGit.repoInfo(forDirectory: repo.root, markdownPaths: paths)
        #expect(info?.upstreamExists == true)
        #expect(classify(info, "README.md") == .onGitHub)
        #expect(classify(info, "docs/setup.md") == .onGitHub)
        #expect(classify(info, "docs/new-since-push.md") == .absent(.notPushed))
        #expect(classify(info, "docs/staged.md") == .absent(.notCommitted))
        #expect(classify(info, "scratch.md") == .absent(.notCommitted))
        #expect(classify(info, "build/out.md") == .absent(.ignoredByGitignore))
        #expect(classify(info, "notes/private.md") == .absent(.ignoredLocally))
        #expect(classify(info, "docs", directory: true) == .onGitHub)
        #expect(classify(info, "build", directory: true) == .absent(.notCommitted))
    }

    @Test func branchWithoutUpstreamIsNotPushed() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo.root.deletingLastPathComponent()) }
        repo.git(["checkout", "-q", "-b", "feature"])
        let info = LocalGit.repoInfo(forDirectory: repo.root, markdownPaths: paths)
        #expect(info?.upstreamExists == false)
        #expect(classify(info, "README.md") == .absent(.notPushed))
        // Ignore and commit state still outrank the branch state.
        #expect(classify(info, "build/out.md") == .absent(.ignoredByGitignore))
        #expect(classify(info, "scratch.md") == .absent(.notCommitted))
    }

    @Test func subfolderRootsProbeWithTheRightPrefix() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo.root.deletingLastPathComponent()) }
        try repo.write("docs/ignored.md")
        try repo.write("docs/.gitignore", "ignored.md\n")
        repo.git(["add", "docs/.gitignore"])
        repo.git(["commit", "-q", "-m", "nested ignore"])
        // A Location opened at docs/ passes docs-relative paths; the index
        // keys stay toplevel-relative.
        let info = LocalGit.repoInfo(forDirectory: repo.root.appendingPathComponent("docs"),
                                     markdownPaths: ["setup.md", "ignored.md"])
        #expect(classify(info, "docs/ignored.md") == .absent(.ignoredByGitignore))
        #expect(classify(info, "docs/setup.md") == .onGitHub)
    }

    @Test func fingerprintIsStableAcrossIdenticalReads() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo.root.deletingLastPathComponent()) }
        let a = LocalGit.repoInfo(forDirectory: repo.root, markdownPaths: paths)
        let b = LocalGit.repoInfo(forDirectory: repo.root, markdownPaths: paths)
        #expect(a == b)
        repo.git(["add", "scratch.md"])
        let c = LocalGit.repoInfo(forDirectory: repo.root, markdownPaths: paths)
        #expect(a != c)
    }
}
