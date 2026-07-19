import Testing
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
}
