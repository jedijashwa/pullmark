import Testing
import Foundation
@testable import PullMark

/// Order-of-magnitude guards, not benchmarks: ceilings are generous so CI
/// noise never fails them, but a quadratic regression (or losing BlockDiff's
/// 4M-cell LCS guard) blows straight through.
@Suite("Performance smoke")
struct PerformanceSmokeTests {
    private func document(blocks: Int, seed: String = "") -> String {
        (0..<blocks)
            .map { "Paragraph \(seed)\($0) with **bold** text and a [link](https://example.com/\($0))." }
            .joined(separator: "\n\n")
    }

    @Test func tenThousandBlockDiffStaysBounded() {
        // 10k×10k blocks is far past the LCS guard (4M cells): BlockDiff
        // must fall back to remove+add instead of building a 100M-cell table.
        let old = document(blocks: 10_000)
        let new = document(blocks: 10_000, seed: "x")
        let elapsed = ContinuousClock().measure {
            let diff = BlockDiff.diff(old: MarkdownBlocks.split(old),
                                      new: MarkdownBlocks.split(new))
            #expect(diff.count >= 10_000)
        }
        #expect(elapsed < .seconds(5))
    }

    @Test func largestTrueLCSDiffStaysInteractive() {
        // 1900×1900 ≈ 3.6M cells — just under the guard, so this exercises
        // the real DP table at its worst allowed size.
        let oldBlocks = (0..<1_900).map { "Block \($0) with unchanged prose." }
        var newBlocks = oldBlocks
        for i in stride(from: 0, to: newBlocks.count, by: 50) {
            newBlocks[i] += " edited"
        }
        let old = oldBlocks.joined(separator: "\n\n")
        let new = newBlocks.joined(separator: "\n\n")
        let elapsed = ContinuousClock().measure {
            let diff = BlockDiff.diff(old: MarkdownBlocks.split(old),
                                      new: MarkdownBlocks.split(new))
            let modified = diff.filter { if case .modified = $0 { return true }; return false }
            #expect(modified.count == 38)
        }
        #expect(elapsed < .seconds(5))
    }

    @Test func megabyteSingleParagraphSplits() {
        // One 1.5MB paragraph on a single line — the splitter must stay
        // linear, and WordDiff against a slightly edited copy must respect
        // its own size limits rather than going quadratic.
        let words = (0..<150_000).map { "word\($0)" }.joined(separator: " ")
        var edited = words
        edited.replaceSubrange(edited.range(of: "word75000")!, with: "changed75000")
        let elapsed = ContinuousClock().measure {
            let blocks = MarkdownBlocks.split("# Title\n\n" + words)
            #expect(blocks.count == 2)
            _ = WordDiff.markup(old: words, new: edited)
        }
        #expect(elapsed < .seconds(5))
    }
}
