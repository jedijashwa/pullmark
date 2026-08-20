import Foundation

/// Abbreviates the current user's home directory to `~` in paths shown in the
/// UI (titlebar subtitles, tooltips, search-result subtitles). Pure string
/// logic so it stays unit-testable; pass `home` explicitly in tests.
enum PathAbbreviator {
    /// Demo mode only: the demo session's real files live in a temp dir,
    /// and `/var/folders/…/T/PullMark Demo` in the titlebar ruins every
    /// published screenshot. Set by DemoSession when it writes the docs;
    /// display shows the path a real user would plausibly have. Never
    /// set outside demo mode — real paths are never masked.
    static var demoRoot: String?
    static let demoDisplayRoot = "~/Documents/PullMark Demo"

    static func abbreviate(_ path: String, home: String = NSHomeDirectory()) -> String {
        if let demoRoot, path.hasPrefix(demoRoot) {
            return demoDisplayRoot + path.dropFirst(demoRoot.count)
        }
        guard !home.isEmpty, home != "/" else { return path }
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        if path == home { return "~" }
        guard path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }
}
