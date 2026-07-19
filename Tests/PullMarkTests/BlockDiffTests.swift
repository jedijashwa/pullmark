import Testing
@testable import PullMark

@Suite struct BlockDiffTests {
    private func segments(old: String, new: String) -> [DiffSegment] {
        BlockDiff.diff(old: MarkdownBlocks.split(old), new: MarkdownBlocks.split(new))
    }

    @Test func identicalDocuments() {
        let text = "# A\n\nBody"
        let result = segments(old: text, new: text)
        #expect(result.count == 2)
        for segment in result {
            guard case .unchanged = segment else {
                Issue.record("Expected unchanged, got \(segment)")
                return
            }
        }
    }

    @Test func pureInsertionMapsToNewFileLines() throws {
        let result = segments(old: "# A\n\nEnd", new: "# A\n\nInserted paragraph\n\nEnd")
        #expect(result.count == 3)
        guard case .added(let block) = result[1] else {
            Issue.record("Expected added, got \(result[1])")
            return
        }
        #expect(block.text == "Inserted paragraph")
        #expect(block.startLine == 3)
        #expect(result[1].payload.side == "RIGHT")
    }

    @Test func pureDeletionMapsToOldFileLines() throws {
        let result = segments(old: "# A\n\nDoomed paragraph\n\nEnd", new: "# A\n\nEnd")
        #expect(result.count == 3)
        guard case .removed(let block) = result[1] else {
            Issue.record("Expected removed, got \(result[1])")
            return
        }
        #expect(block.startLine == 3)
        #expect(result[1].payload.side == "LEFT")
    }

    @Test func changedBlockBecomesModified() throws {
        let result = segments(old: "# A\n\nOld text", new: "# A\n\nNew text")
        #expect(result.count == 2)
        guard case .modified(let old, let new) = result[1] else {
            Issue.record("Expected modified, got \(result[1])")
            return
        }
        #expect(old.text == "Old text")
        #expect(new.text == "New text")
        let payload = result[1].payload
        #expect(payload.kind == "modified")
        #expect(payload.oldText == "Old text")
        #expect(payload.side == "RIGHT")
        #expect(payload.lineStart == 3)
    }

    @Test func emptyOldMeansEverythingAdded() {
        let result = segments(old: "", new: "# New\n\nDoc")
        #expect(result.count == 2)
        for segment in result {
            guard case .added = segment else {
                Issue.record("Expected added, got \(segment)")
                return
            }
        }
    }

    @Test func emptyNewMeansEverythingRemoved() {
        let result = segments(old: "# Old\n\nDoc", new: "")
        #expect(result.count == 2)
        for segment in result {
            guard case .removed = segment else {
                Issue.record("Expected removed, got \(segment)")
                return
            }
        }
    }

    @Test func wordDiffSkippedForFrontMatterSegments() {
        let old = "---\ntitle: Old title\n---\n\nShared paragraph\n\nOld text"
        let new = "---\ntitle: New title\n---\n\nShared paragraph\n\nNew text"
        let payloads = DiffPageBuilder.segments(old: old, new: new)
        #expect(payloads.count == 3)
        #expect(payloads[0].kind == "modified")
        #expect(payloads[0].lineStart == 1)
        // Front matter renders as plain old/new metadata tables; word marks
        // are skipped.
        #expect(payloads[0].wordDiff == nil)
        // Ordinary modified prose still gets word-level markup.
        #expect(payloads[2].kind == "modified")
        #expect(payloads[2].wordDiff != nil)
    }

    @Test func wordDiffSkippedWhenOnlyOneSideIsFrontMatter() {
        let payloads = DiffPageBuilder.segments(
            old: "---\ntitle: Old\n---",
            new: "Intro paragraph"
        )
        #expect(payloads.count == 1)
        #expect(payloads[0].kind == "modified")
        #expect(payloads[0].wordDiff == nil)
        #expect(payloads[0].fmOldText)
        #expect(!payloads[0].fmText)
    }

    @Test func frontMatterFlagsMarkEachSide() {
        let old = "---\ntitle: One\n---\n\npara"
        let new = "---\ntitle: Two\n---\n\npara"
        let payloads = DiffPageBuilder.segments(old: old, new: new)
        #expect(payloads[0].fmText)
        #expect(payloads[0].fmOldText)
        // Prose segments are never flagged.
        #expect(!payloads[1].fmText)
        #expect(!payloads[1].fmOldText)
    }

    @Test func brokenFrontMatterOnNewSideOnlyFlagsOldSide() {
        // Mirrors github/docs#45206: the PR accidentally adds a blank line
        // before the opening fence, so the new side is no longer front
        // matter — only the old side may render as a metadata table, even
        // though the pairing gives the segment the new side's line numbers.
        let old = "---\ntitle: Hello\nversions:\n  fpt: '*'\n---\n\nBody para"
        let new = "\n---\n\ntitle: Hello\nversions:\n  fpt: '*'\n---\n\nBody para"
        let payloads = DiffPageBuilder.segments(old: old, new: new)
        let fmOld = payloads.first { $0.fmOldText || $0.fmText }
        #expect(fmOld != nil)
        #expect(fmOld?.fmText == false)
        #expect(fmOld?.wordDiff == nil)
        // No new-side segment is flagged (the fence is broken there).
        #expect(!payloads.contains { $0.fmText })
    }
}
