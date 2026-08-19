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
        "compare",
        "settings",
        "settings/general",
        "settings/themes",
        "settings/keyboard",
        "settings/experimental",
        "settings/experimental/margin-notes",
        // Review discussion graduated to General in the cockpit wave;
        // the old experimental link stays a promise — settingsTarget
        // remaps it to the toggle's new home.
        "settings/experimental/pr-discussion",
        // General
        "settings/general/pr-discussion",
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
        let anchor = parts.count > 1 ? parts[1] : nil
        // Graduated settings keep their old links working: docs and
        // release notes already published the experimental form.
        if tab == "experimental", anchor == "pr-discussion" {
            return ("general", "pr-discussion")
        }
        return (tab, anchor)
    }

    /// What a compare deep link asks the file's view to diff.
    enum CompareRequest: Equatable {
        /// The working file against one ref (HEAD, a branch, tag, SHA).
        case workingAgainstRef(String)
        /// The file at two refs — both sides frozen, REF1..REF2 syntax
        /// (refnames cannot contain "..", so the split is unambiguous).
        case refAgainstRef(old: String, new: String)
        /// The working file against another file on disk (the baseline).
        case againstFile(URL)
    }

    /// Parses a compare deep link, the CLI's --diff/--diff-with channel:
    ///   pullmark://compare?file=<abs>[&ref=<ref> | &ref=<r1>..<r2> | &with=<abs>]
    /// Paths must be absolute (the CLI resolves relative paths against its
    /// own working directory — the app has no idea what that was); `ref`
    /// defaults to HEAD.
    static func compareTarget(_ url: URL) -> (file: URL, request: CompareRequest)? {
        guard url.scheme == "pullmark", url.host == "compare",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let path = components.queryItems?.first(where: { $0.name == "file" })?.value,
              path.hasPrefix("/")
        else { return nil }
        let file = URL(fileURLWithPath: path)
        if let with = components.queryItems?.first(where: { $0.name == "with" })?.value {
            guard with.hasPrefix("/") else { return nil }
            return (file, .againstFile(URL(fileURLWithPath: with)))
        }
        let ref = components.queryItems?.first(where: { $0.name == "ref" })?.value
            .flatMap { $0.isEmpty ? nil : $0 } ?? "HEAD"
        if let dots = ref.range(of: "..") {
            let old = String(ref[..<dots.lowerBound])
            let new = String(ref[dots.upperBound...])
            // Empty sides, three-dot ranges, and extra ".."s are
            // rejected, not guessed.
            guard !old.isEmpty, !new.isEmpty, !new.hasPrefix("."),
                  !new.contains("..") else { return nil }
            return (file, .refAgainstRef(old: old, new: new))
        }
        return (file, .workingAgainstRef(ref))
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
