import Foundation
import Testing
@testable import PullMark

struct GitHubLinkTests {
    @Test func fileLinkUsesBlob() {
        #expect(GitHubLink.url(owner: "acme", repo: "docs", ref: "main",
                               path: "guides/setup.md", isDirectory: false)
            == "https://github.com/acme/docs/blob/main/guides/setup.md")
    }

    @Test func directoryLinkUsesTree() {
        #expect(GitHubLink.url(owner: "acme", repo: "docs", ref: "main",
                               path: "guides", isDirectory: true)
            == "https://github.com/acme/docs/tree/main/guides")
    }

    @Test func repoRootIsBareTreeRef() {
        #expect(GitHubLink.url(owner: "acme", repo: "docs", ref: "main",
                               path: "", isDirectory: true)
            == "https://github.com/acme/docs/tree/main")
    }

    @Test func slashesInBranchNamesSurvive() {
        #expect(GitHubLink.url(owner: "acme", repo: "docs", ref: "feature/foo",
                               path: "a.md", isDirectory: false)
            == "https://github.com/acme/docs/blob/feature/foo/a.md")
    }

    @Test func awkwardCharactersEncodePerSegment() {
        #expect(GitHubLink.url(owner: "acme", repo: "docs", ref: "wip#2",
                               path: "release notes/1.0 plan.md", isDirectory: false)
            == "https://github.com/acme/docs/blob/wip%232/release%20notes/1.0%20plan.md")
    }

    @Test func permalinkFormIsJustASHARef() {
        #expect(GitHubLink.url(owner: "acme", repo: "docs", ref: "0123abc",
                               path: "a.md", isDirectory: false)
            == "https://github.com/acme/docs/blob/0123abc/a.md")
    }

    // MARK: - inRepository

    private func makeTempTree() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gh-link-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("repo/docs"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("plain"), withIntermediateDirectories: true)
        return root
    }

    @Test func findsGitDirectoryAncestor() throws {
        let root = try makeTempTree()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("repo/.git"), withIntermediateDirectories: true)
        let file = root.appendingPathComponent("repo/docs/a.md")
        #expect(GitHubLink.inRepository(file, isDirectory: false))
        #expect(GitHubLink.inRepository(root.appendingPathComponent("repo"), isDirectory: true))
    }

    @Test func worktreeGitFileCounts() throws {
        let root = try makeTempTree()
        defer { try? FileManager.default.removeItem(at: root) }
        // Linked worktrees carry a .git FILE pointing at the real gitdir.
        try "gitdir: /elsewhere/.git/worktrees/wt"
            .write(to: root.appendingPathComponent("repo/.git"),
                   atomically: true, encoding: .utf8)
        let file = root.appendingPathComponent("repo/docs/a.md")
        #expect(GitHubLink.inRepository(file, isDirectory: false))
    }

    @Test func outsideAnyCheckoutIsFalse() throws {
        let root = try makeTempTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("plain/a.md")
        #expect(!GitHubLink.inRepository(file, isDirectory: false))
    }

    @Test func bridgedNSURLTerminatesAtTheRoot() throws {
        // AppKit hands out NSURL-backed URLs whose
        // deletingLastPathComponent grows "../" past "/" forever — the
        // exact form that beachballed the sidebar. The string-based walk
        // must terminate (and say no) for one of these.
        let root = try makeTempTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let bridged = NSURL(fileURLWithPath: root.appendingPathComponent("plain/a.md").path) as URL
        #expect(!GitHubLink.inRepository(bridged, isDirectory: false))
    }
}
