import Foundation

/// Reading theme for rendered Markdown. Each theme supports both light and
/// dark, composing with the System/Light/Dark `Appearance` setting: the
/// theme picks fonts and a palette, the appearance picks which side of the
/// palette is active (via `prefers-color-scheme` in the web view).
enum Theme: String, CaseIterable, Identifiable {
    case github
    case editorial
    case terminal

    static let defaultsKey = DefaultsKeys.theme

    var id: String { rawValue }

    var label: String {
        switch self {
        case .github: return "GitHub"
        case .editorial: return "Editorial"
        case .terminal: return "Terminal"
        }
    }

    /// One-line descriptor shown under the theme's preview card.
    var descriptor: String {
        switch self {
        case .github: return "The classic look, exactly as on github.com"
        case .editorial: return "Bookish serif headers on warm paper"
        case .terminal: return "Monospace with a phosphor-green accent"
        }
    }

    /// The app-default theme. Every reader of the stored selection must
    /// fall back to this — including the `@AppStorage(Theme.defaultsKey)`
    /// declarations in views, whose inline defaults are what an unset key
    /// actually resolves to (they never consult `current(from:)`).
    static let standard: Theme = .editorial

    /// The stored selection, falling back to the default Editorial theme.
    static func current(from raw: String?) -> Theme {
        raw.flatMap(Theme.init(rawValue:)) ?? .standard
    }

    /// (light, dark) page paper colors, mirroring the `body { background }`
    /// values in app.css per theme — the source of the pre-CSS first paint
    /// and the SwiftUI backdrop behind the web view. Custom themes build on
    /// the GitHub base, so unknown raw values use the GitHub paper.
    static func paperHex(for raw: String) -> (light: String, dark: String) {
        switch Theme(rawValue: raw) {
        case .editorial: return ("#fbfaf8", "#10151c")
        case .terminal: return ("#f4f6f4", "#0a0f0c")
        case .github, .none: return ("#ffffff", "#0d1117")
        }
    }
}
