import Foundation

/// The single source of truth for which file extensions count as Markdown —
/// shared by the folder scanner, the PR file filter, and link handling in
/// the web view.
enum MarkdownFileType {
    static let extensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mdx"]

    static func matches(_ pathExtension: String) -> Bool {
        extensions.contains(pathExtension.lowercased())
    }
}

/// A contiguous chunk of Markdown source, tracked with its 1-based line range
/// in the original file so diff segments can be mapped back to GitHub review
/// comment positions.
struct MarkdownBlock: Equatable {
    let text: String
    let startLine: Int
    let endLine: Int
}

enum MarkdownBlocks {
    /// Splits Markdown source into blocks separated by blank lines, keeping
    /// fenced code blocks (``` or ~~~) intact even when they contain blank
    /// lines. A YAML front matter fence (`---` on the very first line through
    /// the next `---` line) is kept as a single block — even across blank
    /// lines — so diffs treat the metadata atomically and the web layer can
    /// render it as a key/value table.
    static func split(_ source: String) -> [MarkdownBlock] {
        let lines = source.components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var current: [String] = []
        var startIndex = 0
        var fenceMarker: String?
        var firstLineIndex = 0

        if let close = frontMatterCloseIndex(lines) {
            blocks.append(MarkdownBlock(
                text: lines[0...close].joined(separator: "\n"),
                startLine: 1,
                endLine: close + 1
            ))
            firstLineIndex = close + 1
        }

        func flush(lastLineIndex: Int) {
            guard !current.isEmpty else { return }
            blocks.append(MarkdownBlock(
                text: current.joined(separator: "\n"),
                startLine: startIndex + 1,
                endLine: lastLineIndex + 1
            ))
            current = []
        }

        for (i, line) in lines.enumerated() where i >= firstLineIndex {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let marker = fenceMarker {
                current.append(line)
                if trimmed.hasPrefix(marker) {
                    fenceMarker = nil
                }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                if current.isEmpty { startIndex = i }
                current.append(line)
                fenceMarker = String(trimmed.prefix(3))
                continue
            }
            if trimmed.isEmpty {
                flush(lastLineIndex: i - 1)
            } else {
                if current.isEmpty { startIndex = i }
                current.append(line)
            }
        }
        flush(lastLineIndex: lines.count - 1)
        return blocks
    }

    /// True when a block produced by `split` is a leading YAML front matter
    /// fence. Used to skip word-level diffing (plain old/new metadata tables
    /// are clearer than word marks inside YAML).
    static func isFrontMatter(_ block: MarkdownBlock) -> Bool {
        guard block.startLine == 1 else { return false }
        let lines = block.text.components(separatedBy: "\n")
        return lines.count >= 2
            && normalized(lines[0]) == "---"
            && lines[lines.count - 1].trimmingCharacters(in: .whitespacesAndNewlines) == "---"
    }

    /// The 0-based index of the line closing a leading front matter fence,
    /// or nil when the source does not start with one. The opening `---`
    /// must be the very first line (no indentation), which is what keeps
    /// mid-document thematic breaks from matching.
    private static func frontMatterCloseIndex(_ lines: [String]) -> Int? {
        guard lines.count >= 2, normalized(lines[0]) == "---" else { return nil }
        for i in 1..<lines.count
        where lines[i].trimmingCharacters(in: .whitespacesAndNewlines) == "---" {
            return i
        }
        return nil
    }

    /// Strips a trailing carriage return (CRLF sources) but no other
    /// whitespace: the opening fence must start at column 0.
    private static func normalized(_ line: String) -> String {
        line.hasSuffix("\r") ? String(line.dropLast()) : line
    }
}
