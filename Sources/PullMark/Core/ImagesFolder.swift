import Foundation

/// Where pasted and dropped images go (spec: rich-editor §9): the
/// Location's override if set, else the folder the repository's Markdown
/// already references most, else `<document>.assets/` next to the
/// document. Pure path logic; the view layer does the reading and writing.
enum ImagesFolder {
    /// Root-relative directory that the given Markdown files reference
    /// most often in image links (`![alt](path)` and `<img src>`), or nil
    /// when none references a local image. `files` pairs a root-relative
    /// document path with its text; references resolve against the
    /// document's directory.
    static func detect(files: [(path: String, text: String)]) -> String? {
        var counts: [String: Int] = [:]
        let pattern = try! NSRegularExpression(
            pattern: #"!\[[^\]]*\]\(\s*<?([^)\s>]+)>?[^)]*\)|<img[^>]+src=["']([^"']+)["']"#,
            options: [.caseInsensitive])
        for file in files {
            let ns = file.text as NSString
            let dir = (file.path as NSString).deletingLastPathComponent
            for match in pattern.matches(in: file.text, range: NSRange(location: 0, length: ns.length)) {
                let range = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
                guard range.location != NSNotFound else { continue }
                let target = ns.substring(with: range)
                if target.range(of: #"^[a-z][a-z0-9+.-]*:"#, options: .regularExpression) != nil
                    || target.hasPrefix("//") || target.hasPrefix("#") { continue }
                let joined = target.hasPrefix("/") ? String(target.dropFirst())
                    : (dir.isEmpty ? target : dir + "/" + target)
                let folder = (normalized(joined) as NSString).deletingLastPathComponent
                counts[folder, default: 0] += 1
            }
        }
        return counts.max { a, b in a.value == b.value ? a.key > b.key : a.value < b.value }?.key
    }

    /// The folder to write into, as an absolute URL.
    static func destination(document: URL, root: URL?, override: String?, detected: String?) -> URL {
        if let root, let override, !override.isEmpty {
            return root.appendingPathComponent(override, isDirectory: true)
        }
        if let root, let detected {
            return root.appendingPathComponent(detected, isDirectory: true)
        }
        let name = document.deletingPathExtension().lastPathComponent + ".assets"
        return document.deletingLastPathComponent().appendingPathComponent(name, isDirectory: true)
    }

    /// A safe file name that doesn't collide with anything in `folder`:
    /// `photo.png`, then `photo-2.png`, …
    static func uniqueName(_ preferred: String, existing: Set<String>) -> String {
        let cleaned = sanitized(preferred)
        guard existing.contains(cleaned) else { return cleaned }
        let ext = (cleaned as NSString).pathExtension
        let stem = (cleaned as NSString).deletingPathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem)-\(n)" : "\(stem)-\(n).\(ext)"
            if !existing.contains(candidate) { return candidate }
            n += 1
        }
    }

    /// Pasted images arrive nameless; a timestamped name keeps them apart.
    static func pastedName(type: String, date: Date = Date()) -> String {
        let ext: String
        switch type.lowercased() {
        case "image/png": ext = "png"
        case "image/jpeg", "image/jpg": ext = "jpg"
        case "image/gif": ext = "gif"
        case "image/webp": ext = "webp"
        case "image/svg+xml": ext = "svg"
        case "image/heic": ext = "heic"
        default: ext = "png"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "pasted-\(formatter.string(from: date)).\(ext)"
    }

    /// The Markdown link target from `document` to `target`: a relative
    /// path with spaces and parentheses percent-encoded, forward slashes.
    static func relativeLink(from document: URL, to target: URL) -> String {
        let docParts = Array(document.deletingLastPathComponent().standardizedFileURL.pathComponents.dropFirst())
        let targetParts = Array(target.standardizedFileURL.pathComponents.dropFirst())
        var common = 0
        while common < docParts.count, common < targetParts.count, docParts[common] == targetParts[common] {
            common += 1
        }
        let ups = Array(repeating: "..", count: docParts.count - common)
        let rest = targetParts[common...]
        let parts = ups + rest
        return parts.map(encodeSegment).joined(separator: "/")
    }

    /// Whether `url` sits inside `root` (or equals it).
    static func isInside(_ url: URL, root: URL) -> Bool {
        let a = url.standardizedFileURL.path, b = root.standardizedFileURL.path
        return a == b || a.hasPrefix(b.hasSuffix("/") ? b : b + "/")
    }

    // MARK: Helpers

    private static func normalized(_ path: String) -> String {
        var out: [String] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { if !out.isEmpty { out.removeLast() }; continue }
            out.append(String(part))
        }
        return out.joined(separator: "/")
    }

    private static func sanitized(_ name: String) -> String {
        var s = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "\\", with: "-")
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { s = "image" }
        return s
    }

    private static func encodeSegment(_ segment: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "()% ")
        return segment.addingPercentEncoding(withAllowedCharacters: allowed) ?? segment
    }
}
