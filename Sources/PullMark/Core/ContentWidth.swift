import Foundation

/// The reading measure for rendered documents and diffs. Standard is the
/// per-theme measure the app has always used (classic readable line
/// lengths); Wide trades some reading comfort for more on screen, still
/// capped where research puts the ceiling of tolerable line length; Full
/// Width hands the whole window to the content. Deliberately three curated
/// states, not a pixel field — every option is a considered layout.
enum ContentWidth: String, CaseIterable, Identifiable {
    case standard
    case wide
    case full

    var id: String { rawValue }

    static let defaultsKey = "pm.contentWidth"

    var label: String {
        switch self {
        case .standard: return String(localized: "Standard")
        case .wide: return String(localized: "Wide")
        case .full: return String(localized: "Full Width")
        }
    }

    var descriptor: String {
        switch self {
        case .standard: return "A classic reading measure"
        case .wide: return "Longer lines, more on screen"
        case .full: return "Text uses the whole window"
        }
    }

    /// Value for the page's `data-width` attribute; nil (no attribute)
    /// keeps the stylesheet's untouched default cascade.
    var dataValue: String? {
        self == .standard ? nil : rawValue
    }

    static var current: ContentWidth {
        UserDefaults.pullmark.string(forKey: defaultsKey)
            .flatMap(ContentWidth.init(rawValue:)) ?? .standard
    }
}
