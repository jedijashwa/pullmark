import Testing
@testable import PullMark

@Suite struct ReadmePathTests {
    @Test func rootReadmeAnyCase() {
        #expect(PathTree.readmePath(in: ["docs/a.md", "ReadMe.md"]) == "ReadMe.md")
    }

    @Test func indexFallback() {
        #expect(PathTree.readmePath(in: ["index.md", "guide.md"]) == "index.md")
    }

    @Test func readmeBeatsIndex() {
        #expect(PathTree.readmePath(in: ["index.md", "README.markdown"]) == "README.markdown")
    }

    @Test func descendantsNeverCount() {
        #expect(PathTree.readmePath(in: ["docs/README.md", "guide.md"]) == nil)
    }

    @Test func subdirectoryScope() {
        let paths = ["README.md", "docs/README.md", "docs/deep/index.md"]
        #expect(PathTree.readmePath(in: paths, directory: "docs") == "docs/README.md")
        #expect(PathTree.readmePath(in: paths, directory: "docs/deep") == "docs/deep/index.md")
        #expect(PathTree.readmePath(in: paths, directory: "src") == nil)
    }

    @Test func nothingMatches() {
        #expect(PathTree.readmePath(in: ["guide.md", "notes.md"]) == nil)
    }
}
