import Testing
@testable import PullMark

@Suite("Suggestion bodies")
struct SuggestionTests {
    @Test func plainReplacementUsesThreeBacktickFence() {
        let body = Suggestion.body(note: "", replacement: "New text here.")
        #expect(body == "```suggestion\nNew text here.\n```")
    }

    @Test func noteAppearsBelowTheBlockSoItCannotSwallowIt() {
        let body = Suggestion.body(note: "  Tightens the wording. ",
                                   replacement: "Better.")
        #expect(body == "```suggestion\nBetter.\n```\n\nTightens the wording.")
        // The hostile case that forces below-placement: an unclosed fence
        // in the note must not be able to absorb the suggestion opener.
        let hostile = Suggestion.body(note: "```", replacement: "x")
        #expect(hostile.hasPrefix("```suggestion\nx\n```"))
    }

    @Test func fenceOutgrowsEmbeddedCodeFences() {
        let replacement = "```swift\nlet x = 1\n```"
        let body = Suggestion.body(note: "", replacement: replacement)
        #expect(body.hasPrefix("````suggestion\n"))
        #expect(body.hasSuffix("\n````"))
        #expect(body.contains(replacement))
    }

    @Test func emptyReplacementIsADeletionSuggestion() {
        // Zero lines between the fences — GitHub's delete-lines form. A
        // blank line would instead replace the lines with one empty line.
        #expect(Suggestion.body(note: "", replacement: "") == "```suggestion\n```")
    }
}
