import Testing
@testable import PullMark

@Suite("GitHub presence classifier")
struct GitHubPresenceTests {
    private func index(branchUnpushed: Bool = false) -> GitHubPresence.Index {
        GitHubPresence.Index(
            trackedFiles: ["README.md", "docs/setup.md", "docs/staged.md", "docs/new-since-push.md"],
            trackedDirs: ["docs"],
            stagedNew: ["docs/staged.md"],
            unpushed: ["docs/new-since-push.md"],
            branchUnpushed: branchUnpushed,
            ignored: ["build/out.md": .gitignore, "notes/private.md": .local],
            fingerprint: 1)
    }

    @Test func committedAndPushedFileIsOnGitHub() {
        #expect(GitHubPresence.classify(relativePath: "docs/setup.md", isDirectory: false, index: index()) == .onGitHub)
    }

    @Test func repoRootAlwaysLinks() {
        #expect(GitHubPresence.classify(relativePath: "", isDirectory: true, index: index()) == .onGitHub)
        #expect(GitHubPresence.classify(relativePath: "", isDirectory: true, index: nil) == .unknown)
    }

    @Test func eachReasonInOrder() {
        let i = index()
        #expect(GitHubPresence.classify(relativePath: "build/out.md", isDirectory: false, index: i) == .absent(.ignoredByGitignore))
        #expect(GitHubPresence.classify(relativePath: "notes/private.md", isDirectory: false, index: i) == .absent(.ignoredLocally))
        #expect(GitHubPresence.classify(relativePath: "scratch.md", isDirectory: false, index: i) == .absent(.notCommitted))
        #expect(GitHubPresence.classify(relativePath: "docs/staged.md", isDirectory: false, index: i) == .absent(.notCommitted))
        #expect(GitHubPresence.classify(relativePath: "docs/new-since-push.md", isDirectory: false, index: i) == .absent(.notPushed))
    }

    @Test func unpushedBranchMakesEveryCommittedFileNotPushed() {
        let i = index(branchUnpushed: true)
        #expect(GitHubPresence.classify(relativePath: "docs/setup.md", isDirectory: false, index: i) == .absent(.notPushed))
        // Ignored and uncommitted reasons still win over the branch state.
        #expect(GitHubPresence.classify(relativePath: "build/out.md", isDirectory: false, index: i) == .absent(.ignoredByGitignore))
        #expect(GitHubPresence.classify(relativePath: "scratch.md", isDirectory: false, index: i) == .absent(.notCommitted))
    }

    @Test func directoriesUseTrackedAncestry() {
        #expect(GitHubPresence.classify(relativePath: "docs", isDirectory: true, index: index()) == .onGitHub)
        #expect(GitHubPresence.classify(relativePath: "node_modules", isDirectory: true, index: index()) == .absent(.notCommitted))
    }

    @Test func missingIndexIsUnknown() {
        #expect(GitHubPresence.classify(relativePath: "docs/setup.md", isDirectory: false, index: nil) == .unknown)
    }

    @Test func indexEqualityIsByFingerprint() {
        let a = GitHubPresence.Index(trackedFiles: ["a"], trackedDirs: [], fingerprint: 7)
        let b = GitHubPresence.Index(trackedFiles: ["b"], trackedDirs: [], fingerprint: 7)
        let c = GitHubPresence.Index(trackedFiles: ["a"], trackedDirs: [], fingerprint: 8)
        #expect(a == b)
        #expect(a != c)
    }

    // MARK: - Parsers

    @Test func checkIgnoreQuadsClassifyBySource() {
        let output = [".gitignore", "3", "build/", "build/out.md",
                      "docs/.gitignore", "1", "*.tmp.md", "docs/draft.tmp.md",
                      ".git/info/exclude", "2", "notes/", "notes/private.md",
                      "/Users/me/.gitignore_global", "9", "*.secret.md", "keys.secret.md",
                      ""].joined(separator: "\0")
        let parsed = GitHubPresence.parseCheckIgnore(output)
        #expect(parsed["build/out.md"] == .gitignore)
        #expect(parsed["docs/draft.tmp.md"] == .gitignore)
        #expect(parsed["notes/private.md"] == .local)
        #expect(parsed["keys.secret.md"] == .local)
        #expect(parsed.count == 4)
    }

    @Test func emptyCheckIgnoreOutputIsEmpty() {
        #expect(GitHubPresence.parseCheckIgnore("").isEmpty)
    }

    @Test func pathListsDropEmptyEntries() {
        #expect(GitHubPresence.parsePathList("a.md\u{0}docs/b.md\u{0}\u{0}") == ["a.md", "docs/b.md"])
        #expect(GitHubPresence.parsePathList("").isEmpty)
    }
}
