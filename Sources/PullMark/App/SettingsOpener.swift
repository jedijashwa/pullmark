import AppKit

/// Opens the Settings window on a chosen tab — the release-notes
/// deep-link target (pullmark://settings/<tab>). The tab lands via the
/// same stored selection SettingsView reads, so this works from any
/// context that can write defaults.
@MainActor
enum SettingsOpener {
    static func open(tab: String? = nil) {
        if let tab {
            UserDefaults.pullmark.set(tab, forKey: DefaultsKeys.settingsTab)
        }
        NSApp.activate(ignoringOtherApps: true)
        // Ventura renamed the selector; try the modern one first.
        if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }
}
