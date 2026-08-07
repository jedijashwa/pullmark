import AppKit
import SwiftUI

/// Opens the Settings window on a chosen tab — the release-notes
/// deep-link target (pullmark://settings/<tab>). The tab lands via the
/// same stored selection SettingsView reads. Opening the window uses
/// SwiftUI's openSettings action where it exists (the sendAction
/// selector silently no-ops on modern macOS from most contexts); a
/// grabber view in ContentView registers it at launch.
@MainActor
enum SettingsOpener {
    /// The macOS 14+ openSettings environment action, captured by
    /// OpenSettingsGrabber. Nil on macOS 13, where sendAction works.
    static var modern: (() -> Void)?

    /// Set when a deep link targets an ALPHA feature: the Experimental
    /// tab consumes it and — when alpha features are hidden — pops the
    /// alpha-contract dialog, so the link never lands on a tab that
    /// appears empty. A link to the tab itself never prompts.
    static var pendingAlphaPrompt = false

    static func open(tab: String? = nil, feature: String? = nil) {
        if let tab {
            UserDefaults.pullmark.set(tab, forKey: DefaultsKeys.settingsTab)
            if let feature, AppLinks.alphaFeatures.contains(feature) {
                pendingAlphaPrompt = true
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        if let modern {
            modern()
        } else if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            // Ventura renamed the selector; the old name is the fallback.
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
        // Neither path re-orders a Settings window that already exists
        // behind the main window — find it (next runloop turn, so a
        // freshly created one is there too) and bring it forward.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            NSApp.windows.first {
                $0.identifier?.rawValue.contains("Settings") == true
            }?.makeKeyAndOrderFront(nil)
        }
    }
}

/// Invisible resident of ContentView's background: captures the
/// environment's openSettings action once so non-View code paths
/// (deep links) can open Settings reliably.
struct OpenSettingsGrabber: View {
    var body: some View {
        if #available(macOS 14.0, *) {
            OpenSettingsGrabberModern()
        } else {
            Color.clear
        }
    }
}

@available(macOS 14.0, *)
private struct OpenSettingsGrabberModern: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear
            .onAppear { SettingsOpener.modern = { openSettings() } }
    }
}
