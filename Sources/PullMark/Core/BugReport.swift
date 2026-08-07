import Foundation

/// Builds the Help ▸ Report a Bug… URL: GitHub issue forms pre-fill any
/// field from a query param named after its id, so the running app can
/// hand over the two fields nobody should have to look up.
enum BugReport {
    static func url(version: String, macOSVersion: String) -> URL? {
        var components = URLComponents(string: "https://github.com/jedijashwa/pullmark/issues/new")
        components?.queryItems = [
            URLQueryItem(name: "template", value: "1-bug_report.yml"),
            URLQueryItem(name: "version", value: version),
            URLQueryItem(name: "macos", value: macOSVersion),
        ]
        return components?.url
    }

    /// "macOS 26.5" — the template's requested shape.
    static func macOSVersionString(_ v: OperatingSystemVersion) -> String {
        "macOS \(v.majorVersion).\(v.minorVersion)"
    }
}
