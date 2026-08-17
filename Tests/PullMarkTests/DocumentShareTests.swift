import AppKit
import Testing
@testable import PullMark

@Suite struct DocumentShareTests {

    private func item(file: Bool = true, html: Bool = true) -> DocumentShareItem {
        DocumentShareItem(
            fileURL: file ? URL(fileURLWithPath: "/tmp/notes.md") : nil,
            html: html ? "<h1>Hi</h1>" : nil,
            markdown: "# Hi",
            title: "notes.md")
    }

    @Test func flavorsDeclareRichestFirst() {
        // Receivers that honor declaration order (most) must see the
        // file before rich text, and rich text before plain.
        #expect(item().writableTypes(for: .general)
            == [.fileURL, .html, .string])
    }

    @Test func missingFlavorsDropOutButPlainTextNeverDoes() {
        #expect(item(file: false).writableTypes(for: .general)
            == [.html, .string])
        #expect(item(file: false, html: false)
            .writableTypes(for: .general) == [.string])
    }

    @Test func eachFlavorAnswersWithItsOwnPayload() {
        let full = item()
        #expect(full.pasteboardPropertyList(forType: .fileURL) as? String
            == "file:///tmp/notes.md")
        #expect(full.pasteboardPropertyList(forType: .html) as? String == "<h1>Hi</h1>")
        // Plain text is the MARKDOWN SOURCE — the right "plain" for a
        // Markdown app (#72: it used to be the file's name).
        #expect(full.pasteboardPropertyList(forType: .string) as? String == "# Hi")
        #expect(full.pasteboardPropertyList(forType: .rtf) == nil)
        #expect(full.pasteboardPropertyList(forType: .pdf) == nil)
    }

    @Test func declaredTypesAllHavePayloads() {
        // A declared flavor that answers nil poisons the whole paste.
        for variant in [item(), item(file: false), item(html: false)] {
            for type in variant.writableTypes(for: .general) {
                #expect(variant.pasteboardPropertyList(forType: type) != nil,
                        "declared \(type.rawValue) but returned nil")
            }
        }
    }
}
