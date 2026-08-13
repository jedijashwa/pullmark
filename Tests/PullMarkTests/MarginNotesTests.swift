import Testing
@testable import PullMark

@Suite struct MarginNotesTests {
    // MARK: Parsing

    @Test func singleLineNote() {
        let source = "# Title\n\nA paragraph.\n\n<!-- note @josh: Which is it? -->\n\nMore."
        let notes = MarginNotes.parse(source)
        #expect(notes.count == 1)
        #expect(notes[0].author == "josh")
        #expect(notes[0].attributes == nil)
        #expect(notes[0].body == "Which is it?")
        #expect(notes[0].startLine == 5)
        #expect(notes[0].endLine == 5)
        #expect(notes[0].isFileLevel == false)
    }

    @Test func blockFormNote() {
        let source = """
        # Title

        Paragraph.

        <!-- note @josh:
        First line.

        Second **paragraph** with markdown.
        -->
        """
        let notes = MarginNotes.parse(source)
        #expect(notes.count == 1)
        #expect(notes[0].body == "First line.\n\nSecond **paragraph** with markdown.")
        #expect(notes[0].startLine == 5)
        #expect(notes[0].endLine == 9)
    }

    @Test func authorWithSpacesAndAttributes() {
        let notes = MarginNotes.parse("x\n\n<!-- note @Josh R (blocking): fix this -->")
        #expect(notes.count == 1)
        #expect(notes[0].author == "Josh R")
        #expect(notes[0].attributes == "blocking")
        #expect(notes[0].body == "fix this")
    }

    @Test func firstColonDelimitsAuthor() {
        let notes = MarginNotes.parse("<!-- note @josh: see https://example.com/a:b -->")
        #expect(notes.count == 1)
        #expect(notes[0].author == "josh")
        #expect(notes[0].body == "see https://example.com/a:b")
    }

    @Test func escapedArrowUnescapes() {
        let notes = MarginNotes.parse(#"<!-- note @josh: mermaid uses a --\> b -->"#)
        #expect(notes.count == 1)
        #expect(notes[0].body == "mermaid uses a --> b")
    }

    @Test func ordinaryCommentsAreNotNotes() {
        let source = """
        <!-- markdownlint-disable -->
        <!-- @todo: old-style tag comment -->
        <!-- toc -->
        text
        """
        #expect(MarginNotes.parse(source).isEmpty)
    }

    @Test func notesInsideFencesIgnored() {
        let source = """
        Example:

        ```markdown
        <!-- note @josh: not a real note -->
        ```

        <!-- note @josh: a real one -->
        """
        let notes = MarginNotes.parse(source)
        #expect(notes.count == 1)
        #expect(notes[0].body == "a real one")
    }

    @Test func frontMatterSkipped() {
        let source = "---\ntitle: x\n---\n\n<!-- note @josh: file note -->\n\n# Doc"
        let notes = MarginNotes.parse(source)
        #expect(notes.count == 1)
        #expect(notes[0].startLine == 5)
        #expect(notes[0].isFileLevel == true)
    }

    @Test func fileLevelDetection() {
        let source = """
        <!-- note @josh: overall thoughts -->

        <!-- note @josh: second overall -->

        # Title

        <!-- note @josh: anchored -->
        """
        let notes = MarginNotes.parse(source)
        #expect(notes.count == 3)
        #expect(notes[0].isFileLevel == true)
        #expect(notes[1].isFileLevel == true)
        #expect(notes[2].isFileLevel == false)
    }

    @Test func unterminatedCommentIsNotANote() {
        #expect(MarginNotes.parse("<!-- note @josh: never closed\nbody").isEmpty)
    }

    @Test func blockBodyWithFencedCode() {
        let source = """
        para

        <!-- note @josh:
        Use this instead:

        ```swift
        let a = 1
        ```
        -->
        """
        let notes = MarginNotes.parse(source)
        #expect(notes.count == 1)
        #expect(notes[0].body == "Use this instead:\n\n```swift\nlet a = 1\n```")
    }

    // MARK: Writing

    @Test func noteTextSingleAndBlock() {
        #expect(MarginNotes.noteText(author: "josh", body: "short")
            == "<!-- note @josh: short -->")
        #expect(MarginNotes.noteText(author: "josh", body: "one\ntwo")
            == "<!-- note @josh:\none\ntwo\n-->")
    }

    @Test func noteTextEscapesArrow() {
        let text = MarginNotes.noteText(author: "josh", body: "a --> b")
        #expect(text == #"<!-- note @josh: a --\> b -->"#)
        let roundTrip = MarginNotes.parse(text)
        #expect(roundTrip.first?.body == "a --> b")
    }

    @Test func insertAfterBlock() {
        let source = "# Title\n\nParagraph.\n\nNext."
        let out = MarginNotes.inserting(author: "josh", body: "note here",
                                        afterLine: 3, in: source)
        #expect(out == "# Title\n\nParagraph.\n\n<!-- note @josh: note here -->\n\nNext.")
        let notes = MarginNotes.parse(out)
        #expect(notes.count == 1)
        #expect(notes[0].startLine == 5)
    }

    @Test func insertAtTop() {
        let out = MarginNotes.inserting(author: "josh", body: "file note",
                                        afterLine: 0, in: "# Title\n\nBody.")
        #expect(out == "<!-- note @josh: file note -->\n\n# Title\n\nBody.")
        #expect(MarginNotes.parse(out).first?.isFileLevel == true)
    }

    @Test func insertAtEndOfFile() {
        let out = MarginNotes.inserting(author: "josh", body: "tail note",
                                        afterLine: 3, in: "# Title\n\nLast.")
        #expect(out == "# Title\n\nLast.\n\n<!-- note @josh: tail note -->")
    }

    @Test func replaceBody() {
        let source = "para\n\n<!-- note @Josh R (blocking): old -->\n\nafter"
        let note = MarginNotes.parse(source)[0]
        let out = MarginNotes.replacingBody(of: note, with: "new text", in: source)
        #expect(out == "para\n\n<!-- note @Josh R (blocking): new text -->\n\nafter")
    }

    @Test func replaceBodyGrowsToBlockForm() {
        let source = "para\n\n<!-- note @josh: old -->"
        let note = MarginNotes.parse(source)[0]
        let out = MarginNotes.replacingBody(of: note, with: "one\ntwo", in: source)
        #expect(out == "para\n\n<!-- note @josh:\none\ntwo\n-->")
        #expect(MarginNotes.parse(out ?? "").first?.body == "one\ntwo")
    }

    @Test func removeNoteTidiesBlankLines() {
        let source = "para\n\n<!-- note @josh: gone -->\n\nafter"
        let note = MarginNotes.parse(source)[0]
        let out = MarginNotes.removing(note, from: source)
        #expect(out == "para\n\nafter")
    }

    @Test func removeFileLevelNote() {
        let source = "<!-- note @josh: gone -->\n\n# Title"
        let note = MarginNotes.parse(source)[0]
        #expect(MarginNotes.removing(note, from: source) == "# Title")
    }

    @Test func staleNoteRefusesSurgery() {
        let source = "para\n\n<!-- note @josh: original -->"
        let note = MarginNotes.parse(source)[0]
        let changed = "para\n\n<!-- note @josh: someone edited this -->"
        #expect(MarginNotes.replacingBody(of: note, with: "x", in: changed) == nil)
        #expect(MarginNotes.removing(note, from: changed) == nil)
    }

    // MARK: In-item (indented) notes

    @Test func indentedNoteParsesWithIndent() {
        let source = "- one\n  <!-- note @josh: too vague -->\n- two"
        let notes = MarginNotes.parse(source)
        #expect(notes.count == 1)
        #expect(notes[0].indent == "  ")
        #expect(notes[0].body == "too vague")
        #expect(notes[0].startLine == 2)
    }

    @Test func indentedBlockBodyDedents() {
        let source = """
        - item
          <!-- note @josh:
          First line.

          Second, with `code`.
          -->
        - next
        """
        let notes = MarginNotes.parse(source)
        #expect(notes.count == 1)
        #expect(notes[0].body == "First line.\n\nSecond, with `code`.")
        #expect(notes[0].indent == "  ")
        #expect(notes[0].endLine == 6)
    }

    @Test func noteTextIndentsEveryLine() {
        #expect(MarginNotes.noteText(author: "josh", body: "short", indent: "  ")
            == "  <!-- note @josh: short -->")
        #expect(MarginNotes.noteText(author: "josh", body: "one\n\ntwo", indent: "  ")
            == "  <!-- note @josh:\n  one\n\n  two\n  -->")
    }

    @Test func insertInItemIsTightAndIndented() {
        let source = "- one\n- two\n- three"
        let out = MarginNotes.inserting(author: "josh", body: "which?",
                                        afterLine: 1, itemIndent: "  ", in: source)
        #expect(out == "- one\n  <!-- note @josh: which? -->\n- two\n- three")
        let notes = MarginNotes.parse(out)
        #expect(notes.count == 1)
        #expect(notes[0].startLine == 2)
        #expect(notes[0].indent == "  ")
    }

    @Test func indentedNoteRoundTripsThroughEdit() {
        let source = "- one\n  <!-- note @josh: old -->\n- two"
        let note = MarginNotes.parse(source)[0]
        let out = MarginNotes.replacingBody(of: note, with: "new\nlonger", in: source)
        #expect(out == "- one\n  <!-- note @josh:\n  new\n  longer\n  -->\n- two")
        #expect(MarginNotes.parse(out ?? "").first?.body == "new\nlonger")
    }

    @Test func removingTightNoteLeavesListIntact() {
        let source = "- one\n  <!-- note @josh: gone -->\n- two"
        let note = MarginNotes.parse(source)[0]
        #expect(MarginNotes.removing(note, from: source) == "- one\n- two")
    }

    @Test func invalidItemIndentDegradesToSpacedNote() {
        // A 4-space indent would make the note read as an indented code
        // block — invisible to the parser. Garbage from the bridge must
        // fall back to the between-blocks form, never write a lost note.
        for bad in ["    ", "\t", "x ", ""] {
            let out = MarginNotes.inserting(author: "josh", body: "x",
                                            afterLine: 1, itemIndent: bad,
                                            in: "- one\n- two")
            #expect(out == "- one\n\n<!-- note @josh: x -->\n\n- two")
        }
    }

    // MARK: Block splitter integration

    @Test func multiLineCommentIsOneBlock() {
        let source = "para\n\n<!-- note @josh:\nfirst\n\nsecond\n-->\n\nafter"
        let blocks = MarkdownBlocks.split(source)
        #expect(blocks.count == 3)
        #expect(blocks[1].text == "<!-- note @josh:\nfirst\n\nsecond\n-->")
        #expect(blocks[1].startLine == 3)
        #expect(blocks[1].endLine == 7)
    }
}
