import Foundation

/// Abbreviates the current user's home directory to `~` in paths shown in the
/// UI (titlebar subtitles, tooltips, search-result subtitles). Pure string
/// logic so it stays unit-testable; pass `home` explicitly in tests.
enum PathAbbreviator {
    static func abbreviate(_ path: String, home: String = NSHomeDirectory()) -> String {
        guard !home.isEmpty, home != "/" else { return path }
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        if path == home { return "~" }
        guard path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }
}
