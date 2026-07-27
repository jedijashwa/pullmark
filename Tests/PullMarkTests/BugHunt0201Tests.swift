import Testing
import Foundation
@testable import PullMark

@Suite("0.20.1 bug-hunt regressions")
struct BugHunt0201Tests {

    @Test("CRLF blank lines split blocks like LF ones")
    func crlfBlocks() {
        let lf = "# Title\n\npara one\n\npara two"
        let crlf = lf.replacingOccurrences(of: "\n", with: "\r\n")
        #expect(MarkdownBlocks.split(lf).count == 3)
        #expect(MarkdownBlocks.split(crlf).count == 3)
    }

    @Test("A leading thematic break is not front matter")
    func thematicBreakIsNotFrontMatter() {
        let doc = "---\n# Title\n---\nbody"
        let blocks = MarkdownBlocks.split(doc)
        #expect(!blocks.contains { MarkdownBlocks.isFrontMatter($0) })
        let real = "---\ntitle: Doc\n---\nbody"
        #expect(MarkdownBlocks.split(real).contains { MarkdownBlocks.isFrontMatter($0) })
    }

    @Test("ATX closing hashes don't leak into heading slugs")
    func closingHashSlugs() {
        let headings = OpenQuickly.headings(in: "## Overview ##\n\ntext\n\n## Plain\n")
        #expect(headings.map(\.0) == ["Overview", "Plain"])
        #expect(headings.map(\.1) == ["overview", "plain"])
    }

    @Test("LEFT-side comments match old-side ranges, never cross-side nearest")
    func leftPlacement() {
        let segments = [
            DiffSegmentPayload(kind: "unchanged", text: "intro", oldText: nil,
                               lineStart: 1, lineEnd: 3, side: "RIGHT",
                               oldLineStart: 1, oldLineEnd: 3),
            DiffSegmentPayload(kind: "modified", text: "new body", oldText: "old body",
                               lineStart: 50, lineEnd: 52, side: "RIGHT",
                               oldLineStart: 10, oldLineEnd: 12),
        ]
        func left(_ id: Int, line: Int) -> ReviewThread {
            ReviewThread(root: ReviewComment(
                id: id, path: "doc.md", body: "b", line: line, side: "LEFT",
                startLine: nil, originalLine: nil, subjectType: nil,
                inReplyToId: nil, user: .init(login: "a"),
                createdAt: nil, htmlUrl: nil), replies: [])
        }
        let thread = left(1, line: 11)
        let placed = ReviewThreads.place([thread], in: segments)
        #expect(placed.segments[1].threads?.count == 1)
        #expect(placed.segments[0].threads == nil)
        // An anchor matching nothing goes to outdated, not nearest.
        let stray = left(2, line: 400)
        let placed2 = ReviewThreads.place([stray], in: segments)
        #expect(placed2.outdated.count == 1)
    }

    @Test("Relaunch command survives hostile paths")
    func relaunchQuoting() {
        let command = BrewUpdate.relaunchShellCommand(
            appPath: "/Apps/It's \"Fun\" $HOME `x`/PullMark.app")
        #expect(command.contains("'"))
        #expect(!command.contains("\"/Apps"))
        // Must not leave the path bare for interpolation.
        #expect(command.contains("'\\''"))
    }
}
