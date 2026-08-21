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
    /// The focused window's state; commands act on it and disable when no
    /// document window is focused (e.g. Settings is key) — deliberately no
    /// static fallback: it wouldn't be observed, so menus would go stale
    /// and commands could mutate a non-frontmost window.
    @FocusedObject private var focusedState: AppState?
    private var state: AppState? { focusedState }
    @StateObject private var updates = UpdateChecker()
    @StateObject private var defaultApp = DefaultAppManager()
    /// Observed so recording a new shortcut in Settings re-keys the menus.
    @ObservedObject private var shortcuts = ShortcutStore.shared
    @AppStorage(Appearance.defaultsKey, store: UserDefaults.pullmark) private var appearanceRaw = Appearance.system.rawValue
    @AppStorage(DefaultsKeys.outlinePanel, store: UserDefaults.pullmark) private var outlineVisible = false
    @AppStorage(DefaultsKeys.diffLayout, store: UserDefaults.pullmark) private var diffLayoutRaw = PRFileView.DiffLayout.inline.rawValue
    @AppStorage(DefaultsKeys.zoom, store: UserDefaults.pullmark) private var zoom = 1.0
    @AppStorage(ContentWidth.defaultsKey, store: UserDefaults.pullmark) private var contentWidthRaw = ContentWidth.standard.rawValue
    @AppStorage(DefaultsKeys.marginNotesVisible, store: UserDefaults.pullmark) private var marginNotesVisible = true
    @AppStorage(DefaultsKeys.marginNotesEnabled, store: UserDefaults.pullmark) private var marginNotesEnabled = true
    @AppStorage(DefaultsKeys.showHiddenFiles, store: UserDefaults.pullmark) private var showHiddenFiles = false
    @AppStorage(DefaultsKeys.githubLinkStyle, store: UserDefaults.pullmark) private var githubLinkStyleRaw = "branch"

    /// True when a pull request's file (not the overview) is on screen —
    /// the view-mode commands act on it.
    private var prFileSelected: Bool {
        if case .prFile = state?.selection { return true }
        return false
    }

    /// True on the PR surfaces that carry the review control (overview or
    /// a file view) — Review Changes… acts there and disables elsewhere.
    private var prSurfaceSelected: Bool {
        switch state?.selection {
        case .prOverview, .prFile: return true
        default: return false
        }
    }

    /// View menu: the PR file's rendered/source/result switch and the
    /// inline-vs-side-by-side flip. Disabled when no PR file is showing,
    /// so the keys are discoverable without pretending to work everywhere.
    @ViewBuilder
    private var prViewCommands: some View {
        Button("Rendered Diff") { state?.send(.showRenderedDiff) }
            .keyboardShortcut(shortcuts.keyboardShortcut(for: .prRenderedDiff))
            .disabled(!prFileSelected)
        Button("Source Diff") { state?.send(.showSourceDiff) }
            .keyboardShortcut(shortcuts.keyboardShortcut(for: .prSourceDiff))
            .disabled(!prFileSelected)
        Button("Result") { state?.send(.showResult) }
            .keyboardShortcut(shortcuts.keyboardShortcut(for: .prResult))
            .disabled(!prFileSelected)
        Button(diffLayoutRaw == PRFileView.DiffLayout.inline.rawValue
               ? String(localized: "Side-by-Side Diffs") : String(localized: "Inline Diffs")) {
            state?.send(.flipDiffLayout)
        }
        .keyboardShortcut(shortcuts.keyboardShortcut(for: .prFlipLayout))
        .disabled(!prFileSelected)
        Button(state?.resolvedConversationsVisible == true
               ? String(localized: "Hide Resolved Conversations") : String(localized: "Show Resolved Conversations")) {
            state?.resolvedConversationsVisible.toggle()
        }
        .keyboardShortcut(shortcuts.keyboardShortcut(for: .showResolvedConversations))
        .disabled(!prFileSelected)
        .help("Reveal resolved review conversations in the Result view")
        Divider()
        Button("Review Changes…") { state?.send(.reviewChanges) }
            .keyboardShortcut(shortcuts.keyboardShortcut(for: .reviewChanges))
            .disabled(!prSurfaceSelected)
            .help("Open the review — pending comments, summary, and verdict")
        // Its own group: without this divider the command joins the menu's
        // trailing system group (Enter Full Screen) and inherits its indent.
        Divider()
    }

    /// The standard About panel, with credits the default item lacks:
    /// the website and the open-source acknowledgments (the vendored
    /// renderers' license notices also ship in the bundle's Resources).
    /// Copyright is passed explicitly so `swift run` (no Info.plist)
    /// shows the same line the bundle does.
    static func presentAboutPanel() {
        let credits = NSMutableAttributedString()
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        func link(_ title: String, _ url: String) -> NSAttributedString {
            NSAttributedString(string: title, attributes: [
                .link: URL(string: url)!,
                .font: NSFont.systemFont(ofSize: 11),
                .paragraphStyle: center,
            ])
        }
        func plain(_ text: String) -> NSAttributedString {
            NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: center,
            ])
        }
        credits.append(link("pullmark.app", "https://pullmark.app"))
        credits.append(plain("  ·  "))
        credits.append(link("Open Source Licenses", "https://pullmark.app/licenses/"))
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: credits,
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"):
                "© 2026 PullMark contributors · MIT License",
        ])
    }

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

    /// The selection's URL when Copy GitHub Link can act on it: local,
    /// and inside a git checkout — a pure filesystem walk, cheap at
    /// menu render (spec: copy-github-link §4).
    private var selectionGitHubLinkURL: URL? {
        guard let state, let url = state.selectionLocalURL,
              GitHubLink.inRepository(url, isDirectory: state.selectionIsDirectory)
        else { return nil }
        return url
    }

    private func copyGitHubLink(permalink: Bool) {
        guard let state, let url = selectionGitHubLinkURL else { return }
        SidebarActions.copyGitHubLink(url, isDirectory: state.selectionIsDirectory,
                                      permalink: permalink, state: state)
    }

    /// Primary follows the Settings flavor; the ⌥ alternate names the
    /// other one (spec: copy-github-link §2).
    private var githubLinkDefaultIsPermalink: Bool { githubLinkStyleRaw == "commit" }

    private var copyGitHubLinkCommand: some View {
        Button("Copy GitHub Link") {
            copyGitHubLink(permalink: githubLinkDefaultIsPermalink)
        }
        .keyboardShortcut(shortcuts.keyboardShortcut(for: .copyGitHubLink))
        .disabled(selectionGitHubLinkURL == nil)
    }

    private var copyGitHubLinkAlternate: some View {
        Button(githubLinkDefaultIsPermalink ? String(localized: "Copy GitHub Branch Link") : String(localized: "Copy GitHub Permalink")) {
            copyGitHubLink(permalink: !githubLinkDefaultIsPermalink)
        }
        .disabled(selectionGitHubLinkURL == nil)
    }

    /// Copy as Markdown (⌥⌘C): the page maps the selection to covered
    /// source lines (whole-block granularity via data-pm-lines), Swift
    /// slices the original markdown and puts plain text on the pasteboard.
    /// No selection copies the whole document source.
    private func copyAsMarkdown() {
        guard let document = state?.activeDocument else { return }
        DocumentShare.copyMarkdown(from: document)
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
        }
        // Route file-open events into the existing window instead of
        // spawning a second one.
        .handlesExternalEvents(matching: ["*"])
        // First-launch window size (returning windows restore their own).
        .defaultSize(width: 1317, height: 698)
        .commands {
            // Grouped: the commands builder tops out at ten elements, and
            // the Go menu made eleven.
            Group {
                CommandGroup(replacing: .appInfo) {
                    Button("About PullMark") { Self.presentAboutPanel() }
                }
                CommandGroup(after: .appInfo) {
                    // An alert, not the focused window's error state: the
                    // result must land even when Settings is key or no
                    // window is open at all.
                    Button("Check for Updates…") { updates.checkManuallyPresentingResult() }
                }
            }
            CommandGroup(after: .newItem) {
                Button("Open…") { state?.openFileOrFolder() }
                    .keyboardShortcut(shortcuts.keyboardShortcut(for: .openFile))
                Button("Open Pull Request…") { state?.showAddPR = true }
                    .keyboardShortcut(shortcuts.keyboardShortcut(for: .openPullRequest))
                Button("Open Quickly…") { state?.openQuicklyVisible = true }
                    .keyboardShortcut(shortcuts.keyboardShortcut(for: .openQuickly))
                    .disabled(state == nil)
                    .help("Jump to any file, heading, or pull request")
                Menu("Open Recent") {
                    ForEach(state?.recents ?? []) { item in
                        Button(item.title) { state?.openRecent(item) }
                    }
                    if state?.recents.isEmpty == false {
                        Divider()
                        // "Clear Menu" per macOS convention; the settings
                        // row and sidebar context menu say Clear Recents.
                        Button("Clear Menu") { state?.clearRecents() }
                            .keyboardShortcut(shortcuts.keyboardShortcut(for: .clearRecents))
                    }
                }
                // Keyboard/VoiceOver parity for the Open Files header's
                // hover ✕ (spec: sidebar-section-affordances §1).
                Button("Close All Files") { state?.closeAllOpenFiles() }
                    .keyboardShortcut(shortcuts.keyboardShortcut(for: .closeAllFiles))
                    .disabled(state?.hasOpenFiles != true)
                Divider()
                // Sidebar file commands (sidebar-navigator spec §4) — act
                // on the selected file, folder root, or tree node.
                Button("Reveal in Finder") {
                    if let url = state?.selectionLocalURL {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                .keyboardShortcut(shortcuts.keyboardShortcut(for: .revealInFinder))
                .disabled(state?.selectionLocalURL == nil)
                Button("Copy Path") {
                    if let url = state?.selectionLocalURL { SidebarActions.copyPath(url) }
                }
                .keyboardShortcut(shortcuts.keyboardShortcut(for: .copyPath))
                .disabled(state?.selectionLocalURL == nil)
                // Menu items keep their slot (structure stays put), so
                // outside a checkout this disables rather than hides —
                // unlike the context menus, which rebuild per open.
                if #available(macOS 15.0, *) {
                    copyGitHubLinkCommand
                        .modifierKeyAlternate(.option) { copyGitHubLinkAlternate }
                } else {
                    copyGitHubLinkCommand
                }
                Button("Refresh Folder") {
                    if let root = state?.selectionFolderRoot {
                        state?.rescanFolder(root: root)
                    }
                }
                .keyboardShortcut(shortcuts.keyboardShortcut(for: .refreshFolder))
                .disabled(state?.selectionFolderRoot == nil)
            }
            CommandGroup(replacing: .saveItem) {
                // Edit-mode commits write to disk as they land — the mode
                // boundary is the save gesture, so there is no ⌘S.
                Button("Commit Changes…") {
                    guard let url = activeLocalFileURL else { return }
                    if let root = LocalGit.repoRoot(for: url) {
                        state?.commitRequest = CommitRequest(root: root)
                    } else {
                        state?.lastNotice = String(localized: "\(url.lastPathComponent) isn't inside a git repository.")
                    }
                }
                .keyboardShortcut(shortcuts.keyboardShortcut(for: .commitChanges))
                .disabled(activeLocalFileURL == nil)
                .help("Stage and commit changes in this file's repository")
                Button("Revert Last Edit") {
                    guard let url = activeLocalFileURL else { return }
                    do {
                        try EditHistory.revertLastEdit(for: url)
                        state?.lastNotice = String(localized: "Reverted the last edit to \(url.lastPathComponent).")
                    } catch {
                        state?.lastError = String(localized: "Couldn't revert: \(error.localizedDescription)")
                    }
                }
                .keyboardShortcut(shortcuts.keyboardShortcut(for: .revertLastEdit))
                .disabled(activeLocalFileURL.map { EditHistory.lastSnapshot(for: $0) == nil } ?? true)
                .help("Restore the file as it was before PullMark's last edit")
            }
            CommandGroup(replacing: .printItem) {
                Button("Page Setup…") { NSApp.runPageLayout(nil) }
                    .keyboardShortcut(shortcuts.keyboardShortcut(for: .pageSetup))
                    .help("Paper size and orientation for printing")
                Button("Print…") { state?.activeDocument?.proxy.printDocument() }
                    .keyboardShortcut(shortcuts.keyboardShortcut(for: .printDocument))
                    .disabled(state?.activeDocument == nil)
                    .help("Print the rendered document")
            }
            CommandGroup(replacing: .importExport) {
                Button("Export as PDF…") {
                    guard let document = state?.activeDocument else { return }
                    DocumentExport.exportPDF(document) { state?.lastError = $0 }
                }
                .keyboardShortcut(shortcuts.keyboardShortcut(for: .exportPDF))
                .disabled(state?.activeDocument == nil)
                .help("Save the rendered document as a PDF")
                Button("Export as HTML…") {
                    guard let document = state?.activeDocument else { return }
                    DocumentExport.exportHTML(document) { state?.lastError = $0 }
                }
                .keyboardShortcut(shortcuts.keyboardShortcut(for: .exportHTML))
                .disabled(state?.activeDocument == nil)
                .help("Save the rendered document as a self-contained HTML file")
            }
            // The system Copy item (⌘C) stays: WKWebView's native copy puts
            // rich HTML + plain text on the pasteboard for the selection.
            CommandGroup(after: .pasteboard) {
                Button("Copy as Markdown") { copyAsMarkdown() }
                    .keyboardShortcut(shortcuts.keyboardShortcut(for: .copyAsMarkdown))
                    .disabled(state?.activeDocument == nil)
                    .help("Copies the Markdown source of the selected blocks (whole blocks — or the whole document when nothing is selected)")
            }
            CommandGroup(after: .textEditing) {
                Button("Find in Page") { state?.findBarVisible = true }
                    .keyboardShortcut(shortcuts.keyboardShortcut(for: .findInPage))
                Button("Find Next") { state?.send(.findNext) }
                    .keyboardShortcut(shortcuts.keyboardShortcut(for: .findNext))
                    .disabled(state?.findBarVisible != true)
                Button("Find Previous") { state?.send(.findPrevious) }
                    .keyboardShortcut(shortcuts.keyboardShortcut(for: .findPrevious))
                    .disabled(state?.findBarVisible != true)
                Button("Search All Files…") { state?.searchPaletteVisible = true }
                    .keyboardShortcut(shortcuts.keyboardShortcut(for: .searchAllFiles))
                Divider()
                Button("Edit Mode") { state?.send(.toggleEditMode) }
                    .keyboardShortcut(shortcuts.keyboardShortcut(for: .editMode))
                    .disabled(activeLocalFileURL == nil || state?.sourceViewVisible == true)
                    .help("Make the page writable — then click any block")
                Divider()
                Button("Add Margin Note") { state?.send(.addMarginNote) }
                    .keyboardShortcut(shortcuts.keyboardShortcut(for: .addMarginNote))
                    .disabled(!marginNotesEnabled || activeLocalFileURL == nil
                        || state?.sourceViewVisible == true)
                    .help(marginNotesEnabled
                        ? String(localized: "Leave a note on the block you're reading — it's saved into the file as a <!-- note --> comment")
                        : String(localized: "Turn on margin notes in Settings → Experimental"))
                Button("File Margin Note…") { state?.send(.addFileMarginNote) }
                    .keyboardShortcut(shortcuts.keyboardShortcut(for: .addFileMarginNote))
                    .disabled(!marginNotesEnabled || activeLocalFileURL == nil
                        || state?.sourceViewVisible == true)
                    .help(marginNotesEnabled
                        ? String(localized: "Leave a note about the whole document, at the top")
                        : String(localized: "Turn on margin notes in Settings → Experimental"))
            }
            CommandGroup(replacing: .help) {
                Button("Release Notes") {
                    guard let state else { return }
                    Task {
                        if let history = await updates.releaseNotesHistory() {
                            updates.historyMarkdown = history
                            updates.showHistory = true
                        } else {
                            state.lastNotice = String(localized: "Release notes couldn't be loaded — they're also at github.com/jedijashwa/pullmark/releases.")
                        }
                    }
                }
                .disabled(state == nil)
                .help("Every release's notes, up to the version you're running")
                Divider()
                Button("PullMark Website") {
                    open("https://pullmark.app")
                }
                Divider()
                Button("Report a Bug…") {
                    // The form's version and macOS fields arrive filled in —
                    // the app knows both better than the reporter does.
                    let version = Bundle.main.object(
                        forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
                    let macOS = BugReport.macOSVersionString(
                        ProcessInfo.processInfo.operatingSystemVersion)
                    if let url = BugReport.url(version: version, macOSVersion: macOS) {
                        NSWorkspace.shared.open(url)
                    }
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
                // In the View menu as well as Settings: the urge to go
                // wider strikes mid-read (entering full screen), not while
                // browsing preferences.
                Picker("Content Width", selection: $contentWidthRaw) {
                    ForEach(ContentWidth.allCases) { width in
                        Text(width.label).tag(width.rawValue)
                    }
                }
                Divider()
                Button(state?.sourceViewVisible == true ? String(localized: "Hide Markdown Source") : String(localized: "Show Markdown Source")) {
                    state?.sourceViewVisible.toggle()
                }
                .keyboardShortcut(shortcuts.keyboardShortcut(for: .toggleSource))
                .disabled(state?.activeDocument == nil)
                .help("Temporarily show the raw Markdown behind the rendered document")
                Button(outlineVisible ? String(localized: "Hide Outline") : String(localized: "Show Outline")) {
                    outlineVisible.toggle()
                }
                .keyboardShortcut(shortcuts.keyboardShortcut(for: .toggleOutline))
                .help("The document's headings, in a sidebar")
                Button("Reload Document") { state?.send(.reload) }
                    .keyboardShortcut(shortcuts.keyboardShortcut(for: .reloadDocument))
                    .disabled(activeLocalFileURL == nil)
                    .help("Re-read this file from disk")
                Button(state?.expectedSurfaceToolbar?.comparing == true
                       ? String(localized: "Stop Comparing")
                       : String(localized: "Compare with Last Commit")) {
                    state?.send(.toggleCompare)
                }
                .disabled(activeLocalFileURL == nil
                    || state?.expectedSurfaceToolbar?.compareGitAvailable != true)
                .help("What changed since the last commit, rendered like a PR diff — the toolbar's Compare button offers older revisions and branches")
                Button(marginNotesVisible ? String(localized: "Hide Margin Notes") : String(localized: "Show Margin Notes")) {
                    marginNotesVisible.toggle()
                }
                .keyboardShortcut(shortcuts.keyboardShortcut(for: .toggleMarginNotes))
                .help("Margin-note bubbles (<!-- note --> comments) in rendered documents")
                Button(showHiddenFiles ? String(localized: "Hide Hidden Files") : String(localized: "Show Hidden Files")) {
                    showHiddenFiles.toggle()
                }
                .keyboardShortcut(shortcuts.keyboardShortcut(for: .toggleHiddenFiles))
                .help("Dotfiles and hidden folders in Locations — like ⇧⌘. in Finder")
                Divider()
                // Zoom sits below the show/hide cluster with Actual Size
                // first — the Safari/Preview View-menu convention.
                Button("Actual Size") { zoom = 1.0 }
                    .keyboardShortcut(shortcuts.keyboardShortcut(for: .actualSize))
                    .disabled(state == nil || DocumentZoom.isActualSize(zoom))
                    .help("Reset the zoom to 100%")
                Button("Zoom In") { zoom = DocumentZoom.zoomIn(from: zoom) }
                    .keyboardShortcut(shortcuts.keyboardShortcut(for: .zoomIn))
                    .disabled(state == nil || zoom >= DocumentZoom.maximum)
                    .help("Make the document bigger — text, images, and the content column scale together")
                Button("Zoom Out") { zoom = DocumentZoom.zoomOut(from: zoom) }
                    .keyboardShortcut(shortcuts.keyboardShortcut(for: .zoomOut))
                    .disabled(state == nil || zoom <= DocumentZoom.minimum)
                    .help("Make the document smaller")
                Divider()
                // The same palette as right-clicking the toolbar — in the
                // menu too, as Mail and Finder have it, so the feature
                // doesn't hide behind a gesture.
                Button("Customize Toolbar…") {
                    NSApp.sendAction(#selector(NSWindow.runToolbarCustomizationPalette(_:)),
                                     to: nil, from: nil)
                }
                .disabled(state == nil)
                .help("Choose which items the toolbar shows, and their order")
                Divider()
                prViewCommands
            }
            // Between View and Window, where Finder and Xcode keep
            // navigation (spec: back-forward-navigation §6). Disabled
            // sides mirror the toolbar buttons.
            CommandMenu("Go") {
                Button("Back") { state?.goBack() }
                    .keyboardShortcut(shortcuts.keyboardShortcut(for: .goBack))
                    .disabled(state?.canGoBack != true)
                    .help("Show the previous document")
                Button("Forward") { state?.goForward() }
                    .keyboardShortcut(shortcuts.keyboardShortcut(for: .goForward))
                    .disabled(state?.canGoForward != true)
                    .help("Show the next document")
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
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Before any window (and so any toolbar) exists: scrub saved
        // toolbar arrangements that a sidebar-section drop corrupted, so
        // SwiftUI only ever restores a clean one. See ToolbarArrangement.
        ToolbarArrangement.repairSavedConfigurations(in: .standard)
        // Before any view reads the margin-notes flags: alpha-era users
        // who made an explicit enabled choice skip the first-use intro.
        MarginNotesIntro.migrateAtLaunch()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched via `swift run` (no bundle): become a regular,
        // focusable app with a menu bar.
        NSApp.setActivationPolicy(.regular)
        // Capture instances draw active chrome without focus and must
        // NOT activate — the whole point is not stealing the user's
        // input while the generator drives many instances at once.
        CaptureChrome.installIfRequested()
        if !CaptureChrome.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
        Appearance.applyCurrent()
        // Pin the launch language before any UI (or the user) can
        // change the stored value — the Settings row compares against it.
        _ = AppLanguage.atLaunch
        let cliURLs = LaunchArguments.consumeFileURLs()
        if !cliURLs.isEmpty {
            OpenURLRouter.shared.deliver(cliURLs)
        }
        DMGGreeter.runAtLaunch()
        registerQuickLookExtension()
        restoreFullScreenIfNeeded()
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
        // pullmark:// deep links route through AppLinkRouter (shared
        // with the scene's onOpenURL — whichever path macOS picks);
        // everything else is a document open.
        var documents: [URL] = []
        for url in urls {
            if url.scheme == "pullmark" {
                AppLinkRouter.handle(url)
            } else {
                documents.append(url)
            }
        }
        if !documents.isEmpty {
            OpenURLRouter.shared.deliver(documents)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // The session snapshot is written once, at quit, from the last key
        // window — mid-session didSet snapshots proved racy (a restore's
        // own adds overwrote the snapshot it was restoring from).
        AppState.keyInstance?.snapshotSession()
        // SwiftUI restores window frames but not full-screen state, so
        // remember it ourselves (⌘Q from full screen still has the window
        // alive here; closing the window first leaves full screen anyway).
        UserDefaults.pullmark.set(
            NSApp.windows.contains { $0.styleMask.contains(.fullScreen) },
            forKey: DefaultsKeys.windowWasFullScreen)
    }

    /// Re-enters full screen at launch when the app was quit that way.
    /// Polls briefly: SwiftUI creates the window a beat after
    /// applicationDidFinishLaunching.
    func restoreFullScreenIfNeeded(attempt: Int = 0) {
        guard UserDefaults.pullmark.bool(forKey: DefaultsKeys.windowWasFullScreen) else { return }
        if let window = NSApp.windows.first(where: {
            $0.frame.height > 200 && !$0.styleMask.contains(.fullScreen)
        }) {
            window.toggleFullScreen(nil)
        } else if attempt < 15, !NSApp.windows.contains(where: { $0.styleMask.contains(.fullScreen) }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.restoreFullScreenIfNeeded(attempt: attempt + 1)
            }
        }
    }
}
