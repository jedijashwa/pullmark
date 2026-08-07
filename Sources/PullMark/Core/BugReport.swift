import Foundation

/// Builds the Help ▸ Report a Bug… URL: GitHub issue forms pre-fill any
/// field from a query param named after its id, so the running app can
/// hand over the two fields nobody should have to look up.
enum BugReport {
    static func url(version: String, macOSVersion: String,
                    title: String? = nil,
                    whatHappened: String? = nil) -> URL? {
        var components = URLComponents(string: "https://github.com/jedijashwa/pullmark/issues/new")
        var items = [
            URLQueryItem(name: "template", value: "1-bug_report.yml"),
            URLQueryItem(name: "version", value: version),
            URLQueryItem(name: "macos", value: macOSVersion),
        ]
        // Only auto-reports carry a title — the app titles what it can
        // describe truthfully; a human reporter titles their own bug.
        if let title {
            items.append(URLQueryItem(name: "title", value: title))
        }
        if let whatHappened {
            items.append(URLQueryItem(name: "what-happened", value: whatHappened))
        }
        components?.queryItems = items
        return components?.url
    }

    /// "macOS 26.5" — the template's requested shape.
    static func macOSVersionString(_ v: OperatingSystemVersion) -> String {
        "macOS \(v.majorVersion).\(v.minorVersion)"
    }
}
