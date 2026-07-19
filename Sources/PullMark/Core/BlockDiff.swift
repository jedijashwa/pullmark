import Foundation

enum DiffSegment: Equatable {
    case unchanged(old: MarkdownBlock, new: MarkdownBlock)
    case added(MarkdownBlock)
    case removed(MarkdownBlock)
    case modified(old: MarkdownBlock, new: MarkdownBlock)
    /// The same text deleted in one place and inserted verbatim in another:
    /// a move, not an edit. Rendered once, at the new position, with a
    /// quiet "moved" marker instead of screaming red + green.
    case moved(old: MarkdownBlock, new: MarkdownBlock)
}

enum BlockDiff {
    /// Block-level diff via longest-common-subsequence, with adjacent
    /// removed/added pairs collapsed into `.modified`.
    static func diff(old: [MarkdownBlock], new: [MarkdownBlock]) -> [DiffSegment] {
        let n = old.count, m = new.count

        // Degenerate sizes: skip the DP table.
        guard n > 0 else { return new.map { .added($0) } }
        guard m > 0 else { return old.map { .removed($0) } }
        guard n * m <= 4_000_000 else {
            return old.map { .removed($0) } + new.map { .added($0) }
        }

        var lcs = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i][j] = old[i].text == new[j].text
                    ? lcs[i + 1][j + 1] + 1
                    : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }

        var raw: [DiffSegment] = []
        var i = 0, j = 0
        while i < n && j < m {
            if old[i].text == new[j].text {
                raw.append(.unchanged(old: old[i], new: new[j]))
                i += 1; j += 1
            } else if lcs[i + 1][j] >= lcs[i][j + 1] {
                raw.append(.removed(old[i]))
                i += 1
            } else {
                raw.append(.added(new[j]))
                j += 1
            }
        }
        while i < n { raw.append(.removed(old[i])); i += 1 }
        while j < m { raw.append(.added(new[j])); j += 1 }

        var result: [DiffSegment] = []
        var k = 0
        while k < raw.count {
            if case .removed(let o) = raw[k], k + 1 < raw.count, case .added(let nw) = raw[k + 1] {
                result.append(.modified(old: o, new: nw))
                k += 2
            } else {
                result.append(raw[k])
                k += 1
            }
        }
        return detectMoves(in: result)
    }

    /// Post-pass: a block removed in one place and added VERBATIM in
    /// another is presented as `.moved` at its new position; the removal
    /// disappears (nothing about the content changed). Only unambiguous
    /// pairs qualify — the text must appear exactly once among removals
    /// and once among additions, so duplicated boilerplate ("---", repeated
    /// notes) can never be mispaired.
    static func detectMoves(in segments: [DiffSegment]) -> [DiffSegment] {
        var removedIndex: [String: [Int]] = [:]
        var addedIndex: [String: [Int]] = [:]
        for (i, segment) in segments.enumerated() {
            switch segment {
            // Substantial blocks only: a lone "---" or short one-liner that
            // happens to be deleted here and added there is coincidence,
            // and the chip's provenance claim must never be a guess.
            case .removed(let block) where block.text.count >= 24:
                removedIndex[block.text, default: []].append(i)
            case .added(let block) where block.text.count >= 24:
                addedIndex[block.text, default: []].append(i)
            default: break
            }
        }
        var moves: [Int: Int] = [:]  // added index → removed index
        for (text, removedAt) in removedIndex {
            guard removedAt.count == 1, let addedAt = addedIndex[text],
                  addedAt.count == 1 else { continue }
            moves[addedAt[0]] = removedAt[0]
        }
        guard !moves.isEmpty else { return segments }
        let removedSlots = Set(moves.values)
        var result: [DiffSegment] = []
        for (i, segment) in segments.enumerated() {
            if removedSlots.contains(i) { continue }
            if let from = moves[i], case .removed(let old) = segments[from],
               case .added(let new) = segment {
                result.append(.moved(old: old, new: new))
            } else {
                result.append(segment)
            }
        }
        return result
    }
}

/// JSON payload handed to the web layer for rendering one diff segment.
struct DiffSegmentPayload: Encodable, Equatable {
    let kind: String
    let text: String
    let oldText: String?
    let lineStart: Int
    let lineEnd: Int
    let side: String
    /// Whether `text` (resp. `oldText`) is a leading YAML front matter
    /// block — decided here because only Swift knows each side's true line
    /// numbers (a modified segment's payload carries only the new side's).
    /// The web layer renders flagged sides as metadata tables.
    var fmText = false
    var fmOldText = false
    /// For kind "moved": the 1-based old-file line the block came from.
    var movedFromLine: Int? = nil
    /// Existing review threads anchored to this segment (attached later by
    /// ReviewThreads.place, hence mutable).
    var threads: [ThreadPayload]? = nil
    /// Word-level markup for modified segments (attached after diffing).
    var wordDiff: WordDiff.Markup? = nil
}

extension DiffSegment {
    /// GitHub review comments target either the old file ("LEFT") or the new
    /// file ("RIGHT"). Everything that still exists in the new file targets
    /// RIGHT; only fully removed blocks target LEFT.
    var payload: DiffSegmentPayload {
        switch self {
        case .unchanged(_, let new):
            return DiffSegmentPayload(kind: "unchanged", text: new.text, oldText: nil,
                                      lineStart: new.startLine, lineEnd: new.endLine, side: "RIGHT",
                                      fmText: MarkdownBlocks.isFrontMatter(new))
        case .added(let block):
            return DiffSegmentPayload(kind: "added", text: block.text, oldText: nil,
                                      lineStart: block.startLine, lineEnd: block.endLine, side: "RIGHT",
                                      fmText: MarkdownBlocks.isFrontMatter(block))
        case .removed(let block):
            return DiffSegmentPayload(kind: "removed", text: block.text, oldText: nil,
                                      lineStart: block.startLine, lineEnd: block.endLine, side: "LEFT",
                                      fmText: MarkdownBlocks.isFrontMatter(block))
        case .modified(let old, let new):
            return DiffSegmentPayload(kind: "modified", text: new.text, oldText: old.text,
                                      lineStart: new.startLine, lineEnd: new.endLine, side: "RIGHT",
                                      fmText: MarkdownBlocks.isFrontMatter(new),
                                      fmOldText: MarkdownBlocks.isFrontMatter(old))
        case .moved(let old, let new):
            return DiffSegmentPayload(kind: "moved", text: new.text, oldText: nil,
                                      lineStart: new.startLine, lineEnd: new.endLine, side: "RIGHT",
                                      fmText: MarkdownBlocks.isFrontMatter(new),
                                      movedFromLine: old.startLine)
        }
    }
}
