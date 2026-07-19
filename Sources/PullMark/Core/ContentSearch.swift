import Foundation

/// One matching line of a searched document.
struct SearchMatch: Equatable {
    /// 1-based line number in the source text.
    let lineNumber: Int
    /// The full text of the matching line (without its newline).
    let lineText: String
    /// Every occurrence of the query within `lineText`, in order.
    let ranges: [Range<String.Index>]
}

/// Pure, case-insensitive substring search used by the all-files search
/// palette (⇧⌘F). No I/O — callers hand in already-loaded text.
enum ContentSearch {
    /// All lines of `text` containing `query` (case-insensitive). An empty or
    /// whitespace-only query matches nothing.
    static func matches(in text: String, query: String) -> [SearchMatch] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        var results: [SearchMatch] = []
        var lineNumber = 0
        // "\r\n" is a single Character in Swift, so match every newline
        // grapheme rather than splitting on "\n" alone.
        let separators: Set<Character> = ["\n", "\r\n", "\r"]
        for rawLine in text.split(omittingEmptySubsequences: false,
                                  whereSeparator: { separators.contains($0) }) {
            lineNumber += 1
            // Materialize the line first so the reported ranges index into
            // the exact string handed back in `lineText`.
            let line = String(rawLine)
            var ranges: [Range<String.Index>] = []
            var searchStart = line.startIndex
            while searchStart < line.endIndex,
                  let found = line.range(of: query, options: [.caseInsensitive],
                                         range: searchStart..<line.endIndex) {
                ranges.append(found)
                searchStart = found.upperBound
            }
            if !ranges.isEmpty {
                results.append(SearchMatch(lineNumber: lineNumber, lineText: line, ranges: ranges))
            }
        }
        return results
    }
}
