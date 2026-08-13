import Foundation

/// File-extension → highlight.js language mapping for the review
/// discussion's code excerpts (spec: pr-review-discussion). Curated,
/// not exhaustive — highlight.js deliberately owns no extension map
/// (hosts maintain their own, GitHub uses Linguist's), and an unknown
/// extension renders plain, which is the graceful floor.
enum CodeLanguages {
    private static let byExtension: [String: String] = [
        "swift": "swift",
        "js": "javascript", "mjs": "javascript", "cjs": "javascript",
        "jsx": "javascript",
        "ts": "typescript", "tsx": "typescript",
        "py": "python",
        "rb": "ruby",
        "go": "go",
        "rs": "rust",
        "java": "java",
        "kt": "kotlin", "kts": "kotlin",
        "c": "c", "h": "c",
        "cpp": "cpp", "cc": "cpp", "cxx": "cpp", "hpp": "cpp",
        "m": "objectivec", "mm": "objectivec",
        "cs": "csharp",
        "php": "php",
        "sh": "bash", "bash": "bash", "zsh": "bash",
        "yml": "yaml", "yaml": "yaml",
        "json": "json",
        "toml": "ini",
        "css": "css", "scss": "scss", "less": "less",
        "html": "xml", "htm": "xml", "xml": "xml", "svg": "xml",
        "sql": "sql",
        "md": "markdown", "markdown": "markdown",
        "diff": "diff", "patch": "diff",
        "pl": "perl",
        "lua": "lua",
        "r": "r",
        "dart": "dart",
        "gradle": "gradle",
    ]

    /// Marker-named files with no useful extension.
    private static let byFilename: [String: String] = [
        "dockerfile": "dockerfile",
        "makefile": "makefile",
        "gemfile": "ruby",
        "rakefile": "ruby",
    ]

    /// The highlight.js language for a repo path, or nil → plain text.
    static func hljsLanguage(forPath path: String) -> String? {
        let name = (path as NSString).lastPathComponent.lowercased()
        if let byName = byFilename[name] { return byName }
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty else { return nil }
        return byExtension[ext]
    }
}
