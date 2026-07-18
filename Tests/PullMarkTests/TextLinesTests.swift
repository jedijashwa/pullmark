import Foundation
import Testing
@testable import PullMark

@Suite struct TextLinesTests {
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
