import Testing
@testable import PullMark

@Suite("PathTree building")
struct PathTreeTests {
    @Test func filesSortCaseInsensitivelyAfterDirectories() {
        let nodes = PathTree.build(["zeta.md", "Alpha.md", "docs/inner.md", "beta.md"])
        #expect(nodes.map(\.name) == ["docs", "Alpha.md", "beta.md", "zeta.md"])
        #expect(nodes[0].isDirectory)
        #expect(nodes[0].children.map(\.name) == ["inner.md"])
    }

    @Test func singleChildChainsCompress() {
        let nodes = PathTree.build(["docs/en/guide/setup.md", "docs/en/guide/usage.md"])
        #expect(nodes.count == 1)
        #expect(nodes[0].name == "docs/en/guide")
        #expect(nodes[0].path == "docs/en/guide")
        #expect(nodes[0].children.map(\.name) == ["setup.md", "usage.md"])
    }

    @Test func chainStopsCompressingAtBranch() {
        let nodes = PathTree.build([
            "docs/en/setup.md",
            "docs/fr/setup.md",
        ])
        #expect(nodes.count == 1)
        #expect(nodes[0].name == "docs")
        #expect(nodes[0].children.map(\.name) == ["en", "fr"])
    }

    @Test func chainStopsAtDirectoryWithAFile() {
        let nodes = PathTree.build([
            "docs/readme.md",
            "docs/en/setup.md",
        ])
        #expect(nodes[0].name == "docs")
        #expect(nodes[0].children.map(\.name) == ["en", "readme.md"])
    }

    @Test func leafPathsWalkInTreeOrder() {
        let nodes = PathTree.build(["b/two.md", "a/one.md", "top.md"])
        let all = nodes.flatMap(PathTree.leafPaths)
        #expect(all == ["a/one.md", "b/two.md", "top.md"])
    }

    @Test func duplicatesCollapseAndRootFilesSurvive() {
        let nodes = PathTree.build(["readme.md", "readme.md"])
        #expect(nodes.count == 1)
        #expect(nodes[0].filePath == "readme.md")
    }

    @Test func filePathsSurviveCompression() {
        let nodes = PathTree.build(["a/b/c/deep.md"])
        #expect(nodes[0].name == "a/b/c")
        #expect(nodes[0].children[0].filePath == "a/b/c/deep.md")
    }
}
