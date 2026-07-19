import Testing
@testable import PullMark

@Suite struct ContentSearchTests {
    @Test func findsCaseInsensitiveMatches() {
        let text = "# Mermaid diagrams\n\nUse mermaid fences.\nNothing here."
        let matches = ContentSearch.matches(in: text, query: "MERMAID")
        #expect(matches.count == 2)
        #expect(matches[0].lineNumber == 1)
        #expect(matches[0].lineText == "# Mermaid diagrams")
        #expect(matches[1].lineNumber == 3)
        #expect(matches[1].lineText == "Use mermaid fences.")
    }

    @Test func reportsEveryOccurrenceOnALine() {
        let matches = ContentSearch.matches(in: "abc ABC aBc", query: "abc")
        #expect(matches.count == 1)
        let match = matches[0]
        #expect(match.ranges.count == 3)
        #expect(match.ranges.map { String(match.lineText[$0]) } == ["abc", "ABC", "aBc"])
    }

    @Test func lineNumbersAreOneBasedAndCountEmptyLines() {
        let text = "one\n\n\nfour target\nfive\ntarget"
        let matches = ContentSearch.matches(in: text, query: "target")
        #expect(matches.map(\.lineNumber) == [4, 6])
    }

    @Test func emptyAndWhitespaceQueriesMatchNothing() {
        let text = "some content\nmore content"
        #expect(ContentSearch.matches(in: text, query: "").isEmpty)
        #expect(ContentSearch.matches(in: text, query: "   ").isEmpty)
        #expect(ContentSearch.matches(in: text, query: "\n").isEmpty)
    }

    @Test func noMatchesReturnsEmpty() {
        #expect(ContentSearch.matches(in: "alpha\nbeta", query: "gamma").isEmpty)
    }

    @Test func rangesIndexIntoReportedLineText() {
        let matches = ContentSearch.matches(in: "The Mermaid docs", query: "mermaid")
        #expect(matches.count == 1)
        let match = matches[0]
        #expect(match.ranges.count == 1)
        #expect(String(match.lineText[match.ranges[0]]) == "Mermaid")
    }

    @Test func stripsCarriageReturnsFromWindowsLineEndings() {
        let matches = ContentSearch.matches(in: "first term\r\nsecond\r\n", query: "term")
        #expect(matches.count == 1)
        #expect(matches[0].lineText == "first term")
        #expect(matches[0].lineNumber == 1)
    }

    @Test func overlappingOccurrencesAdvancePastEachMatch() {
        // "aaaa" contains "aa" at 0-1 and 2-3 when scanning forward.
        let matches = ContentSearch.matches(in: "aaaa", query: "aa")
        #expect(matches.count == 1)
        #expect(matches[0].ranges.count == 2)
    }
}
