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

    @Test func leadingFrontMatterIsOneBlock() {
        let source = "---\ntitle: Hello\nlayout: page\n---\n\n# Doc\n\nBody"
        let blocks = MarkdownBlocks.split(source)
        #expect(blocks.count == 3)
        #expect(blocks[0].text == "---\ntitle: Hello\nlayout: page\n---")
        #expect(blocks[0].startLine == 1)
        #expect(blocks[0].endLine == 4)
        #expect(MarkdownBlocks.isFrontMatter(blocks[0]))
        #expect(blocks[1].text == "# Doc")
        #expect(blocks[1].startLine == 6)
        #expect(blocks[2].text == "Body")
        #expect(blocks[2].startLine == 8)
    }

    @Test func frontMatterWithBlankLineStaysOneBlock() {
        let source = "---\ntitle: Hello\n\ntags: [a, b]\n---\n\npara"
        let blocks = MarkdownBlocks.split(source)
        #expect(blocks.count == 2)
        #expect(blocks[0].text == "---\ntitle: Hello\n\ntags: [a, b]\n---")
        #expect(blocks[0].endLine == 5)
        #expect(MarkdownBlocks.isFrontMatter(blocks[0]))
    }

    @Test func midDocumentHorizontalRuleIsNotFrontMatter() {
        let source = "intro\n\n---\n\nafter\n\n---"
        let blocks = MarkdownBlocks.split(source)
        #expect(blocks.count == 4)
        #expect(blocks[1].text == "---")
        #expect(blocks[1].startLine == 3)
        #expect(!MarkdownBlocks.isFrontMatter(blocks[1]))
        #expect(blocks[3].text == "---")
    }

    @Test func thematicBreakAfterContentAtTopIsNotFrontMatter() {
        // Setext-style heading: `---` right under text on line 1 must not
        // swallow the document into a "front matter" block.
        let source = "Title\n---\n\npara\n\n---"
        let blocks = MarkdownBlocks.split(source)
        #expect(blocks.count == 3)
        #expect(blocks[0].text == "Title\n---")
        #expect(!MarkdownBlocks.isFrontMatter(blocks[0]))
    }

    @Test func unclosedLeadingFenceIsNotFrontMatter() {
        let source = "---\ntitle: Hello\n\npara"
        let blocks = MarkdownBlocks.split(source)
        #expect(blocks.count == 2)
        #expect(blocks[0].text == "---\ntitle: Hello")
        #expect(!MarkdownBlocks.isFrontMatter(blocks[0]))
    }

    @Test func indentedDashesDoNotOpenFrontMatter() {
        let source = " ---\ntitle: x\n---\n\npara"
        let blocks = MarkdownBlocks.split(source)
        #expect(blocks[0].text == " ---\ntitle: x\n---")
        #expect(!MarkdownBlocks.isFrontMatter(blocks[0]))
    }

    @Test func crlfFrontMatter() {
        let source = "---\r\ntitle: Hello\r\n---\r\n\r\npara"
        let blocks = MarkdownBlocks.split(source)
        #expect(blocks.count == 2)
        #expect(blocks[0].startLine == 1)
        #expect(blocks[0].endLine == 3)
        #expect(MarkdownBlocks.isFrontMatter(blocks[0]))
    }
}
