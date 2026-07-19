import Foundation

/// Folder-wide docs lint: broken relative links, dead heading anchors,
/// missing images, and orphaned pages, computed from the Markdown alone.
/// Pure — file contents come in through a reader closure so tests never
/// touch the disk.
enum DocDoctor {
    enum Kind: String {
        case brokenLink = "Broken link"
        case brokenImage = "Missing image"
        case deadAnchor = "Dead anchor"
        case orphanPage = "Orphan page"
    }

    struct Issue: Identifiable, Equatable {
        /// Repo-relative path of the file the issue is in.
        let file: String
        /// 1-based line, when the issue points at a specific reference.
        let line: Int?
        let kind: Kind
        /// The offending target, e.g. "img/gone.png" or "docs/x.md#setup".
        let target: String
        /// The link's visible text — what find-in-page can actually locate
        /// on the rendered page (hrefs aren't rendered text).
        var label: String = ""
        var id: String { "\(file):\(line ?? 0):\(kind.rawValue):\(target)" }
    }

    /// Inline links/images in a line: (isImage, target, label) triples.
    /// Angle-bracket targets carry spaces; plain targets allow one level of
    /// parentheses (CommonMark requires <…> beyond that). Reference
    /// definitions and autolinks are out of scope (v1).
    static func references(in line: String) -> [(isImage: Bool, target: String, label: String)] {
        var results: [(Bool, String, String)] = []
        let pattern = #"(!?)\[([^\]]*)\]\((?:<([^>]*)>|((?:[^()\s]|\([^()]*\))+))(?:\s[^)]*)?\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(line.startIndex..., in: line)
        for match in regex.matches(in: line, range: range) {
            guard let bangRange = Range(match.range(at: 1), in: line),
                  let labelRange = Range(match.range(at: 2), in: line) else { continue }
            let target: String
            if let angle = Range(match.range(at: 3), in: line) {
                target = String(line[angle])
            } else if let plain = Range(match.range(at: 4), in: line) {
                target = String(line[plain])
            } else {
                continue
            }
            results.append((!line[bangRange].isEmpty, target, String(line[labelRange])))
        }
        return results
    }

    /// Scans `files` (relative path → present) using `read` for contents.
    /// External URLs (scheme://, mailto:) and pure #anchors into the same
    /// file are checked against that file's own headings.
    static func scan(files: [String], read: (String) -> String?) -> [Issue] {
        let fileSet = Set(files)
        var issues: [Issue] = []
        var headingCache: [String: Set<String>] = [:]
        func slugs(of file: String) -> Set<String> {
            if let cached = headingCache[file] { return cached }
            let computed = Set(OpenQuickly.headings(in: read(file) ?? "").map(\.slug))
            headingCache[file] = computed
            return computed
        }
        var linkedTo: Set<String> = []

        for file in files.sorted() {
            guard let text = read(file) else { continue }
            let directory = (file as NSString).deletingLastPathComponent
            // Fences pair by their own marker: a ~~~ inside a ``` fence is
            // content, not a toggle.
            var fenceMarker: Character?
            for (index, line) in text.components(separatedBy: "\n").enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                    let marker = trimmed.first!
                    if fenceMarker == nil {
                        fenceMarker = marker
                    } else if fenceMarker == marker {
                        fenceMarker = nil
                    }
                    continue
                }
                guard fenceMarker == nil else { continue }
                for reference in references(in: line) {
                    let target = reference.target
                    if target.contains("://") || target.hasPrefix("mailto:") { continue }
                    let lineNumber = index + 1
                    let label = reference.label
                    if target.hasPrefix("#") {
                        // Same-file anchor.
                        let slug = (String(target.dropFirst()).removingPercentEncoding
                            ?? String(target.dropFirst())).lowercased()
                        if !slugs(of: file).contains(slug) {
                            issues.append(Issue(file: file, line: lineNumber,
                                                kind: .deadAnchor, target: target,
                                                label: label))
                        }
                        continue
                    }
                    let rawPath = target.components(separatedBy: "#").first ?? target
                    let pathPart = rawPath.removingPercentEncoding ?? rawPath
                    let anchorPart = target.contains("#")
                        ? target.components(separatedBy: "#").last : nil
                    guard let resolved = normalize(directory.isEmpty
                        ? pathPart
                        : directory + "/" + pathPart) else { continue }  // escapes root: unverifiable
                    if reference.isImage {
                        if !fileSet.contains(resolved) {
                            issues.append(Issue(file: file, line: lineNumber,
                                                kind: .brokenImage, target: target,
                                                label: label))
                        }
                        continue
                    }
                    guard resolved.lowercased().hasSuffix(".md")
                        || fileSet.contains(resolved) else { continue }
                    if !fileSet.contains(resolved) {
                        issues.append(Issue(file: file, line: lineNumber,
                                            kind: .brokenLink, target: target,
                                            label: label))
                        continue
                    }
                    linkedTo.insert(resolved)
                    if let anchor = anchorPart, !anchor.isEmpty,
                       !slugs(of: resolved).contains(
                           (anchor.removingPercentEncoding ?? anchor).lowercased()) {
                        issues.append(Issue(file: file, line: lineNumber,
                                            kind: .deadAnchor, target: target,
                                            label: label))
                    }
                }
            }
        }

        // Orphans: Markdown pages nothing links to (roots excluded — a
        // README/index is entered directly, not linked).
        for file in files.sorted()
        where file.lowercased().hasSuffix(".md") && !linkedTo.contains(file) {
            let name = (file as NSString).lastPathComponent.lowercased()
            if name == "readme.md" || name == "index.md" { continue }
            if !file.contains("/") { continue }  // top-level pages are entry points
            issues.append(Issue(file: file, line: nil, kind: .orphanPage, target: file))
        }
        return issues
    }

    /// Resolves "a/b/../c" and "./x" without touching the filesystem; nil
    /// when the path escapes the scanned root (a leading "..") — such links
    /// can't be verified and must be skipped, not guessed root-relative.
    static func normalize(_ path: String) -> String? {
        var parts: [String] = []
        for component in path.components(separatedBy: "/") {
            switch component {
            case "", ".": continue
            case "..":
                guard !parts.isEmpty else { return nil }
                parts.removeLast()
            default: parts.append(component)
            }
        }
        return parts.joined(separator: "/")
    }
}
