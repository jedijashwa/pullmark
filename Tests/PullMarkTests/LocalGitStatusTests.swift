import Testing
import Foundation
@testable import PullMark

/// Integration tests against a real throwaway repo — the porcelain parser's
/// failure modes (C-quoted unicode paths, rename old-path fields) only show
/// up with actual git output.
@Suite("LocalGit status parsing")
struct LocalGitStatusTests {
    private func makeRepo() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pm-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        func git(_ args: [String]) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["git", "-C", root.path] + args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
        }
        git(["init", "-q"])
        git(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "init"])
        try "old\n".write(to: root.appendingPathComponent("base.md"), atomically: true, encoding: .utf8)
        try "hi\n".write(to: root.appendingPathComponent("résumé file.md"), atomically: true, encoding: .utf8)
        git(["add", "-A"])
        git(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "add"])
        git(["mv", "base.md", "moved.md"])
        try "hi edited\n".write(to: root.appendingPathComponent("résumé file.md"), atomically: true, encoding: .utf8)
        try "new\n".write(to: root.appendingPathComponent("untracked.md"), atomically: true, encoding: .utf8)
        return root
    }

    @Test func parsesUnicodeRenamesAndUntracked() throws {
        let root = try makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = LocalGit.changedFiles(in: root)
        let byPath = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) })

        // Unicode path arrives unmangled, not C-quoted.
        #expect(byPath["résumé file.md"] != nil)
        #expect(byPath["résumé file.md"]?.stagePaths == ["résumé file.md"])
        #expect(byPath["untracked.md"]?.status == "??")
        // The rename shows its new name but stages BOTH sides.
        let rename = try #require(byPath["moved.md"])
        #expect(rename.status.hasPrefix("R"))
        #expect(Set(rename.stagePaths) == Set(["moved.md", "base.md"]))
    }

    @Test func commitStagesRenamesWhole() throws {
        let root = try makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        let rename = try #require(LocalGit.changedFiles(in: root).first { $0.path == "moved.md" })
        // Committing via stagePaths must land the deletion half too.
        let failure = LocalGit.commit(paths: rename.stagePaths,
                                      message: "rename", in: root)
        #expect(failure == nil)
        let after = LocalGit.changedFiles(in: root).map(\.path)
        #expect(!after.contains("moved.md"))
        #expect(!after.contains("base.md"))
    }

    // MARK: - Tracked paths (Copy GitHub Link's render gate)

    @Test func parseTrackedPathsBuildsFilesAndAncestorDirs() {
        let parsed = LocalGit.parseTrackedPaths(
            "a.md\0docs/guide/setup.md\0docs/intro.md\0r\u{00E9}sum\u{00E9} dir/nested/n.md\0")
        #expect(parsed.files == ["a.md", "docs/guide/setup.md", "docs/intro.md",
                                 "r\u{00E9}sum\u{00E9} dir/nested/n.md"])
        #expect(parsed.dirs == ["docs", "docs/guide",
                                "r\u{00E9}sum\u{00E9} dir", "r\u{00E9}sum\u{00E9} dir/nested"])
    }

    @Test func parseTrackedPathsEmptyOutput() {
        let parsed = LocalGit.parseTrackedPaths("")
        #expect(parsed.files.isEmpty)
        #expect(parsed.dirs.isEmpty)
    }

    @Test func repoInfoCarriesTrackedPaths() throws {
        let root = try makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        let info = try #require(LocalGit.repoInfo(forDirectory: root))
        let tracked = try #require(info.trackedPaths)
        // The rename is staged: moved.md is in the index, base.md is not.
        #expect(tracked.contains("moved.md"))
        #expect(!tracked.contains("base.md"))
        #expect(tracked.contains("r\u{00E9}sum\u{00E9} file.md"))
        // Untracked worktree files never appear.
        #expect(!tracked.contains("untracked.md"))
    }

    @Test func isTrackedAsksTheIndex() throws {
        let root = try makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(LocalGit.isTracked("moved.md", in: root))
        #expect(!LocalGit.isTracked("untracked.md", in: root))
        #expect(!LocalGit.isTracked("never-existed.md", in: root))
    }
}
