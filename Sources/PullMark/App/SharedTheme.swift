import Foundation

/// Mirrors the reading-theme choice into the shared app-group defaults
/// suite so the sandboxed Quick Look extension (its own container, its own
/// defaults domain) can render previews in the theme the user reads in.
/// The group id is team-prefixed, which is what lets both signed bundles
/// open it without a consent prompt.
enum SharedTheme {
    static let suiteName = "35F47G5Y6D.app.pullmark"

    private static var observer: NSObjectProtocol?

    /// Syncs the current value and keeps syncing on every defaults change
    /// (theme writes happen from Settings, @AppStorage, and ThemeSelection —
    /// observing the domain catches all of them). Cheap: writes only when
    /// the mirrored value actually differs.
    static func startMirroring() {
        mirror()
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { _ in mirror() }
    }

    private static func mirror() {
        guard let shared = UserDefaults(suiteName: suiteName) else { return }
        let theme = UserDefaults.standard.string(forKey: DefaultsKeys.theme)
        guard shared.string(forKey: DefaultsKeys.theme) != theme else { return }
        shared.set(theme, forKey: DefaultsKeys.theme)
    }
}
