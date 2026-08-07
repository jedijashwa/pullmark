import Foundation

/// pullmark:// deep links in release notes are promises — and a build
/// should only render the promises it can keep. This registry lists
/// every target THIS build supports; `sanitize` demotes any pullmark://
/// markdown link with an unknown target to plain text, so notes written
/// for a future (or past) version never show a link that goes nowhere.
enum AppLinks {
    /// host/path forms this build can open. Grows with new targets;
    /// entries for retired targets are removed, which is what makes old
    /// notes' links quietly stop being links.
    /// Tab targets, plus per-setting anchors the tabs can scroll to and
    /// highlight. Anchor ids mirror the docs pages' spellings.
    static let supported: Set<String> = [
        "settings",
        "settings/general",
        "settings/themes",
        "settings/keyboard",
        "settings/experimental",
        "settings/experimental/margin-notes",
        // General
        "settings/general/restore-session",
        "settings/general/show-hidden-files",
        "settings/general/github-links",
        "settings/general/clicking-files",
        "settings/general/diff-layout",
        "settings/general/review-requests",
        "settings/general/whats-new",
        "settings/general/check-updates",
        "settings/general/default-app",
        "settings/general/command-line",
        "settings/general/quick-look",
        // Appearance (stored tab tag: "themes")
        "settings/themes/appearance-mode",
        "settings/themes/theme",
        "settings/themes/content-width",
        "settings/themes/line-numbers",
    ]

    /// Experimental features currently at the ALPHA level — a deep link
    /// straight to one offers the "Show alpha features" switch when
    /// alpha is hidden (a link to the tab alone never does).
    static let alphaFeatures: Set<String> = ["margin-notes"]

    /// Parses a settings deep link: pullmark://settings/<tab>[/<anchor>].
    static func settingsTarget(_ url: URL) -> (tab: String, anchor: String?)? {
        guard url.scheme == "pullmark", url.host == "settings", isSupported(url)
        else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard let tab = parts.first else { return ("general", nil) }
        return (tab, parts.count > 1 ? parts[1] : nil)
    }

    static func isSupported(_ url: URL) -> Bool {
        guard url.scheme == "pullmark", let host = url.host else { return false }
        let path = url.path.split(separator: "/").joined(separator: "/")
        let target = path.isEmpty ? host : "\(host)/\(path)"
        return supported.contains(target)
    }

    /// Markdown in, markdown out: `[text](pullmark://…)` stays a link
    /// only when this build supports the target; otherwise just `text`.
    /// Web links are untouched.
    static func sanitize(_ markdown: String) -> String {
        let pattern = #"\[([^\]]*)\]\((pullmark://[^)\s]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return markdown }
        let full = NSRange(markdown.startIndex..., in: markdown)
        var result = ""
        var cursor = markdown.startIndex
        for match in regex.matches(in: markdown, range: full) {
            guard let whole = Range(match.range, in: markdown),
                  let textRange = Range(match.range(at: 1), in: markdown),
                  let urlRange = Range(match.range(at: 2), in: markdown) else { continue }
            result += markdown[cursor..<whole.lowerBound]
            let text = String(markdown[textRange])
            let urlString = String(markdown[urlRange])
            if let url = URL(string: urlString), isSupported(url) {
                result += markdown[whole]
            } else {
                result += text
            }
            cursor = whole.upperBound
        }
        result += markdown[cursor...]
        return result
    }
}
