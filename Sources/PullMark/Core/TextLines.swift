import Foundation

enum TextLines {
    /// 1-based inclusive line range from `text`, or nil when out of bounds.
    static func lines(in text: String, from start: Int, to end: Int) -> String? {
        let all = text.components(separatedBy: "\n")
        guard start >= 1, end >= start, end <= all.count else { return nil }
        return all[(start - 1)...(end - 1)].joined(separator: "\n")
    }
}
