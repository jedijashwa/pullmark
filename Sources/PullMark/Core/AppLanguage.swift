import Foundation

/// The in-app language override (spec: app-i18n). Stored as the
/// AppleLanguages array in the app's own defaults domain — the same
/// mechanism the system's per-app Language & Region setting uses, so
/// the two never fight: whichever wrote last wins, exactly like every
/// other app. Strings resolve at launch, so a change applies the next
/// time PullMark opens.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case chinese = "zh-Hans"
    case japanese = "ja"
    case french = "fr"
    case german = "de"
    case dutch = "nl"
    case spanish = "es"
    case portuguese = "pt-BR"

    var id: String { rawValue }

    /// Every language names itself — deliberately never translated,
    /// matching the site's switcher: a reader hunting for their own
    /// language finds it in that language.
    var label: String {
        switch self {
        case .system: return String(localized: "System")
        case .english: return "English"
        case .chinese: return "中文"
        case .japanese: return "日本語"
        case .french: return "Français"
        case .german: return "Deutsch"
        case .dutch: return "Nederlands"
        case .spanish: return "Español"
        case .portuguese: return "Português"
        }
    }

    static var current: AppLanguage {
        guard let languages = UserDefaults.pullmark.array(forKey: "AppleLanguages") as? [String],
              let first = languages.first else { return .system }
        return AppLanguage(rawValue: first) ?? .system
    }

    func apply() {
        if self == .system {
            UserDefaults.pullmark.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.pullmark.set([rawValue], forKey: "AppleLanguages")
        }
    }
}
