import Foundation

/// Word-level diff for a pair of changed Markdown blocks. Changed runs are
/// wrapped in private-use sentinel characters that pass through the Markdown
/// renderer as plain text; the web layer converts them into highlight spans
/// after rendering (see applyWordDiffMarks in app.js).
enum WordDiff {
    struct Markup: Encodable, Equatable {
        /// Old and new text interleaved: deletions and insertions both marked.
        let merged: String
        /// Old text with deleted runs marked.
        let old: String
        /// New text with inserted runs marked.
        let new: String
    }

    static let deleteOpen = "\u{E000}"
    static let deleteClose = "\u{E001}"
    static let insertOpen = "\u{E002}"
    static let insertClose = "\u{E003}"

    /// Returns nil when a word-level diff would not make sense: code fences
    /// (highlighting would fight the syntax highlighter) or blocks so
    /// different that nearly everything would be marked.
    static func markup(old: String, new: String) -> Markup? {
        for fence in ["```", "~~~"] {
            if old.contains(fence) || new.contains(fence) { return nil }
        }
        let oldTokens = tokenize(old)
        let newTokens = tokenize(new)
        guard oldTokens.count * newTokens.count <= 1_000_000 else { return nil }

        let operations = ops(old: oldTokens, new: newTokens)

        var equalWords = 0, oldWords = 0, newWords = 0
        for operation in operations {
            switch operation {
            case .equal(let t):
                if !isBlank(t) { equalWords += 1; oldWords += 1; newWords += 1 }
            case .delete(let t):
                if !isBlank(t) { oldWords += 1 }
            case .insert(let t):
                if !isBlank(t) { newWords += 1 }
            }
        }
        guard oldWords + newWords > 0 else { return nil }
        let similarity = Double(2 * equalWords) / Double(oldWords + newWords)
        guard similarity >= 0.4 else { return nil }

        var merged = "", oldMarked = "", newMarked = ""
        var index = 0
        while index < operations.count {
            switch operations[index] {
            case .equal(let t):
                merged += t
                oldMarked += t
                newMarked += t
                index += 1
            case .delete:
                var run = ""
                while index < operations.count, case .delete(let t) = operations[index] {
                    run += t
                    index += 1
                }
                if isBlank(run) {
                    oldMarked += run
                } else {
                    merged += deleteOpen + run + deleteClose
                    oldMarked += deleteOpen + run + deleteClose
                }
            case .insert:
                var run = ""
                while index < operations.count, case .insert(let t) = operations[index] {
                    run += t
                    index += 1
                }
                if isBlank(run) {
                    merged += run
                    newMarked += run
                } else {
                    merged += insertOpen + run + insertClose
                    newMarked += insertOpen + run + insertClose
                }
            }
        }
        return Markup(merged: merged, old: oldMarked, new: newMarked)
    }

    // MARK: - Internals (exposed for tests)

    enum Op: Equatable {
        case equal(String)
        case delete(String)
        case insert(String)
    }

    /// Splits text into word runs, whitespace runs, and single punctuation
    /// characters, so joining the tokens reproduces the input exactly.
    static func tokenize(_ text: String) -> [String] {
        enum Kind { case word, space, other }
        func kind(of character: Character) -> Kind {
            if character.isLetter || character.isNumber { return .word }
            if character.isWhitespace { return .space }
            return .other
        }
        var tokens: [String] = []
        var current = ""
        var currentKind: Kind?
        for character in text {
            let k = kind(of: character)
            if k == currentKind && k != .other {
                current.append(character)
            } else {
                if !current.isEmpty { tokens.append(current) }
                current = String(character)
                currentKind = k
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    static func ops(old: [String], new: [String]) -> [Op] {
        let n = old.count, m = new.count
        guard n > 0 else { return new.map { .insert($0) } }
        guard m > 0 else { return old.map { .delete($0) } }

        var lcs = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i][j] = old[i] == new[j]
                    ? lcs[i + 1][j + 1] + 1
                    : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var result: [Op] = []
        var i = 0, j = 0
        while i < n && j < m {
            if old[i] == new[j] {
                result.append(.equal(old[i]))
                i += 1; j += 1
            } else if lcs[i + 1][j] >= lcs[i][j + 1] {
                result.append(.delete(old[i]))
                i += 1
            } else {
                result.append(.insert(new[j]))
                j += 1
            }
        }
        while i < n { result.append(.delete(old[i])); i += 1 }
        while j < m { result.append(.insert(new[j])); j += 1 }
        return result
    }

    private static func isBlank(_ text: String) -> Bool {
        text.allSatisfy(\.isWhitespace)
    }
}
