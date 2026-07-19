import Foundation
import Testing
@testable import PullMark

@Suite struct TextLinesTests {
    @Test func replacingSwapsExactLineRange() {
        let text = "one\ntwo\nthree\nfour\n"
        #expect(TextLines.replacing(in: text, from: 2, to: 3, with: "TWO\nTHREE")
            == "one\nTWO\nTHREE\nfour\n")
        // Different line count in the replacement is fine.
        #expect(TextLines.replacing(in: text, from: 2, to: 3, with: "swapped")
            == "one\nswapped\nfour\n")
    }

    @Test func replacingWithEmptyDeletesTheLines() {
        #expect(TextLines.replacing(in: "a\nb\nc\n", from: 2, to: 2, with: "")
            == "a\nc\n")
    }

    @Test func replacingPreservesTrailingNewlineAndBounds() {
        #expect(TextLines.replacing(in: "a\nb", from: 2, to: 2, with: "B") == "a\nB")
        #expect(TextLines.replacing(in: "a\nb", from: 0, to: 1, with: "x") == nil)
        #expect(TextLines.replacing(in: "a\nb", from: 2, to: 3, with: "x") == nil)
        // Round-trip: extracting then replacing with the same text is identity.
        let doc = "# H\n\npara one\n\npara two\n"
        let seed = TextLines.lines(in: doc, from: 3, to: 3)!
        #expect(TextLines.replacing(in: doc, from: 3, to: 3, with: seed) == doc)
    }

    let text = "one\ntwo\nthree\nfour"

    @Test func extractsRange() {
        #expect(TextLines.lines(in: text, from: 2, to: 3) == "two\nthree")
        #expect(TextLines.lines(in: text, from: 1, to: 1) == "one")
        #expect(TextLines.lines(in: text, from: 4, to: 4) == "four")
    }

    @Test func rejectsOutOfBounds() {
        #expect(TextLines.lines(in: text, from: 0, to: 2) == nil)
        #expect(TextLines.lines(in: text, from: 3, to: 2) == nil)
        #expect(TextLines.lines(in: text, from: 2, to: 5) == nil)
    }

    @Test func remoteSchemePathValidation() {
        let good = URL(string: "pullmark-remote:///docs/img/a.png")!
        #expect(RemoteResourceSchemeHandler.repoPath(from: good) == "docs/img/a.png")
        let traversal = URL(string: "pullmark-remote:///../secrets")!
        #expect(RemoteResourceSchemeHandler.repoPath(from: traversal) == nil)
        let empty = URL(string: "pullmark-remote:///")!
        #expect(RemoteResourceSchemeHandler.repoPath(from: empty) == nil)
    }
}
