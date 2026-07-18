import AppKit

enum Appearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let defaultsKey = "pm.appearance"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// Setting NSApp.appearance cascades to every window and to WKWebView's
    /// `prefers-color-scheme`, so a single override handles both the native
    /// chrome and the rendered Markdown.
    @MainActor func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    @MainActor static func applyCurrent() {
        let raw = UserDefaults.standard.string(forKey: defaultsKey) ?? Appearance.system.rawValue
        (Appearance(rawValue: raw) ?? .system).apply()
    }
}
