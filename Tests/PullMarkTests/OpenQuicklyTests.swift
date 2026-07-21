import Testing
import Foundation
@testable import PullMark

@Suite("Open Quickly")
struct OpenQuicklyTests {
    @Test func subsequenceScoringPrefersWordStartsAndShortTargets() {
        #expect(OpenQuickly.score("xyz", in: "README.md") == nil)
        let readme = try! #require(OpenQuickly.score("read", in: "README.md"))
        let scattered = try! #require(OpenQuickly.score("read", in: "spread-readiness-notes.md"))
        #expect(readme > scattered)
    }

    @Test func headingExtractionSkipsFencesAndSlugsLikeThePage() {
        let markdown = "# Top\n\n```\n# not a heading\n```\n\n## Sub Section!"
        let headings = OpenQuickly.headings(in: markdown)
        #expect(headings.map(\.title) == ["Top", "Sub Section!"])
        #expect(headings.last?.slug == "sub-section")
    }

    @Test func directDestinationParsesPullRequestForms() {
        let expected = OpenQuickly.DirectDestination.pullRequest(
            PullRequestRef(owner: "octo", repo: "docs", number: 42))
        for query in ["https://github.com/octo/docs/pull/42",
                      "https://github.com/octo/docs/pull/42/files",
                      "github.com/octo/docs/pull/42",
                      "octo/docs#42",
                      "  octo/docs/pull/42  "] {
            #expect(OpenQuickly.directDestination(for: query) { _ in false } == expected,
                    "query: \(query)")
        }
    }

    @Test func directDestinationAcceptsOnlyExistingAbsolutePaths() {
        let exists: (String) -> Bool = { $0 == "/tmp/notes.md" || $0 == NSHomeDirectory() + "/notes.md" }
        #expect(OpenQuickly.directDestination(for: "/tmp/notes.md", fileExists: exists)
            == .path("/tmp/notes.md"))
        #expect(OpenQuickly.directDestination(for: "/tmp/gone.md", fileExists: exists) == nil)
        #expect(OpenQuickly.directDestination(for: "~/notes.md", fileExists: exists)
            == .path(NSHomeDirectory() + "/notes.md"))
        #expect(OpenQuickly.directDestination(for: "file:///tmp/notes.md", fileExists: exists)
            == .path("/tmp/notes.md"))
        // Relative paths and ordinary search terms never hijack the query.
        #expect(OpenQuickly.directDestination(for: "notes.md", fileExists: { _ in true }) == nil)
        #expect(OpenQuickly.directDestination(for: "readme heading", fileExists: { _ in true }) == nil)
        #expect(OpenQuickly.directDestination(for: "", fileExists: { _ in true }) == nil)
        // A path that is also plausible fuzzy input still resolves as a path
        // only when it exists — otherwise it falls through to fuzzy search.
        #expect(OpenQuickly.directDestination(for: "/does/not/exist", fileExists: exists) == nil)
    }

    @Test func newFileDiffPageCarriesTheAllNewFlag() {
        let segment = DiffSegmentPayload(kind: "added", text: "# Hi", oldText: nil,
                                         lineStart: 1, lineEnd: 1, side: "RIGHT")
        let flagged = HTMLBuilder.diffPage(segments: [segment], allNew: true)
        #expect(flagged.contains("\"allNew\":true"))
        let normal = HTMLBuilder.diffPage(segments: [segment])
        #expect(!normal.contains("allNew"))
    }
}
