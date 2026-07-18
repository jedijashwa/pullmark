import Testing
@testable import PullMark

@Suite struct MarkdownBlocksTests {
    @Test func splitsParagraphsWithLineNumbers() {
        let source = "# Title\n\nFirst paragraph\nsecond line\n\nLast one"
        let blocks = MarkdownBlocks.split(source)
        #expect(blocks.count == 3)
        #expect(blocks[0].text == "# Title")
        #expect(blocks[0].startLine == 1)
        #expect(blocks[0].endLine == 1)
        #expect(blocks[1].text == "First paragraph\nsecond line")
        #expect(blocks[1].startLine == 3)
        #expect(blocks[1].endLine == 4)
        #expect(blocks[2].startLine == 6)
        #expect(blocks[2].endLine == 6)
    }

    @Test func fencedCodeWithBlankLinesStaysOneBlock() {
        let source = "para\n\n```swift\nlet a = 1\n\nlet b = 2\n```\n\nafter"
        let blocks = MarkdownBlocks.split(source)
        #expect(blocks.count == 3)
        #expect(blocks[1].text == "```swift\nlet a = 1\n\nlet b = 2\n```")
        #expect(blocks[1].startLine == 3)
        #expect(blocks[1].endLine == 7)
        #expect(blocks[2].text == "after")
    }

    @Test func tildeFence() {
        let blocks = MarkdownBlocks.split("~~~\ncode\n\nmore\n~~~")
        #expect(blocks.count == 1)
        #expect(blocks[0].endLine == 5)
    }

    @Test func unclosedFenceRunsToEndOfFile() {
        let source = "```\ncode\n\nstill code"
        let blocks = MarkdownBlocks.split(source)
        #expect(blocks.count == 1)
        #expect(blocks[0].text == source)
    }

    @Test func emptyAndBlankSources() {
        #expect(MarkdownBlocks.split("").isEmpty)
        #expect(MarkdownBlocks.split("\n\n\n").isEmpty)
    }

    @Test func trailingNewline() {
        let blocks = MarkdownBlocks.split("hello\n")
        #expect(blocks.count == 1)
        #expect(blocks[0].startLine == 1)
        #expect(blocks[0].endLine == 1)
    }
}
