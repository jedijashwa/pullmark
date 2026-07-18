import Testing
@testable import PullMark

@Suite struct WordDiffTests {
    @Test func tokenizeRoundTrips() {
        let text = "Hello, world!  This is **bold** text.\nNew line."
        #expect(WordDiff.tokenize(text).joined() == text)
    }

    @Test func marksOnlyChangedWords() throws {
        let markup = try #require(WordDiff.markup(
            old: "This release fixes several bugs.",
            new: "This release adds dark mode and fixes several bugs."
        ))
        #expect(markup.merged.contains(WordDiff.insertOpen + "adds dark mode and " + WordDiff.insertClose))
        #expect(!markup.merged.contains(WordDiff.deleteOpen))
        #expect(markup.old == "This release fixes several bugs.")
        #expect(markup.new.contains(WordDiff.insertOpen))
        #expect(markup.new.replacingOccurrences(of: WordDiff.insertOpen, with: "")
            .replacingOccurrences(of: WordDiff.insertClose, with: "")
            == "This release adds dark mode and fixes several bugs.")
    }

    @Test func replacementMarksBothSides() throws {
        let markup = try #require(WordDiff.markup(
            old: "The quick brown fox",
            new: "The quick red fox"
        ))
        #expect(markup.merged.contains(WordDiff.deleteOpen + "brown" + WordDiff.deleteClose))
        #expect(markup.merged.contains(WordDiff.insertOpen + "red" + WordDiff.insertClose))
        #expect(markup.old.contains(WordDiff.deleteOpen + "brown" + WordDiff.deleteClose))
        #expect(!markup.old.contains(WordDiff.insertOpen))
        #expect(markup.new.contains(WordDiff.insertOpen + "red" + WordDiff.insertClose))
        #expect(!markup.new.contains(WordDiff.deleteOpen))
    }

    @Test func codeFencesFallBack() {
        #expect(WordDiff.markup(old: "```\nlet a = 1\n```", new: "```\nlet a = 2\n```") == nil)
    }

    @Test func dissimilarBlocksFallBack() {
        #expect(WordDiff.markup(
            old: "Completely different content about apples and oranges here.",
            new: "Nothing in common with the previous paragraph whatsoever, sorry."
        ) == nil)
    }

    @Test func identicalWhitespaceOnlyChangeIsHarmless() {
        // Whitespace-only differences produce no visible marks.
        if let markup = WordDiff.markup(old: "a  b", new: "a b") {
            #expect(!markup.merged.contains(WordDiff.insertOpen))
            #expect(!markup.merged.contains(WordDiff.deleteOpen))
        }
    }
}
