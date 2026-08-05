import Testing
import Foundation
@testable import PullMark

@Suite struct RemoteDocLinkTests {
    private func parse(_ s: String) -> RemoteDocLink? {
        RemoteDocLink.parse(URL(string: s)!)
    }

    @Test func blobURL() {
        let link = parse("https://github.com/obra/superpowers/blob/main/skills/brainstorming/SKILL.md")
        #expect(link == RemoteDocLink(owner: "obra", repo: "superpowers", ref: "main",
                                      path: "skills/brainstorming/SKILL.md", fragment: nil))
    }

    @Test func blobURLWithFragmentAndQuery() {
        let link = parse("https://github.com/o/r/blob/main/README.md?plain=1#the-process")
        #expect(link?.path == "README.md")
        #expect(link?.fragment == "the-process")
    }

    @Test func blobAtSHA() {
        let link = parse("https://github.com/o/r/blob/0a1b2c3d4e/docs/guide.markdown")
        #expect(link?.ref == "0a1b2c3d4e")
        #expect(link?.path == "docs/guide.markdown")
    }

    @Test func rawURL() {
        let link = parse("https://raw.githubusercontent.com/o/r/main/docs/a.md")
        #expect(link == RemoteDocLink(owner: "o", repo: "r", ref: "main",
                                      path: "docs/a.md", fragment: nil))
    }

    @Test func rawRefsHeadsURL() {
        let link = parse("https://raw.githubusercontent.com/o/r/refs/heads/main/docs/a.md")
        #expect(link?.ref == "main")
        #expect(link?.path == "docs/a.md")
    }

    @Test func rawRefsTagsURL() {
        let link = parse("https://raw.githubusercontent.com/o/r/refs/tags/v1.0/CHANGELOG.md")
        #expect(link?.ref == "v1.0")
        #expect(link?.path == "CHANGELOG.md")
    }

    @Test func percentEncodedPath() {
        let link = parse("https://github.com/o/r/blob/main/docs/release%20notes.md")
        #expect(link?.path == "docs/release notes.md")
    }

    @Test func uppercaseExtension() {
        #expect(parse("https://github.com/o/r/blob/main/README.MD") != nil)
    }

    @Test func rejectsNonMarkdown() {
        #expect(parse("https://github.com/o/r/blob/main/src/main.swift") == nil)
        #expect(parse("https://github.com/o/r/blob/main/Package.resolved") == nil)
    }

    @Test func rejectsTreeGistAndOtherHosts() {
        #expect(parse("https://github.com/o/r/tree/main/docs") == nil)
        #expect(parse("https://gist.github.com/o/abc123") == nil)
        #expect(parse("https://gitlab.com/o/r/blob/main/a.md") == nil)
        #expect(parse("https://github.com/o/r/pull/12") == nil)
        #expect(parse("https://github.com/o/r") == nil)
    }

    @Test func rejectsTraversalSegments() {
        #expect(parse("https://github.com/o/r/blob/main/../secrets.md") == nil)
    }

    @Test func wwwHostAccepted() {
        #expect(parse("https://www.github.com/o/r/blob/main/a.md") != nil)
    }
}
