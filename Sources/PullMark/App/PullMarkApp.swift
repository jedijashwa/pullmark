import SwiftUI

@main
struct PullMarkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState()
    @AppStorage(Appearance.defaultsKey) private var appearanceRaw = Appearance.system.rawValue

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
                .onChange(of: appearanceRaw) { newValue in
                    (Appearance(rawValue: newValue) ?? .system).apply()
                }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open…") { state.openFileOrFolder() }
                    .keyboardShortcut("o")
                Button("Open Pull Request…") { state.showAddPR = true }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandGroup(after: .toolbar) {
                Picker("Appearance", selection: $appearanceRaw) {
                    ForEach(Appearance.allCases) { appearance in
                        Text(appearance.label).tag(appearance.rawValue)
                    }
                }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched via `swift run` (no bundle): become a regular,
        // focusable app with a menu bar.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        Appearance.applyCurrent()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        NotificationCenter.default.post(name: .pullMarkOpenURLs, object: urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
