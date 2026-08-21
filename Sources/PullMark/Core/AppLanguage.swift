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

    /// The language this process actually launched with — pinned at
    /// startup (PullMarkApp touches it) so the Settings row can tell a
    /// pending change from the status quo and offer a relaunch.
    static let atLaunch: AppLanguage = current

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

    /// The lproj this choice would relaunch into — for .system, the
    /// system's own preference order matched against what we ship
    /// (read from the GLOBAL domain: this process's Locale is already
    /// colored by the current per-app override). nil means English,
    /// which has no lproj — keys are the strings.
    private var relaunchLproj: String? {
        switch self {
        case .english:
            return nil
        case .system:
            let global = CFPreferencesCopyValue(
                "AppleLanguages" as CFString, kCFPreferencesAnyApplication,
                kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String] ?? []
            let shipped = AppLanguage.allCases.map(\.rawValue).filter { $0 != "system" }
            let preferred = Bundle.preferredLocalizations(from: shipped + ["en"], forPreferences: global)
            let first = preferred.first ?? "en"
            return first == "en" ? nil : first
        default:
            return rawValue
        }
    }

    /// Resolve a localized key IN THIS LANGUAGE rather than the launch
    /// language. The Settings relaunch row uses it so "takes effect
    /// after relaunch" and its button read in the language the user
    /// just chose — the one they're headed to (and can read).
    func resolve(_ key: String, fallback: String) -> String {
        guard let lproj = relaunchLproj,
              let path = Bundle.main.path(forResource: lproj, ofType: "lproj"),
              let bundle = Bundle(path: path)
        else { return fallback }
        return bundle.localizedString(forKey: key, value: fallback, table: nil)
    }
}
