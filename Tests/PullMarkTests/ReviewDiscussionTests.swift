import Testing
import Foundation
@testable import PullMark

@Suite struct ReviewDiscussionTests {
    // MARK: Excerpts

    @Test func excerptKeepsHunkTailWithAnchorLast() {
        let hunk = """
        @@ -10,6 +10,7 @@ func load() {
         let a = 1
        -let b = 2
        +let b = load(2)
         let c = 3
         let d = 4
         let anchor = 5
        """
        let lines = ReviewDiscussion.excerpt(from: hunk)
        #expect(lines.count == 4)
        #expect(lines.first == .init(text: "let b = load(2)", kind: "add"))
        #expect(lines.last == .init(text: "let anchor = 5", kind: "ctx"))
    }

    @Test func excerptClassifiesKinds() {
        let hunk = "@@ -1,2 +1,2 @@\n ctx line\n-removed\n+added"
        let lines = ReviewDiscussion.excerpt(from: hunk)
        #expect(lines.map(\.kind) == ["ctx", "del", "add"])
        #expect(lines.map(\.text) == ["ctx line", "removed", "added"])
    }

    @Test func excerptDropsArtifacts() {
        // Trailing newline and no-newline markers must not displace the
        // anchor from the excerpt's last line.
        let hunk = "@@ -1 +1 @@\n+only line\n\\ No newline at end of file\n"
        let lines = ReviewDiscussion.excerpt(from: hunk)
        #expect(lines == [.init(text: "only line", kind: "add")])
    }

    @Test func excerptStripsCRLF() {
        // A raw CR inside white-space:pre renders as a spurious break.
        let lines = ReviewDiscussion.excerpt(from: "@@ -1 +1 @@\r\n+crlf line\r\n ctx\r")
        #expect(lines == [.init(text: "crlf line", kind: "add"),
                          .init(text: "ctx", kind: "ctx")])
    }

    @Test func excerptOfNothing() {
        #expect(ReviewDiscussion.excerpt(from: nil).isEmpty)
        #expect(ReviewDiscussion.excerpt(from: "").isEmpty)
    }

    // MARK: Languages

    @Test func languageMap() {
        #expect(CodeLanguages.hljsLanguage(forPath: "Sources/App/Main.swift") == "swift")
        #expect(CodeLanguages.hljsLanguage(forPath: "web/index.TS") == "typescript")
        #expect(CodeLanguages.hljsLanguage(forPath: "Dockerfile") == "dockerfile")
        #expect(CodeLanguages.hljsLanguage(forPath: "deep/path/Makefile") == "makefile")
        #expect(CodeLanguages.hljsLanguage(forPath: "notes.txt") == nil)
        #expect(CodeLanguages.hljsLanguage(forPath: "LICENSE") == nil)
    }

    // MARK: Grouping

    private func comment(id: Int, path: String, line: Int?,
                         originalLine: Int? = nil, inReplyTo: Int? = nil,
                         subjectType: String? = nil,
                         hunk: String? = nil) -> ReviewComment {
        ReviewComment(id: id, path: path, body: "c\(id)", line: line,
                      side: "RIGHT", startLine: nil,
                      originalLine: originalLine, subjectType: subjectType,
                      inReplyToId: inReplyTo,
                      user: .init(login: "u"), createdAt: nil,
                      htmlUrl: URL(string: "https://github.com/o/r/pull/1#discussion_r\(id)"),
                      diffHunk: hunk)
    }

    @Test func groupsFollowFileOrderThenAlpha() {
        let comments = [
            comment(id: 1, path: "src/lib.rs", line: 4),
            comment(id: 2, path: "docs/guide.md", line: 9),
            comment(id: 3, path: "zzz/gone.py", line: 1),
        ]
        let groups = ReviewDiscussion.groups(
            comments: comments, meta: [:], viewer: nil,
            markdownPaths: ["docs/guide.md"],
            fileOrder: ["docs/guide.md", "src/lib.rs"])
        #expect(groups.map(\.path) == ["docs/guide.md", "src/lib.rs", "zzz/gone.py"])
        #expect(groups[0].isMarkdown)
        #expect(!groups[1].isMarkdown)
    }

    @Test func renamedPathsJoinTheirNewGroup() {
        // A thread from before a rename carries the old path; it must
        // land in the renamed file's group, not a phantom group.
        let comments = [
            comment(id: 1, path: "docs/old-name.md", line: 3),
            comment(id: 2, path: "docs/new-name.md", line: 8),
        ]
        let groups = ReviewDiscussion.groups(
            comments: comments, meta: [:], viewer: nil,
            markdownPaths: ["docs/new-name.md"],
            fileOrder: ["docs/new-name.md"],
            renames: ["docs/old-name.md": "docs/new-name.md"])
        #expect(groups.count == 1)
        #expect(groups[0].path == "docs/new-name.md")
        #expect(groups[0].threads.count == 2)
        #expect(groups[0].isMarkdown)
    }

    @Test func missingMetaLeavesResolvedUnknown() {
        // Nil resolution (no GraphQL meta) must reach the page as nil so
        // cards suppress Resolve — and count as unresolved, matching the
        // sidebar-badge rule.
        let comments = [comment(id: 1, path: "a.swift", line: 3)]
        let groups = ReviewDiscussion.groups(
            comments: comments, meta: [:], viewer: nil,
            markdownPaths: [], fileOrder: ["a.swift"])
        #expect(groups[0].threads[0].resolved == nil)
        #expect(groups[0].unresolvedCount == 1)
    }

    @Test func threadsSortFileLevelThenByLine() {
        let comments = [
            comment(id: 5, path: "a.swift", line: 40),
            comment(id: 6, path: "a.swift", line: nil, originalLine: 12),
            comment(id: 7, path: "a.swift", line: nil, subjectType: "file"),
            comment(id: 8, path: "a.swift", line: 3),
        ]
        let groups = ReviewDiscussion.groups(
            comments: comments, meta: [:], viewer: nil,
            markdownPaths: [], fileOrder: ["a.swift"])
        let labels = groups[0].threads.map(\.lineLabel)
        #expect(labels == ["Whole file", "Line 3 (new)",
                           "Outdated — was line 12", "Line 40 (new)"])
        #expect(groups[0].threads[2].outdated)
    }

    @Test func repliesFoldIntoThreadAndResolutionCounts() {
        let comments = [
            comment(id: 1, path: "a.swift", line: 3, hunk: "@@ -1 +3 @@\n+x"),
            comment(id: 2, path: "a.swift", line: 3, inReplyTo: 1),
            comment(id: 3, path: "a.swift", line: 9),
        ]
        let meta = [1: ThreadMeta(nodeID: "n1", isResolved: true)]
        let groups = ReviewDiscussion.groups(
            comments: comments, meta: meta, viewer: nil,
            markdownPaths: [], fileOrder: ["a.swift"])
        #expect(groups[0].threads.count == 2)
        #expect(groups[0].threads[0].comments.count == 2)
        #expect(groups[0].threads[0].resolved == true)
        #expect(groups[0].unresolvedCount == 1)
        #expect(groups[0].threads[0].excerpt == [.init(text: "x", kind: "add")])
        #expect(groups[0].threads[0].htmlUrl?.fragment == "discussion_r1")
    }

    @Test func fileLevelThreadsCarryNoExcerpt() {
        let comments = [comment(id: 1, path: "a.swift", line: nil,
                                subjectType: "file", hunk: "@@ -1 +1 @@\n+x")]
        let groups = ReviewDiscussion.groups(
            comments: comments, meta: [:], viewer: nil,
            markdownPaths: [], fileOrder: ["a.swift"])
        #expect(groups[0].threads[0].excerpt.isEmpty)
    }
}
