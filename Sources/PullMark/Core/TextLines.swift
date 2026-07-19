import Foundation

enum TextLines {
    /// 1-based inclusive line range from `text`, or nil when out of bounds.
    static func lines(in text: String, from start: Int, to end: Int) -> String? {
        let all = text.components(separatedBy: "\n")
        guard start >= 1, end >= start, end <= all.count else { return nil }
        return all[(start - 1)...(end - 1)].joined(separator: "\n")
    }

    /// Replaces the 1-based inclusive line range with `replacement` (block
    /// editing writes back through this). Everything outside the range —
    /// including a trailing newline — is preserved byte-for-byte; nil when
    /// the range is out of bounds. An empty replacement deletes the lines.
    static func replacing(in text: String, from start: Int, to end: Int,
                          with replacement: String) -> String? {
        var all = text.components(separatedBy: "\n")
        guard start >= 1, end >= start, end <= all.count else { return nil }
        let newLines = replacement.isEmpty ? [] : replacement.components(separatedBy: "\n")
        all.replaceSubrange((start - 1)...(end - 1), with: newLines)
        return all.joined(separator: "\n")
    }
}
