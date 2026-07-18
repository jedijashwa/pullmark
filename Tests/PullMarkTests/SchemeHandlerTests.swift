import Foundation
import Testing
@testable import PullMark

@Suite struct SchemeHandlerTests {
    private let root = URL(fileURLWithPath: "/Users/someone/notes")

    @Test func resolvesNestedRelativePath() throws {
        let url = try #require(URL(string: "pullmark-local:///img/pic%20one.png"))
        let resolved = LocalResourceSchemeHandler.resolve(url, root: root)
        #expect(resolved?.path == "/Users/someone/notes/img/pic one.png")
    }

    @Test func refusesPathTraversal() throws {
        let url = try #require(URL(string: "pullmark-local:///../secrets.txt"))
        #expect(LocalResourceSchemeHandler.resolve(url, root: root) == nil)
        let sneaky = try #require(URL(string: "pullmark-local:///img/../../other/file.png"))
        #expect(LocalResourceSchemeHandler.resolve(sneaky, root: root) == nil)
    }

    @Test func refusesEmptyPath() throws {
        let url = try #require(URL(string: "pullmark-local:///"))
        #expect(LocalResourceSchemeHandler.resolve(url, root: root) == nil)
    }

    @Test func allowsDotSegmentsThatStayInside() throws {
        let url = try #require(URL(string: "pullmark-local:///img/../readme.md"))
        let resolved = LocalResourceSchemeHandler.resolve(url, root: root)
        #expect(resolved?.path == "/Users/someone/notes/readme.md")
    }
}
