import Foundation

/// Matching and candidate types behind the ⌘K Open Quickly palette. Pure
/// so the ranking is unit-testable.
enum OpenQuickly {
    /// Subsequence fuzzy score: nil when `needle` isn't a subsequence of
    /// `hay` (case-insensitive); higher is better. Word-start and
    /// contiguous-run hits outrank scattered ones, and shorter targets win
    /// ties, which is what makes "read" find README.md before
    /// "spread-readiness-notes.md".
    static func score(_ needle: String, in hay: String) -> Int? {
        let n = Array(needle.lowercased())
        let h = Array(hay.lowercased())
        guard !n.isEmpty else { return 0 }
        var score = 0
        var hi = 0
        var previousHit = -2
        for character in n {
            var found = false
            while hi < h.count {
                if h[hi] == character {
                    if hi == 0 || h[hi - 1] == " " || h[hi - 1] == "-"
                        || h[hi - 1] == "_" || h[hi - 1] == "/" || h[hi - 1] == "." {
                        score += 8
                    }
                    if hi == previousHit + 1 { score += 5 }
                    previousHit = hi
                    hi += 1
                    found = true
                    break
                }
                hi += 1
            }
            if !found { return nil }
        }
        return score - min(h.count, 40) / 4
    }

    /// The same slug the rendering pipeline gives headings (pm-extensions
    /// slugify): trim, lowercase, strip everything but letters/numbers/
    /// dashes/spaces, spaces → dashes.
    static func headingSlug(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        var kept = ""
        for scalar in trimmed.unicodeScalars {
            if CharacterSet.letters.contains(scalar)
                || CharacterSet.decimalDigits.contains(scalar)
                || scalar == "-" || scalar == " " {
                kept.unicodeScalars.append(scalar)
            }
        }
        return kept.replacingOccurrences(of: " +", with: "-",
                                         options: .regularExpression)
    }

    /// Headings of a Markdown document (outside code fences), as
    /// (title, slug) pairs for palette jumping.
    static func headings(in markdown: String) -> [(title: String, slug: String)] {
        var inFence = false
        var result: [(String, String)] = []
        for line in markdown.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            guard !inFence, trimmed.hasPrefix("#") else { continue }
            var title = String(trimmed.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            // Approximate the rendered textContent the page slugged: inline
            // links/images collapse to their text, code/emphasis markers drop.
            title = title.replacingOccurrences(of: #"!?\[([^\]]*)\]\([^)]*\)"#,
                                               with: "$1", options: .regularExpression)
            title = title.replacingOccurrences(of: "[`*_]", with: "",
                                               options: .regularExpression)
            guard !title.isEmpty else { continue }
            result.append((title, headingSlug(title)))
        }
        return result
    }

    /// A ⌘K query that IS a destination rather than a search term: a GitHub
    /// pull request URL/reference, or an absolute (or `~`-, or `file://`-)
    /// path that exists on disk. The palette offers these as an "Open …" row
    /// above the fuzzy matches. `fileExists` is injectable so the parsing
    /// stays unit-testable without touching the real filesystem.
    enum DirectDestination: Equatable {
        /// Expanded, standardized absolute path, verified to exist.
        case path(String)
        case pullRequest(PullRequestRef)
    }

    static func directDestination(
        for query: String,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> DirectDestination? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let ref = PullRequestRef.parse(trimmed) {
            return .pullRequest(ref)
        }
        var path = trimmed
        if path.lowercased().hasPrefix("file://"),
           let url = URL(string: path), url.isFileURL {
            path = url.path
        }
        if path.hasPrefix("~") {
            path = (path as NSString).expandingTildeInPath
        }
        guard path.hasPrefix("/") else { return nil }
        let standardized = (path as NSString).standardizingPath
        guard fileExists(standardized) else { return nil }
        return .path(standardized)
    }
}
