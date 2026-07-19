import Foundation

/// Builds GitHub ```suggestion comment bodies for edit-as-suggestion.
enum Suggestion {
    /// A suggestion block containing the replacement lines, with the
    /// optional explanatory note BELOW it — below, because a note with an
    /// unclosed code fence would otherwise swallow the ```suggestion opener
    /// (no fence length can save it: closing fences can't carry an info
    /// string). The fence grows past any backtick run inside the
    /// replacement, so suggesting an edit to a code fence can't break out.
    /// An empty replacement emits GitHub's delete-lines form: nothing at
    /// all between the fences (a blank line would instead replace the
    /// targeted lines with one empty line).
    static func body(note: String, replacement: String) -> String {
        var run = 0
        var longest = 0
        for character in replacement {
            if character == "`" {
                run += 1
                longest = max(longest, run)
            } else {
                run = 0
            }
        }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        let block = replacement.isEmpty
            ? "\(fence)suggestion\n\(fence)"
            : "\(fence)suggestion\n\(replacement)\n\(fence)"
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedNote.isEmpty ? block : "\(block)\n\n\(trimmedNote)"
    }
}
