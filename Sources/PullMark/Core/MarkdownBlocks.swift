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
    /// fenced code blocks (``` or ~~~) intact even when they contain blank lines.
    static func split(_ source: String) -> [MarkdownBlock] {
        let lines = source.components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var current: [String] = []
        var startIndex = 0
        var fenceMarker: String?

        func flush(lastLineIndex: Int) {
            guard !current.isEmpty else { return }
            blocks.append(MarkdownBlock(
                text: current.joined(separator: "\n"),
                startLine: startIndex + 1,
                endLine: lastLineIndex + 1
            ))
            current = []
        }

        for (i, line) in lines.enumerated() {
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
}
