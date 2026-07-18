import SwiftUI

@main
enum PullMarkLauncher {
    /// Direct terminal invocations of the bundled binary with file/folder
    /// arguments are relaunched through LaunchServices: AppKit turns raw
    /// argv paths into open-document events in a way that suppresses the
    /// main window, whereas the `open` path is fully supported.
    static func main() {
        let fm = FileManager.default
        let cwd = fm.currentDirectoryPath
        let paths = CommandLine.arguments.dropFirst()
            .filter { !$0.hasPrefix("-") }
            .map { $0.hasPrefix("/") ? $0 : cwd + "/" + $0 }
            .filter { fm.fileExists(atPath: $0) }
        let bundlePath = Bundle.main.bundlePath
        if !paths.isEmpty, bundlePath.hasSuffix(".app") {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-a", bundlePath] + paths
            do {
                try process.run()
                process.waitUntilExit()
                exit(process.terminationStatus)
            } catch {
                // Fall through and start normally.
            }
        }
        PullMarkApp.main()
    }
}

struct PullMarkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState()
    @AppStorage(Appearance.defaultsKey) private var appearanceRaw = Appearance.system.rawValue

    private func open(_ urlString: String) {
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
                .onChange(of: appearanceRaw) { newValue in
                    (Appearance(rawValue: newValue) ?? .system).apply()
                }
        }
        // Route file-open events into the existing window instead of
        // spawning a second one.
        .handlesExternalEvents(matching: ["*"])
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open…") { state.openFileOrFolder() }
                    .keyboardShortcut("o")
                Button("Open Pull Request…") { state.showAddPR = true }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Menu("Open Recent") {
                    ForEach(state.recents) { item in
                        Button(item.title) { state.openRecent(item) }
                    }
                    if !state.recents.isEmpty {
                        Divider()
                        Button("Clear Menu") { state.clearRecents() }
                    }
                }
            }
            CommandGroup(after: .textEditing) {
                Button("Find in Page") { state.findBarVisible = true }
                    .keyboardShortcut("f")
            }
            CommandGroup(replacing: .help) {
                Button("PullMark Website") {
                    open("https://pullmark.app")
                }
                Divider()
                Button("Report a Bug…") {
                    open("https://github.com/jedijashwa/pullmark/issues/new?template=1-bug_report.yml")
                }
                Button("Request a Feature…") {
                    open("https://github.com/jedijashwa/pullmark/issues/new?template=2-feature_request.yml")
                }
                Divider()
                Button("Support PullMark ❤️") {
                    open("https://ko-fi.com/pullmark")
                }
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

/// Files and folders passed as command-line arguments, so the binary can be
/// invoked as `PullMark <file-or-directory> ...` from a terminal. Consumed
/// once: both the app delegate and AppState ask (their initialization order
/// is not guaranteed), and whichever comes first handles the arguments.
@MainActor
enum LaunchArguments {
    private static var consumed = false

    static func consumeFileURLs() -> [URL] {
        guard !consumed else { return [] }
        consumed = true
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        return CommandLine.arguments.dropFirst().compactMap { argument in
            guard !argument.hasPrefix("-") else { return nil }
            let url = URL(fileURLWithPath: argument, relativeTo: cwd).standardizedFileURL
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
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
        let cliURLs = LaunchArguments.consumeFileURLs()
        if !cliURLs.isEmpty {
            NotificationCenter.default.post(name: .pullMarkOpenURLs, object: cliURLs)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        NotificationCenter.default.post(name: .pullMarkOpenURLs, object: urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
