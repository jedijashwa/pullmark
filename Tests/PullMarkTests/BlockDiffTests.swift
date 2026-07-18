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
}
