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
    /// The focused window's state; commands act on it (nil disables them).
    @FocusedObject private var focusedState: AppState?
    private var state: AppState? { focusedState ?? AppState.keyInstance }
    @StateObject private var updates = UpdateChecker()
    @StateObject private var defaultApp = DefaultAppManager()
    @AppStorage(Appearance.defaultsKey) private var appearanceRaw = Appearance.system.rawValue

    private func open(_ urlString: String) {
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    /// The selected local file — drives Save (⌘S) and Commit Changes….
    /// Read from the sidebar selection, not ActiveDocument: comparing
    /// unregisters the document, and Save must keep working with unsaved
    /// edits while a comparison is on screen.
    private var activeLocalFileURL: URL? {
        guard let selection = state?.selection, case .local(let url) = selection else { return nil }
        return url
    }

    /// Copy as Markdown (⌥⌘C): the page maps the selection to covered
    /// source lines (whole-block granularity via data-pm-lines), Swift
    /// slices the original markdown and puts plain text on the pasteboard.
    /// No selection copies the whole document source.
    private func copyAsMarkdown() {
        guard let document = state?.activeDocument else { return }
        document.proxy.selectionSourceLineRange { range in
            let source = MarkdownCopy.source(of: document.markdown, lineRange: range)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(source, forType: .string)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(updates)
                .environmentObject(defaultApp)
                .onChange(of: appearanceRaw) { newValue in
                    (Appearance(rawValue: newValue) ?? .system).apply()
                }
                // The scene-level modifier alone still spawns a fresh window
                // per open-file event; an existing window must also declare
                // that it prefers to handle those events.
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                // Launch-time open-document events are claimed by the SwiftUI
                // scene and never reach application(_:open:); without this
                // handler a document opened while the app is not running
                // would be silently dropped. (AppState.add is idempotent, so
                // overlap with the delegate path is harmless.)
        }
        // Route file-open events into the existing window instead of
        // spawning a second one.
        .handlesExternalEvents(matching: ["*"])
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    Task {
                        if let message = await updates.checkManually() {
                            state?.lastError = message
                        }
                    }
                }
            }
            CommandGroup(after: .newItem) {
                Button("Open…") { state?.openFileOrFolder() }
                    .keyboardShortcut("o")
                Button("Open Pull Request…") { state?.showAddPR = true }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Menu("Open Recent") {
                    ForEach(state?.recents ?? []) { item in
                        Button(item.title) { state?.openRecent(item) }
                    }
                    if state?.recents.isEmpty == false {
                        Divider()
                        Button("Clear Menu") { state?.clearRecents() }
                    }
                }
            }
            CommandGroup(replacing: .saveItem) {
                // Manual-save mode: writes the active document's pending
                // block edits; a no-op (disabled) when nothing is dirty.
                Button("Save") {
                    if let url = activeLocalFileURL { state?.saveEdits(for: url) }
                }
                .keyboardShortcut("s")
                .disabled(activeLocalFileURL.map { state?.editedText[$0] == nil } ?? true)
                Button("Commit Changes…") {
                    guard let url = activeLocalFileURL else { return }
                    if let root = LocalGit.repoRoot(for: url) {
                        state?.commitRequest = CommitRequest(root: root)
                    } else {
                        state?.lastNotice = "\(url.lastPathComponent) isn't inside a git repository."
                    }
                }
                .keyboardShortcut("k", modifiers: [.command, .control])
                .disabled(activeLocalFileURL == nil)
                .help("Stage and commit changes in this file's repository")
            }
            CommandGroup(replacing: .importExport) {
                Button("Export as PDF…") {
                    guard let document = state?.activeDocument else { return }
                    DocumentExport.exportPDF(document) { state?.lastError = $0 }
                }
                .disabled(state?.activeDocument == nil)
                .help("Save the rendered document as a PDF")
                Button("Export as HTML…") {
                    guard let document = state?.activeDocument else { return }
                    DocumentExport.exportHTML(document) { state?.lastError = $0 }
                }
                .disabled(state?.activeDocument == nil)
                .help("Save the rendered document as a self-contained HTML file")
            }
            // The system Copy item (⌘C) stays: WKWebView's native copy puts
            // rich HTML + plain text on the pasteboard for the selection.
            CommandGroup(after: .pasteboard) {
                Button("Copy as Markdown") { copyAsMarkdown() }
                    .keyboardShortcut("c", modifiers: [.command, .option])
                    .disabled(state?.activeDocument == nil)
                    .help("Copies the Markdown source of the selected blocks "
                        + "(whole blocks — or the whole document when nothing is selected)")
            }
            CommandGroup(after: .textEditing) {
                Button("Find in Page") { state?.findBarVisible = true }
                    .keyboardShortcut("f")
                Button("Search All Files…") { state?.searchPaletteVisible = true }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
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
                Divider()
                Button(state?.sourceViewVisible == true ? "Hide Markdown Source" : "Show Markdown Source") {
                    state?.sourceViewVisible.toggle()
                }
                .keyboardShortcut("u", modifiers: [.command, .option])
                .disabled(state?.activeDocument == nil)
                .help("Temporarily show the raw Markdown behind the rendered document")
            }
        }
        Settings {
            SettingsView()
                .environmentObject(updates)
                .environmentObject(defaultApp)
        }
    }
}

/// Routes open-file events (Finder, `open`, drag onto the Dock icon) to
/// AppState. On a cold launch with a document the event arrives before
/// SwiftUI has created the AppState, so URLs are buffered until the handler
/// registers — otherwise the document would be silently dropped.
@MainActor
final class OpenURLRouter {
    static let shared = OpenURLRouter()

    private var pending: [URL] = []
    private var handler: (([URL]) -> Void)?

    func deliver(_ urls: [URL]) {
        if let handler {
            handler(urls)
        } else {
            pending.append(contentsOf: urls)
        }
    }

    func onOpen(_ handler: @escaping ([URL]) -> Void) {
        self.handler = handler
        if !pending.isEmpty {
            let buffered = pending
            pending = []
            handler(buffered)
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
        SharedTheme.startMirroring()
        let cliURLs = LaunchArguments.consumeFileURLs()
        if !cliURLs.isEmpty {
            OpenURLRouter.shared.deliver(cliURLs)
        }
        DMGGreeter.runAtLaunch()
        registerQuickLookExtension()
    }

    /// Brew's delete-and-replace upgrade can drop the Quick Look appex's
    /// pluginkit registration (previews silently fall back to raw text
    /// until something re-registers). Idempotent and cheap, so it runs on
    /// every launch; the cask's postflight covers upgrades where the app
    /// is never launched.
    private func registerQuickLookExtension() {
        let appex = Bundle.main.bundleURL
            .appendingPathComponent("Contents/PlugIns/PullMarkQuickLook.appex")
        guard FileManager.default.fileExists(atPath: appex.path) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        process.arguments = ["-a", appex.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        OpenURLRouter.shared.deliver(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
