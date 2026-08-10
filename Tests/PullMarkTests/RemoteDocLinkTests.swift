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

    @Test func schemelessFormsWorkViaOpenQuickly() {
        // ⌘K accepts what people actually type — no scheme.
        #expect(OpenQuickly.directDestination(for: "github.com/o/r", fileExists: { _ in false })
            == .remoteRepo(owner: "o", repo: "r", ref: nil))
        #expect(OpenQuickly.directDestination(for: "github.com/o/r/blob/main/a.md",
                                              fileExists: { _ in false })
            == .remoteDoc(RemoteDocLink(owner: "o", repo: "r", ref: "main",
                                        path: "a.md", fragment: nil)))
    }

    // MARK: - blobURL builder (the remote-doc toolbar Share target)

    @Test func buildsCanonicalBlobURL() {
        let url = RemoteDocLink.blobURL(owner: "obra", repo: "superpowers",
                                        ref: "main", path: "skills/brainstorming/SKILL.md")
        #expect(url?.absoluteString
            == "https://github.com/obra/superpowers/blob/main/skills/brainstorming/SKILL.md")
    }

    @Test func builtBlobURLPercentEncodes() {
        let url = RemoteDocLink.blobURL(owner: "o", repo: "r",
                                        ref: "main", path: "docs/release notes.md")
        #expect(url?.absoluteString
            == "https://github.com/o/r/blob/main/docs/release%20notes.md")
    }

    @Test func builtBlobURLRoundTripsThroughParse() {
        let url = RemoteDocLink.blobURL(owner: "o", repo: "r",
                                        ref: "feature/wide-tables", path: "docs/a.md")!
        // A ref containing "/" is ambiguous by nature — parse takes the
        // first segment as the ref. Plain refs must round-trip exactly.
        let plain = RemoteDocLink.blobURL(owner: "o", repo: "r",
                                          ref: "main", path: "docs/release notes.md")!
        #expect(RemoteDocLink.parse(plain)
            == RemoteDocLink(owner: "o", repo: "r", ref: "main",
                             path: "docs/release notes.md", fragment: nil))
        #expect(url.absoluteString.contains("/blob/feature/wide-tables/"))
    }

    // MARK: - isCommitSHA (the remote-doc toolbar Reload gate)

    @Test func commitSHAsAreDetected() {
        #expect(RemoteDocLink.isCommitSHA("0a1b2c3"))
        #expect(RemoteDocLink.isCommitSHA("0a1b2c3d4e"))
        #expect(RemoteDocLink.isCommitSHA("aa76b61cea0fe2f22caa93b1c9f9a0b2c3d4e5f6"))
        #expect(RemoteDocLink.isCommitSHA("DEADBEEF0123"))
    }

    @Test func branchAndTagNamesAreNot() {
        #expect(!RemoteDocLink.isCommitSHA("main"))
        #expect(!RemoteDocLink.isCommitSHA("master"))
        #expect(!RemoteDocLink.isCommitSHA("v1.0.2"))
        #expect(!RemoteDocLink.isCommitSHA("feature/wide-tables"))
        #expect(!RemoteDocLink.isCommitSHA("release-2026"))
        // Too short to be an abbreviated object name even when all-hex.
        #expect(!RemoteDocLink.isCommitSHA("cafe"))
        #expect(!RemoteDocLink.isCommitSHA(""))
        // Over full-SHA length.
        #expect(!RemoteDocLink.isCommitSHA(String(repeating: "a", count: 41)))
    }
}
