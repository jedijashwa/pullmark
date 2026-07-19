import Foundation

/// Copy as Markdown: maps a selection's covered source line range (computed
/// in the page from the data-pm-lines block annotations) back to a slice of
/// the original markdown text. Whole-block granularity — selecting part of
/// a block yields that whole block's source.
enum MarkdownCopy {
    /// Source text for a copy request. nil range (no selection, or a
    /// selection that touches no annotated block) copies the whole
    /// document; otherwise the covered lines, clamped to the document —
    /// a range that clamps to nothing falls back to the whole document.
    static func source(of markdown: String, lineRange: (start: Int, end: Int)?) -> String {
        guard let range = lineRange else { return markdown }
        let lineCount = markdown.components(separatedBy: "\n").count
        let start = max(1, range.start)
        let end = min(lineCount, range.end)
        guard start <= end, let slice = TextLines.lines(in: markdown, from: start, to: end) else {
            return markdown
        }
        return slice
    }
}
