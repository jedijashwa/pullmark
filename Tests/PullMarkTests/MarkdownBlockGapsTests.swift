import Testing
@testable import PullMark

@Suite("Markdown block gaps")
struct MarkdownBlockGapsTests {
    private func roundTrip(_ source: String) -> Bool {
        let blocks = MarkdownBlocks.split(source)
        let gaps = MarkdownBlocks.gaps(of: source, blocks: blocks)
        return MarkdownBlocks.assemble(blockTexts: blocks.map(\.text), gaps: gaps) == source
    }

    @Test func plainDocumentReassembles() {
        #expect(roundTrip("# Title\n\nSome text.\n\n- a\n- b\n"))
    }

    @Test func irregularSpacingSurvives() {
        // Two blank lines, a whitespace-only line, no trailing newline,
        // a leading blank line, CRLF endings.
        #expect(roundTrip("\n# T\n\n\nPara\n  \nNext"))
        #expect(roundTrip("a\r\n\r\nb\r\n"))
        #expect(roundTrip("only one block"))
        #expect(roundTrip(""))
    }

    @Test func fencesCommentsAndFrontMatterKeepTheirGaps() {
        let source = """
        ---
        title: x
        ---
        Right after front matter.

        ```js
        let a = 1;

        let b = 2;
        ```

        <!-- note @sam: two
        lines -->

        End.

        """
        #expect(roundTrip(source))
    }

    @Test func gapsAreExactlyTheDroppedText() {
        let source = "A\n\n\nB\n"
        let blocks = MarkdownBlocks.split(source)
        let gaps = MarkdownBlocks.gaps(of: source, blocks: blocks)
        #expect(gaps.leading == "")
        #expect(gaps.between == ["\n\n\n"])
        #expect(gaps.trailing == "\n")
        // An edited block drops into the same spacing.
        #expect(MarkdownBlocks.assemble(blockTexts: ["A2", "B"], gaps: gaps) == "A2\n\n\nB\n")
    }
}
