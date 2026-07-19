import Testing
@testable import PullMark

@Suite struct MarkdownCopyTests {
    let doc = """
    # Title

    First paragraph
    spanning two lines.

    - list item
    """

    @Test func nilRangeCopiesWholeDocument() {
        #expect(MarkdownCopy.source(of: doc, lineRange: nil) == doc)
    }

    @Test func rangeCopiesCoveredLines() {
        #expect(MarkdownCopy.source(of: doc, lineRange: (start: 3, end: 4))
                == "First paragraph\nspanning two lines.")
        #expect(MarkdownCopy.source(of: doc, lineRange: (start: 1, end: 1)) == "# Title")
        #expect(MarkdownCopy.source(of: doc, lineRange: (start: 6, end: 6)) == "- list item")
    }

    @Test func rangeIsClampedToTheDocument() {
        // Blocks annotated against a stale render can overshoot; clamp
        // rather than fail.
        #expect(MarkdownCopy.source(of: doc, lineRange: (start: 0, end: 2)) == "# Title\n")
        #expect(MarkdownCopy.source(of: doc, lineRange: (start: 6, end: 99)) == "- list item")
    }

    @Test func unsatisfiableRangeFallsBackToWholeDocument() {
        #expect(MarkdownCopy.source(of: doc, lineRange: (start: 50, end: 60)) == doc)
        #expect(MarkdownCopy.source(of: doc, lineRange: (start: 4, end: 2)) == doc)
    }

    @Test func wholeRangeEqualsWholeDocument() {
        #expect(MarkdownCopy.source(of: doc, lineRange: (start: 1, end: 6)) == doc)
    }

    @Test func emptyDocument() {
        #expect(MarkdownCopy.source(of: "", lineRange: nil) == "")
        #expect(MarkdownCopy.source(of: "", lineRange: (start: 1, end: 3)) == "")
    }
}
