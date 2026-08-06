import QuickLook
import SwiftUI

struct ContentView: View {
    /// Each window owns its state — sidebar, sessions, selection, edits —
    /// which is what makes ⌘N windows and native tabs independent.
    @StateObject private var state = AppState()
    @EnvironmentObject private var updates: UpdateChecker
    /// Observed so the toolbar's shortcut hints follow a rebind.
    @ObservedObject private var shortcuts = ShortcutStore.shared
    @AppStorage(Appearance.defaultsKey, store: UserDefaults.pullmark) private var appearanceRaw = Appearance.system.rawValue
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        NavigationSplitView {
            // The column's limits deliberately don't follow the zoom:
            // scaled minimums would eat the document at high zoom, and
            // AppKit's autosaved width would ratchet and never come back.
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 278)
        } detail: {
            VStack(spacing: 0) {
                AppUpdateBanner()
                DefaultAppBanner()
                DetailView()
                    .overlay(alignment: .top) { ZoomHUD().padding(.top, 10) }
            }

        }
        // Physical "⌘+" (⇧⌘=) zooms in like the menu's ⌘= — see the catcher.
        .background(ZoomKeyCatcher())
        // Titlebar proxy icon + ⌘-click path menu for the open local file.
        // macOS 14 gets the real API (navigationDocument); 13 the fallback.
        .modifier(DocumentProxyModifier(url: selectedLocalURL))
        .frame(minWidth: 940, minHeight: 620)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    state.openFileOrFolder()
                } label: {
                    Label("Open File or Folder", systemImage: "folder")
                }
                .help("Open local Markdown files or a folder"
                    + shortcuts.hint(.openFile))

                Button {
                    state.showAddPR = true
                } label: {
                    Label("Open Pull Request", systemImage: "arrow.triangle.pull")
                }
                .help("Open a GitHub pull request"
                    + shortcuts.hint(.openPullRequest))

                Menu {
                    Picker("Appearance", selection: $appearanceRaw) {
                        ForEach(Appearance.allCases) { appearance in
                            Text(appearance.label).tag(appearance.rawValue)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Appearance", systemImage: "circle.lefthalf.filled")
                }
                .help("Switch between light, dark, and system appearance")

                // The morphing review control — window-level, trailing-most,
                // on every PR surface (spec §3). Hosted here rather than in
                // the surfaces' own toolbars because SwiftUI overflows
                // detail-level toolbar items before window-level ones at
                // every width: review status must survive the squeeze that
                // rightly claims the layout picker and comment shortcut
                // first (see ReviewToolbarButton). The click rides the same
                // command path as the View menu and ⇧⌘R; the active surface
                // presents the popover.
                if let sessionID = reviewSessionID {
                    ReviewToolbarButton(sessionID: sessionID,
                                        tracker: state.reviewAnchor) {
                        state.send(.reviewChanges)
                    }
                }
            }
        }
        .sheet(isPresented: $state.showAddPR) {
            AddPRSheet()
        }
        .sheet(isPresented: $state.searchPaletteVisible) {
            SearchPalette()
        }
        .sheet(item: $state.commitRequest) { request in
            CommitSheet(root: request.root)
        }
        .sheet(isPresented: $state.openQuicklyVisible) {
            OpenQuicklyPalette()
        }
        .sheet(isPresented: $updates.showReleaseNotes) {
            ReleaseNotesSheet(
                title: "What's New in PullMark \(updates.availableVersion ?? "")",
                markdown: updates.availableNotes
            )
        }
        .sheet(isPresented: $updates.showWhatsNew) {
            ReleaseNotesSheet(title: "What's New in PullMark",
                              markdown: updates.whatsNewMarkdown)
        }
        .alert("Something went wrong", isPresented: errorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(state.lastError ?? "")
        }
        .alert(state.lastNotice ?? "", isPresented: noticePresented) {
            Button("OK", role: .cancel) {}
        }
        // A clicked dead recent: quiet notice with a removal action —
        // never the old error-and-purge (spec §6).
        .alert("\(state.deadRecent?.title ?? "") isn't available",
               isPresented: deadRecentPresented) {
            Button("Remove from Recents") {
                if let item = state.deadRecent { state.removeRecent(id: item.id) }
            }
            Button("Keep", role: .cancel) {}
        } message: {
            Text("Last seen at \(state.deadRecent?.path.map { PathAbbreviator.abbreviate($0) } ?? ""). "
                + "It will revive here if the file comes back.")
        }
        // A GitHub Markdown link clicked while the policy is "ask": the
        // choice sheet (a sheet, not an alert — it carries the Remember
        // checkbox, which alerts cannot host).
        .sheet(item: $state.remoteLinkPrompt) { prompt in
            RemoteLinkPromptSheet(prompt: prompt)
        }
        .environmentObject(state)
        // Drop .md files or folders anywhere on the window.
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            var accepted = false
            for provider in providers where provider.canLoadObject(ofClass: URL.self) {
                accepted = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in state.add(url: url) }
                }
            }
            return accepted
        }
        // Menu commands act on the focused window's state.
        .focusedSceneObject(state)
        // External opens land in the key window.
        .onChange(of: controlActiveState) { active in
            if active == .key { AppState.keyInstance = state }
        }
        // Closing the last window IS the app's default quit path, and the
        // weak keyInstance nils before applicationWillTerminate can use it
        // — snapshot here while this window's state is still alive.
        .onDisappear {
            if AppState.keyInstance === state { state.snapshotSession() }
        }
        .onOpenURL { url in
            if AppState.gateOpen(url) { state.add(url: url) }
        }
    }

    private var selectedLocalURL: URL? {
        if case .local(let url) = state.selection { return url }
        return nil
    }

    /// The PR session whose review the toolbar control shows — the
    /// surfaces that carry the review workflow (overview and file view),
    /// matching where Review Changes… is enabled.
    private var reviewSessionID: String? {
        switch state.selection {
        case .prOverview(let id): return id
        case .prFile(let id, _): return id
        default: return nil
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { state.lastError != nil },
            set: { if !$0 { state.lastError = nil } }
        )
    }

    private var noticePresented: Binding<Bool> {
        Binding(
            get: { state.lastNotice != nil },
            set: { if !$0 { state.lastNotice = nil } }
        )
    }

    private var deadRecentPresented: Binding<Bool> {
        Binding(
            get: { state.deadRecent != nil },
            set: { if !$0 { state.deadRecent = nil } }
        )
    }
}

struct SidebarView: View {
    @EnvironmentObject private var state: AppState

    @AppStorage(DefaultsKeys.zoom, store: UserDefaults.pullmark) private var zoom = 1.0
    @AppStorage(DefaultsKeys.inboxEnabled, store: UserDefaults.pullmark) private var inboxEnabled = true
    @AppStorage(DefaultsKeys.inboxMarkdownOnly, store: UserDefaults.pullmark) private var inboxMarkdownOnly = true
    // Per-window like the rest of the sidebar (@AppStorage would live-sync
    // a collapse in one window into every other window).
    @SceneStorage(DefaultsKeys.sidebarLocalExpanded) private var filesExpanded = true
    @SceneStorage(DefaultsKeys.sidebarFoldersExpanded) private var foldersExpanded = true
    @SceneStorage(DefaultsKeys.sidebarPRsExpanded) private var prsExpanded = true
    @SceneStorage(DefaultsKeys.sidebarInboxExpanded) private var inboxExpanded = true
    @SceneStorage(DefaultsKeys.sidebarRecentExpanded) private var recentExpanded = true
    /// Space → Quick Look on the selected local row (spec §8.2).
    @State private var quickLookURL: URL?

    // What you opened yourself outranks what was assigned to you: the
    // review-request subgroup sits below the opened pull requests.
    private var fonts: ChromeFonts { ChromeFonts(zoom: zoom) }

    var body: some View {
        List(selection: $state.selection) {
            // The working set: explicitly opened documents, flat and
            // ordered, plus the single italic preview entry last. Trees
            // answer "where does it live"; this section answers "what do
            // I have open" (Sublime's exact label for the same list).
            CollapsibleSection("Open Files", isExpanded: $filesExpanded, headerMenu: {
                AnyView(Button("Close All") { state.closeAllOpenFiles() }
                    .disabled(state.localFiles.isEmpty && state.previewFile == nil))
            }) {
                if state.localFiles.isEmpty, state.preview == nil {
                    Button("Open File…") { state.openFilesPanel() }
                        .font(fonts.callout)
                }
                ForEach(state.localFiles) { file in
                    SidebarFileRow(file: file,
                                   showsPath: duplicateFileNames.contains(file.url.lastPathComponent))
                        .tag(SidebarSelection.local(file.url))
                }
                .onMove { from, to in state.localFiles.move(fromOffsets: from, toOffset: to) }
                // The preview holds a stable slot at the end so promotion
                // never reorders the pinned rows above it. ONE home for it
                // regardless of origin — "what am I reading" shouldn't
                // depend on where the file lives; keeping a remote doc is
                // what files it with its repo.
                switch state.preview {
                case .local(let preview):
                    SidebarFileRow(file: preview,
                                   showsPath: duplicateFileNames.contains(preview.url.lastPathComponent),
                                   isPreview: true)
                        .tag(SidebarSelection.local(preview.url))
                case .remote(let sessionID, let path):
                    RemotePreviewRow(sessionID: sessionID, path: path)
                        .tag(SidebarSelection.remoteDoc(sessionID, path))
                case nil:
                    EmptyView()
                }
            }
            // Locations: browsable roots wherever they live — local folders
            // and GitHub repos share one section (Finder's word for exactly
            // this list); the icon and subtitle carry the origin.
            CollapsibleSection("Locations", isExpanded: $foldersExpanded) {
                if state.folders.isEmpty, state.remoteSessions.isEmpty {
                    Button("Open Folder…") { state.openFolderPanel() }
                        .font(fonts.callout)
                }
                ForEach(state.folders) { folder in
                    FolderRootGroup(folder: folder)
                }
                .onMove { from, to in state.folders.move(fromOffsets: from, toOffset: to) }
                ForEach(state.remoteSessions) { session in
                    RemoteRepoGroup(session: session)
                }
                .onMove { from, to in state.remoteSessions.move(fromOffsets: from, toOffset: to) }
            }
            CollapsibleSection("Pull Requests", isExpanded: $prsExpanded) {
                if state.prSessions.isEmpty {
                    Button("Open Pull Request…") { state.showAddPR = true }
                        .font(fonts.callout)
                }
                ForEach(state.prSessions) { session in
                    PRSidebarGroup(session: session)
                }
                .onMove { from, to in state.prSessions.move(fromOffsets: from, toOffset: to) }
                // The inbox is a facet of pull requests, not its own
                // category — a subgroup whose unread count keeps demotion
                // honest even collapsed.
                if inboxEnabled, !visibleInbox.isEmpty {
                    DisclosureGroup(isExpanded: $inboxExpanded) {
                        ForEach(visibleInbox) { item in
                            InboxRow(item: item)
                                .tag(SidebarSelection.inboxItem(item.id))
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Label {
                                Text("Review Requests")
                                    .font(fonts.row)
                            } icon: {
                                Image(systemName: "tray")
                                    .foregroundStyle(.secondary)
                            }
                            let unread = visibleInbox.filter(state.inboxIsUnread).count
                            if unread > 0 {
                                Spacer(minLength: 2)
                                Text("\(unread)")
                                    .font(fonts.caption)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .accessibilityLabel("\(unread) unread")
                            }
                        }
                    }
                }
            }
            if !recentItems.isEmpty {
                CollapsibleSection("Recents", isExpanded: $recentExpanded) {
                    ForEach(recentItems) { item in
                        RecentRow(item: item,
                                  missing: state.missingRecentIDs.contains(item.id),
                                  showsPath: duplicateRecentNames.contains(item.title))
                            .tag(SidebarSelection.recentItem(item.id))
                    }
                }
                .contextMenu {
                    Button("Clear Recents") { state.clearRecents() }
                }
            }
        }
        .listStyle(.sidebar)
        // ⌫ removes the selected removable item (spec §4).
        .onDeleteCommand { state.removeSelectedSidebarItem() }
        .modifier(SpaceQuickLook(url: $quickLookURL, selected: selectedLocalURL))
        .onAppear { state.validateSidebarPaths() }
    }

    private var selectedLocalURL: URL? {
        if case .local(let url) = state.selection { return url }
        return nil
    }

    /// With Markdown-only on (default), review requests PullMark can't
    /// render stay hidden; a PR whose file count is still loading shows
    /// until the count proves it Markdown-free.
    private var visibleInbox: [GitHubClient.InboxPR] {
        guard inboxMarkdownOnly else { return state.inbox }
        return state.inbox.filter { (state.inboxMDCount($0) ?? 1) > 0 }
    }

    /// Recents not already visible in the sidebar — a file under an open
    /// folder root counts as visible (it's in that root's tree).
    private var recentItems: [RecentItem] {
        state.recents.filter { item in
            switch item.kind {
            case .file:
                guard let path = item.path else { return true }
                if state.localFiles.contains(where: { $0.url.path == path }) { return false }
                return !state.folders.contains { path.hasPrefix($0.rootURL.path + "/") }
            case .folder:
                return !state.folders.contains { $0.rootURL.path == item.path }
            case .pr:
                guard let ref = item.ref else { return false }
                return !state.prSessions.contains { $0.ref == ref }
            }
        }
    }

    /// Display names shared by two or more visible rows grow a dimmed
    /// parent-path second line (spec §5, VS Code's rule).
    private var duplicateFileNames: Set<String> {
        duplicates((state.localFiles + (state.previewFile.map { [$0] } ?? []))
            .map { $0.url.lastPathComponent })
    }

    private var duplicateRecentNames: Set<String> {
        duplicates(recentItems.filter { $0.kind != .pr }.map(\.title))
    }

    private func duplicates(_ names: [String]) -> Set<String> {
        var seen: Set<String> = []
        var dupes: Set<String> = []
        for name in names {
            if !seen.insert(name).inserted { dupes.insert(name) }
        }
        return dupes
    }
}

/// Space previews the selected local file through Quick Look — the app
/// ships a QL extension, so the sidebar previews PullMark's own render.
/// Key handling needs macOS 14; earlier systems simply don't get Space.
private struct SpaceQuickLook: ViewModifier {
    @Binding var url: URL?
    let selected: URL?

    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content
                .quickLookPreview($url)
                .onKeyPress(.space) {
                    guard let selected else { return .ignored }
                    url = selected
                    return .handled
                }
        } else {
            content
        }
    }
}

/// The shared hover-revealed ✕ for removable top-level rows (spec §4):
/// same non-destructive removal as the context menu, never on tree
/// children. Sized against the chrome font so it survives zoom.
private struct HoverRemoveButton: View {
    let help: String
    let action: () -> Void
    @AppStorage(DefaultsKeys.zoom, store: UserDefaults.pullmark) private var zoom = 1.0

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .font(ChromeFonts(zoom: zoom).caption)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Wraps row content with a trailing hover-✕. The hover state lives per
/// row; the button only exists while hovered so it can't eat clicks.
private struct RemovableRow<Content: View>: View {
    let help: String
    let remove: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 4) {
            content()
            Spacer(minLength: 2)
            if hovered {
                HoverRemoveButton(help: help, action: remove)
            }
        }
        .onHover { hovered = $0 }
    }
}

/// An explicitly opened document in Open Files — or, italicized, the one
/// transient preview entry (`isPreview`). Double-clicking the preview
/// keeps it open; the next tree click replaces it.
private struct SidebarFileRow: View {
    @EnvironmentObject private var state: AppState
    @AppStorage(DefaultsKeys.zoom, store: UserDefaults.pullmark) private var zoom = 1.0
    let file: LocalFile
    let showsPath: Bool
    var isPreview = false

    var body: some View {
        let fonts = ChromeFonts(zoom: zoom)
        RemovableRow(help: isPreview ? "Dismiss Preview" : "Remove from Sidebar",
                     remove: { isPreview ? state.dismissPreview()
                                         : state.removeLocalFile(file) }) {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(file.url.lastPathComponent)
                        .italic(isPreview)
                        .lineLimit(1)
                        .font(fonts.row)
                    if showsPath {
                        Text(PathAbbreviator.abbreviate(file.url.deletingLastPathComponent().path))
                            .lineLimit(1)
                            .truncationMode(.head)
                            .font(fonts.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } icon: {
                // Rasterized: the List drag preview repaints template
                // symbols white (mismatching the black text); a flattened
                // icon keeps its tint in the ghost.
                Image(systemName: "doc.text")
                    .foregroundStyle(.secondary)
                    .drawingGroup()
            }
        }
        .overlay(isPreview ? DoubleClickCatcher { state.pinFile(at: file.url) } : nil)
        .help(PathAbbreviator.abbreviate(file.url.path)
            + (isPreview ? " — previewing; double-click to keep open" : ""))
        .contextMenu {
            if isPreview {
                Button("Keep Open") { state.pinFile(at: file.url) }
                Button("Dismiss Preview") { state.dismissPreview() }
            } else {
                Button("Remove from Sidebar") { state.removeLocalFile(file) }
            }
            if state.folderRootContaining(file.url) != nil {
                Button("Reveal in Location") { state.revealInLocation(file.url) }
            }
            Divider()
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
            Button("Copy Path") { SidebarActions.copyPath(file.url) }
        }
    }
}

/// The Open Files preview slot when the previewed document is remote:
/// same italics and gestures as a local preview, with an
/// `owner/repo @ ref` second line since the file isn't on this Mac.
/// Keeping it (double-click / Keep Open) pins it under its repo.
private struct RemotePreviewRow: View {
    @EnvironmentObject private var state: AppState
    @AppStorage(DefaultsKeys.zoom, store: UserDefaults.pullmark) private var zoom = 1.0
    let sessionID: String
    let path: String

    var body: some View {
        let fonts = ChromeFonts(zoom: zoom)
        RemovableRow(help: "Dismiss Preview",
                     remove: { state.dismissPreview() }) {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text((path as NSString).lastPathComponent)
                        .italic()
                        .lineLimit(1)
                        .font(fonts.row)
                    if let session = state.remoteSession(sessionID) {
                        Text("\(session.ref.owner)/\(session.ref.repo) @ \(session.displayRef)")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .font(fonts.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: "book.closed")
                    .foregroundStyle(.secondary)
                    .drawingGroup()
            }
        }
        .overlay(DoubleClickCatcher {
            state.pinRemoteDoc(sessionID: sessionID, path: path)
        })
        .help("\(path) — previewing; double-click to keep it with its repo")
        .contextMenu {
            Button("Keep Open") { state.pinRemoteDoc(sessionID: sessionID, path: path) }
            Button("Dismiss Preview") { state.dismissPreview() }
        }
    }
}

/// Shared clipboard/Finder actions for sidebar rows.
enum SidebarActions {
    static func copyPath(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }
}

/// A folder root: closeable place with its tree (or flat list) below.
private struct FolderRootGroup: View {
    @EnvironmentObject private var state: AppState
    @AppStorage(DefaultsKeys.zoom, store: UserDefaults.pullmark) private var zoom = 1.0
    let folder: LocalFolder
    @State private var ghBranches: [String] = []
    @State private var menuAnchor = MenuAnchorBox()
    @State private var menuPresenter = MenuActionPresenter()

    private var fonts: ChromeFonts { ChromeFonts(zoom: zoom) }

    /// The local flavor of the branch menu: worktrees open as sibling
    /// Locations (disk truth is discovered, never mutated — PullMark does
    /// no checkouts), and for GitHub-backed folders other branches open as
    /// pinned remote sessions — except branches a worktree already has
    /// checked out, which jump to that folder instead (local beats remote
    /// whenever disk truth exists).
    private func popBranchMenu() {
        guard let git = folder.git else { return }
        if git.primaryGitHubRepo != nil, ghBranches.isEmpty {
            let ref = PullRequestRef(owner: git.gitHubRepos[0].owner,
                                     repo: git.gitHubRepos[0].repo, number: 0)
            Task {
                do {
                    ghBranches = try await state.client.branchNames(ref)
                } catch {
                    // Offline or unauthorized: the worktree half still works.
                }
                presentMenu()
            }
        } else {
            presentMenu()
        }
    }

    private func presentMenu() {
        guard let git = folder.git else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        var actions: [() -> Void] = []
        func item(_ title: String, checked: Bool = false, in target: NSMenu,
                  run: @escaping () -> Void) {
            let item = NSMenuItem(title: title,
                                  action: #selector(MenuActionPresenter.fire(_:)),
                                  keyEquivalent: "")
            item.target = menuPresenter
            item.tag = actions.count
            item.state = checked ? .on : .off
            actions.append(run)
            target.addItem(item)
        }
        func header(_ title: String) {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            if #available(macOS 14.0, *) {
                menu.addItem(NSMenuItem.sectionHeader(title: title))
            } else {
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
        }

        header("Worktrees")
        for worktree in git.worktrees {
            let path = worktree.path
            let isHere = path == git.toplevel
            item((worktree.branch ?? "detached") + " — " + PathAbbreviator.abbreviate(path),
                 checked: isHere, in: menu) {
                if !isHere { state.add(url: URL(fileURLWithPath: path)) }
            }
        }
        if let repoID = git.primaryGitHubRepo, !ghBranches.isEmpty {
            header("View Branch from GitHub")
            for branch in ghBranches.prefix(100) where branch != git.branch {
                if let worktree = git.worktrees.first(where: { $0.branch == branch }) {
                    let path = worktree.path
                    item("\(branch) — worktree", in: menu) {
                        state.add(url: URL(fileURLWithPath: path))
                    }
                } else {
                    item(branch, in: menu) {
                        Task {
                            await state.openRemoteRepo(owner: repoID.owner, repo: repoID.repo,
                                                       refName: branch, loadTree: false)
                        }
                    }
                }
            }
        }
        if let repoID = git.primaryGitHubRepo {
            menu.addItem(.separator())
            let branch = git.branch
            item("Open on GitHub", in: menu) {
                let ref = branch.map { "/tree/\($0)" } ?? ""
                if let url = URL(string: "https://github.com/\(repoID.owner)/\(repoID.repo)\(ref)") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        menuPresenter.actions = actions
        RemoteBranchMenu.pop(menu, from: menuAnchor.view)
    }

    var body: some View {
        DisclosureGroup(isExpanded: Binding(
            get: { folder.expandedPaths.contains("") },
            set: { state.setFolderExpanded(folder.rootURL, path: "", $0) }
        )) {
            if folder.viewMode == .tree {
                ForEach(folder.nodes) { node in
                    FolderNodeView(folder: folder, node: node, depth: 1)
                }
            } else {
                ForEach(folder.filePaths, id: \.self) { path in
                    Label {
                        Text(path)
                            .lineLimit(1)
                            .truncationMode(.head)
                    } icon: {
                        Image(systemName: "doc.text")
                            .foregroundStyle(.secondary)
                    }
                    .font(fonts.row)
                    .tag(SidebarSelection.local(folder.fileURL(for: path)))
                    .overlay(DoubleClickCatcher {
                        state.pinFile(at: folder.fileURL(for: path))
                    })
                    .contextMenu { fileMenu(folder.fileURL(for: path)) }
                }
            }
            if folder.truncated {
                Text("Showing the first \(folder.filePaths.count) files")
                    .font(fonts.caption)
                    .foregroundStyle(.secondary)
            }
        } label: {
            rootRow
        }
    }

    private var rootRow: some View {
        RemovableRow(help: "Remove from Sidebar",
                     remove: { state.removeFolder(folder.rootURL) }) {
            Label {
                Text(folder.displayName)
                    .lineLimit(1)
                    .font(fonts.row)
            } icon: {
                Image(systemName: folder.missing ? "folder.badge.questionmark" : "folder")
                    .foregroundStyle(.secondary)
                    .drawingGroup() // keeps its tint in the drag preview
            }
            .foregroundStyle(folder.missing ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            if let git = folder.git, let branch = git.branch {
                BranchChip(text: branch, font: fonts.caption,
                           anchor: menuAnchor) {
                    popBranchMenu()
                }
            }
            if let repoID = folder.git?.primaryGitHubRepo {
                // The quiet fourth-state marker: this folder is a checkout
                // of a GitHub repo (local-only git shows just the chip).
                Image(systemName: "book.closed")
                    .font(fonts.caption)
                    .foregroundStyle(.tertiary)
                    .help("Checkout of \(repoID.owner)/\(repoID.repo)")
            }
            if folder.scanning {
                ProgressView().controlSize(.mini)
            }
        }
        .tag(SidebarSelection.folder(folder.rootURL))
        .help(folder.missing
            ? "Folder not found — last seen at "
                + PathAbbreviator.abbreviate(folder.rootURL.path)
            : PathAbbreviator.abbreviate(folder.rootURL.path))
        .contextMenu {
            Button("Remove from Sidebar") { state.removeFolder(folder.rootURL) }
            Divider()
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([folder.rootURL])
            }
            Button("Copy Path") { SidebarActions.copyPath(folder.rootURL) }
            Button("Refresh Folder") { state.rescanFolder(root: folder.rootURL) }
            // Right-click parity with the branch chip (SwiftUI context
            // menus rebuild per open, so live content is safe here).
            if let git = folder.git {
                Divider()
                if git.worktrees.count > 1 {
                    Menu("Open Worktree") {
                        ForEach(git.worktrees, id: \.path) { worktree in
                            Button((worktree.branch ?? "detached") + " — "
                                + PathAbbreviator.abbreviate(worktree.path)) {
                                state.add(url: URL(fileURLWithPath: worktree.path))
                            }
                            .disabled(worktree.path == git.toplevel)
                        }
                    }
                }
                if let repoID = git.primaryGitHubRepo {
                    Button("Open on GitHub") {
                        let ref = git.branch.map { "/tree/\($0)" } ?? ""
                        if let url = URL(string: "https://github.com/\(repoID.owner)/\(repoID.repo)\(ref)") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
            Divider()
            Picker("View", selection: Binding(
                get: { folder.viewMode },
                set: { state.setFolderViewMode(folder.rootURL, $0) }
            )) {
                Text("View as Tree").tag(LocalFolder.ViewMode.tree)
                Text("View as List").tag(LocalFolder.ViewMode.list)
            }
            .pickerStyle(.inline)
        }
    }

    @ViewBuilder
    private func fileMenu(_ url: URL) -> some View {
        Button("Keep Open") { state.pinFile(at: url) }
        Divider()
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        Button("Copy Path") { SidebarActions.copyPath(url) }
    }
}

/// One node of a folder tree. Expansion binds into the folder model so
/// it persists per root in the session snapshot; ⌥-clicking a directory
/// expands its whole subtree.
private struct FolderNodeView: View {
    @EnvironmentObject private var state: AppState
    @AppStorage(DefaultsKeys.zoom, store: UserDefaults.pullmark) private var zoom = 1.0
    let folder: LocalFolder
    let node: PathTree.Node
    let depth: Int

    private var fonts: ChromeFonts { ChromeFonts(zoom: zoom) }

    var body: some View {
        if node.isDirectory {
            DisclosureGroup(isExpanded: Binding(
                get: { folder.expandedPaths.contains(node.path) },
                set: { state.setFolderExpanded(folder.rootURL, path: node.path, $0) }
            )) {
                ForEach(node.children) { child in
                    FolderNodeView(folder: folder, node: child, depth: depth + 1)
                }
            } label: {
                Label {
                    Text(node.name)
                } icon: {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                }
                    .font(fonts.row)
                    .tag(SidebarSelection.folderNode(folder.rootURL, node.path))
                    .simultaneousGesture(
                        TapGesture().modifiers(.option).onEnded {
                            expandSubtree(node)
                        }
                    )
                    .contextMenu {
                        Button("Expand All") { expandSubtree(node) }
                        Divider()
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting(
                                [folder.fileURL(for: node.path)])
                        }
                        Button("Copy Path") {
                            SidebarActions.copyPath(folder.fileURL(for: node.path))
                        }
                    }
            }
        } else {
            Label {
                Text(node.name)
            } icon: {
                Image(systemName: "doc.text")
                    .foregroundStyle(.secondary)
            }
                .font(fonts.row)
                .tag(SidebarSelection.local(folder.fileURL(for: node.path)))
                // Single click selects (and previews) through the List as
                // usual; a double click keeps the file open.
                .overlay(DoubleClickCatcher {
                    state.pinFile(at: folder.fileURL(for: node.path))
                })
                .help(PathAbbreviator.abbreviate(folder.fileURL(for: node.path).path))
                .contextMenu {
                    Button("Keep Open") {
                        state.pinFile(at: folder.fileURL(for: node.path))
                    }
                    Divider()
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [folder.fileURL(for: node.path)])
                    }
                    Button("Copy Path") {
                        SidebarActions.copyPath(folder.fileURL(for: node.path))
                    }
                }
        }
    }

    private func expandSubtree(_ node: PathTree.Node) {
        state.setFolderExpanded(folder.rootURL, path: node.path, true)
        for child in node.children where child.isDirectory {
            expandSubtree(child)
        }
    }
}

/// A sidebar section the user can fold away. Native collapsing (chevron in
/// the header) needs macOS 14's `Section(isExpanded:)`; on macOS 13 the
/// section renders permanently expanded. A non-zero `badge` renders a
/// count at the header's trailing edge (visible even while collapsed).
private struct CollapsibleSection<Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    var badge = 0
    /// Optional right-click actions on the section header itself (e.g.
    /// Close All on Open Files).
    var headerMenu: (() -> AnyView)?
    @ViewBuilder let content: () -> Content
    @AppStorage(DefaultsKeys.zoom, store: UserDefaults.pullmark) private var zoom = 1.0

    init(_ title: String, isExpanded: Binding<Bool>, badge: Int = 0,
         headerMenu: (() -> AnyView)? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self._isExpanded = isExpanded
        self.badge = badge
        self.headerMenu = headerMenu
        self.content = content
    }

    // Headers follow the zoom with their rows — an 11pt header over 20pt
    // rows would read as a layout bug.
    private var header: some View {
        let fonts = ChromeFonts(zoom: zoom)
        return HStack {
            Text(title)
                .font(fonts.sectionHeader)
            Spacer()
            if badge > 0 {
                Text("\(badge)")
                    .font(fonts.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    // Header content ignores the rows' trailing inset —
                    // unpadded, the count hugs the sidebar's edge.
                    .padding(.trailing, 10)
                    .accessibilityLabel("\(badge) unread")
            }
        }
    }

    var body: some View {
        if #available(macOS 14.0, *) {
            Section(isExpanded: $isExpanded) { content() } header: { decoratedHeader }
        } else {
            Section { content() } header: { decoratedHeader }
        }
    }

    @ViewBuilder private var decoratedHeader: some View {
        if let headerMenu {
            header.contextMenu { headerMenu() }
        } else {
            header
        }
    }
}

/// A review-requested PR: unread dot, title over repo#number, and a
/// Markdown-file badge. A real selectable row (spec §1): click opens,
/// arrow keys merely select, the context menu offers Open and GitHub.
private struct InboxRow: View {
    @EnvironmentObject private var state: AppState
    @AppStorage(DefaultsKeys.zoom, store: UserDefaults.pullmark) private var zoom = 1.0
    let item: GitHubClient.InboxPR

    var body: some View {
        let fonts = ChromeFonts(zoom: zoom)
        HStack(spacing: 6) {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 6, height: 6)
                .opacity(state.inboxIsUnread(item) ? 1 : 0)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .lineLimit(1)
                    .font(fonts.row)
                    .fontWeight(state.inboxIsUnread(item) ? .semibold : .regular)
                Text("\(item.ref.owner)/\(item.ref.repo)#\(item.ref.number)"
                    + (item.draft ? " · draft" : ""))
                    .font(fonts.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let count = state.inboxMDCount(item), count > 0 {
                Label("\(count)", systemImage: "doc.text")
                    .font(fonts.caption)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
                    .help(count == 1 ? "1 Markdown file" : "\(count) Markdown files")
            }
        }
        .contentShape(Rectangle())
        // Click opens; the gesture rides alongside List selection so the
        // row still highlights and arrow keys merely select.
        .simultaneousGesture(TapGesture().onEnded { state.openInboxItem(item) })
        .help(state.inboxMDCount(item) == 0
            ? "No Markdown files in this pull request" : item.title)
        .contextMenu {
            Button("Open") { state.openInboxItem(item) }
            Button("Reveal on GitHub") {
                let ref = item.ref
                if let url = URL(string:
                    "https://github.com/\(ref.owner)/\(ref.repo)/pull/\(ref.number)") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}

/// A recent file, folder, or PR. Dead local entries dim instead of
/// vanishing and revive when their path returns (spec §6); clicking a
/// dead entry raises the quiet notice with a removal action.
private struct RecentRow: View {
    @EnvironmentObject private var state: AppState
    @AppStorage(DefaultsKeys.zoom, store: UserDefaults.pullmark) private var zoom = 1.0
    let item: RecentItem
    let missing: Bool
    let showsPath: Bool

    var body: some View {
        let fonts = ChromeFonts(zoom: zoom)
        RemovableRow(help: "Remove from Recents",
                     remove: { state.removeRecent(id: item.id) }) {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(item.title)
                            .lineLimit(1)
                            .font(fonts.row)
                        if item.kind == .pr, let status = item.prStatus, status != .open {
                            Text(status.label)
                                .font(fonts.caption2)
                                .foregroundStyle(status.color)
                        }
                    }
                    if showsPath, let path = item.path {
                        Text(PathAbbreviator.abbreviate((path as NSString).deletingLastPathComponent))
                            .lineLimit(1)
                            .truncationMode(.head)
                            .font(fonts.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } icon: {
                switch item.kind {
                case .file:
                    Image(systemName: missing ? "doc.badge.clock" : "doc.text")
                        .foregroundStyle(.secondary)
                case .folder:
                    Image(systemName: missing ? "folder.badge.questionmark" : "folder")
                        .foregroundStyle(.secondary)
                case .pr:
                    let status = item.prStatus ?? .open
                    Image(systemName: status.systemImage)
                        .foregroundStyle(status.color.opacity(0.75))
                }
            }
            .foregroundStyle(missing ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
        }
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { state.openRecent(item) })
        .help(helpText)
        .contextMenu {
            Button("Remove from Recents") { state.removeRecent(id: item.id) }
            if item.kind != .pr, let path = item.path {
                Divider()
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
                Button("Copy Path") { SidebarActions.copyPath(URL(fileURLWithPath: path)) }
            }
            Divider()
            Button("Clear Recents") { state.clearRecents() }
        }
    }

    private var helpText: String {
        switch item.kind {
        case .file, .folder:
            let path = item.path.map { PathAbbreviator.abbreviate($0) } ?? item.title
            return missing ? "File not found — last seen at \(path)" : path
        case .pr:
            let status = item.prStatus.map { " — \($0.label)" } ?? ""
            return "\(item.owner ?? "")/\(item.repo ?? "")#\(item.number ?? 0)\(status)"
        }
    }
}

/// A PR group: header with status, changed-file count, and hover ✕; its
/// Markdown files as a path tree (spec §3) with status icons and
/// unresolved-comment badges on file nodes; browsed repo docs as a flat
/// run below; and the "other files" honesty line as a quiet final row.
private struct PRSidebarGroup: View {
    @EnvironmentObject private var state: AppState
    @AppStorage(DefaultsKeys.zoom, store: UserDefaults.pullmark) private var zoom = 1.0
    let session: PRSession
    @State private var expanded = true
    /// Tree expansion, all directories open by default (GitHub's
    /// default); per-window, not persisted — PR trees are small.
    @State private var collapsedDirs: Set<String> = []

    private var fonts: ChromeFonts { ChromeFonts(zoom: zoom) }

    /// Unresolved comment count per path — every comment in an unresolved
    /// thread, outdated and file-level included (spec §2). Derived from
    /// reviewComments + threadMeta, which the session publishes together.
    private var commentCounts: [String: Int] {
        ThreadVisibility.unresolvedCommentCounts(comments: session.reviewComments,
                                                 meta: session.threadMeta)
    }

    private var tree: [PathTree.Node] {
        PathTree.build(session.markdownFiles.map(\.filename))
    }

    private var statusByPath: [String: String] {
        Dictionary(uniqueKeysWithValues: session.markdownFiles.map { ($0.filename, $0.status) })
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(tree) { node in
                PRNodeView(session: session, node: node,
                           statusByPath: statusByPath,
                           commentCounts: commentCounts,
                           collapsedDirs: $collapsedDirs)
            }
            ForEach(session.browsedDocs, id: \.self) { path in
                Label {
                    Text(path)
                        .lineLimit(1)
                        .truncationMode(.head)
                } icon: {
                    Image(systemName: "doc.text")
                        .foregroundStyle(.secondary)
                }
                .font(fonts.row)
                .tag(SidebarSelection.prDoc(session.id, path))
            }
            if session.otherFileCount > 0 {
                Text(session.otherFileCount == 1
                    ? "1 other file not shown"
                    : "\(session.otherFileCount) other files not shown")
                    .font(fonts.caption)
                    .foregroundStyle(.secondary)
            }
        } label: {
            // Interpolating the Int directly would go through LocalizedStringKey
            // and render with digit grouping ("#45,206").
            let title: String = "\(session.ref.repo) #\(session.ref.number)"
            let status = PRStatus(details: session.details)
            RemovableRow(help: "Remove from Sidebar",
                         remove: { state.removePR(session.id) }) {
                Label {
                    Text(title)
                        .font(fonts.row)
                } icon: {
                    Image(systemName: status.systemImage)
                        .foregroundStyle(status.color)
                        .drawingGroup() // keeps its tint in the drag preview
                }
                let count = session.markdownFiles.count
                Text("\(count)")
                    .font(fonts.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .help(count == 1 ? "1 changed Markdown file"
                        : "\(count) changed Markdown files")
            }
            .tag(SidebarSelection.prOverview(session.id))
            .help(status.label)
            .contextMenu {
                Button("Remove from Sidebar") { state.removePR(session.id) }
                Button("Reveal on GitHub") {
                    if let url = URL(string: "https://github.com/\(session.ref.owner)/"
                        + "\(session.ref.repo)/pull/\(session.ref.number)") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }
}

/// One node of a PR file tree: directories disclose (expanded by
/// default), files keep their status icon and comment badge.
private struct PRNodeView: View {
    @AppStorage(DefaultsKeys.zoom, store: UserDefaults.pullmark) private var zoom = 1.0
    let session: PRSession
    let node: PathTree.Node
    let statusByPath: [String: String]
    let commentCounts: [String: Int]
    @Binding var collapsedDirs: Set<String>

    private var fonts: ChromeFonts { ChromeFonts(zoom: zoom) }

    var body: some View {
        if node.isDirectory {
            DisclosureGroup(isExpanded: Binding(
                get: { !collapsedDirs.contains(node.path) },
                set: { expanded in
                    if expanded {
                        collapsedDirs.remove(node.path)
                    } else {
                        collapsedDirs.insert(node.path)
                    }
                }
            )) {
                ForEach(node.children) { child in
                    PRNodeView(session: session, node: child,
                               statusByPath: statusByPath,
                               commentCounts: commentCounts,
                               collapsedDirs: $collapsedDirs)
                }
            } label: {
                Label {
                    Text(node.name)
                } icon: {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                }
                .font(fonts.row)
            }
        } else if let filePath = node.filePath {
            HStack(spacing: 6) {
                Label {
                    Text(node.name)
                        .lineLimit(1)
                        .truncationMode(.head)
                } icon: {
                    Image(systemName: Self.icon(for: statusByPath[filePath] ?? ""))
                        .foregroundStyle(Self.color(for: statusByPath[filePath] ?? ""))
                }
                .font(fonts.row)
                if let count = commentCounts[filePath] {
                    Spacer(minLength: 2)
                    Label("\(count)", systemImage: "bubble.left")
                        .font(fonts.caption)
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                        .help(count == 1 ? "1 unresolved review comment"
                            : "\(count) unresolved review comments")
                        .accessibilityLabel("\(count) unresolved review comment\(count == 1 ? "" : "s")")
                }
            }
            .tag(SidebarSelection.prFile(session.id, filePath))
        }
    }

    static func icon(for status: String) -> String {
        switch status {
        case "added": return "plus.circle"
        case "removed": return "minus.circle"
        case "renamed": return "arrow.right.circle"
        default: return "pencil.circle"
        }
    }

    static func color(for status: String) -> Color {
        switch status {
        case "added": return .green
        case "removed": return .red
        default: return .secondary
        }
    }
}

/// A GitHub repo opened for reading: the docs that arrived via links, plus
/// an on-demand full Markdown tree (one explicit "Browse" fetch).
private struct RemoteRepoGroup: View {
    @EnvironmentObject private var state: AppState
    @AppStorage(DefaultsKeys.zoom, store: UserDefaults.pullmark) private var zoom = 1.0
    let session: RemoteRepoSession
    @State private var expanded = true
    @State private var collapsedDirs: Set<String> = []
    @State private var branches: [String] = []
    @State private var menuAnchor = MenuAnchorBox()
    @State private var menuPresenter = MenuActionPresenter()

    private var fonts: ChromeFonts { ChromeFonts(zoom: zoom) }

    /// Branches load on the chip's first click, never on row render.
    private func popBranchMenu() {
        if branches.isEmpty {
            Task {
                do {
                    branches = try await state.client.branchNames(session.ref)
                    presentMenu()
                } catch {
                    state.lastError = AppState.remoteFailureMessage(
                        error, what: "branches of \(session.ref.owner)/\(session.ref.repo)")
                }
            }
        } else {
            presentMenu()
        }
    }

    private func presentMenu() {
        RemoteBranchMenu.present(session: session, branches: branches,
                                 state: state, anchor: menuAnchor.view,
                                 presenter: menuPresenter)
    }

    private var tree: [PathTree.Node]? {
        session.treePaths.map { PathTree.build($0) }
    }

    /// Link-opened docs the fetched tree doesn't already display.
    private var looseDocs: [String] {
        guard let treePaths = session.treePaths else { return session.docs }
        let inTree = Set(treePaths)
        return session.docs.filter { !inTree.contains($0) }
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            // The session's working set — kept docs, then the one preview —
            // sits above the tree so it never drowns under a big repo.
            ForEach(looseDocs, id: \.self) { path in
                RemovableRow(help: "Remove from Sidebar",
                             remove: { state.removeRemoteDoc(sessionID: session.id, path: path) }) {
                    Label {
                        Text(path)
                            .lineLimit(1)
                            .truncationMode(.head)
                    } icon: {
                        Image(systemName: "doc.text")
                            .foregroundStyle(.secondary)
                    }
                    .font(fonts.row)
                }
                .tag(SidebarSelection.remoteDoc(session.id, path))
                .contextMenu {
                    Button("Remove from Sidebar") {
                        state.removeRemoteDoc(sessionID: session.id, path: path)
                    }
                }
            }
            if let tree {
                ForEach(tree) { node in
                    RemoteNodeView(session: session, node: node,
                                   collapsedDirs: $collapsedDirs)
                }
                if session.treeTruncated {
                    Text("Large repo — not all files shown")
                        .font(fonts.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if tree == nil {
                if session.treeLoading {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Loading repo files…")
                            .font(fonts.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    // The one explicit network action: fetches the repo's
                    // Markdown tree so the whole repo is browsable.
                    Button("Browse Repo Files…") {
                        Task { await state.loadRemoteTree(sessionID: session.id) }
                    }
                    .font(fonts.callout)
                }
            }
        } label: {
            RemovableRow(help: "Remove from Sidebar",
                         remove: { state.removeRemoteSession(session.id) }) {
                Label {
                    Text("\(session.ref.repo)")
                        .font(fonts.row)
                } icon: {
                    Image(systemName: "book.closed")
                        .foregroundStyle(.secondary)
                        .drawingGroup() // keeps its tint in the drag preview
                }
                BranchChip(text: session.displayRef, font: fonts.caption,
                           anchor: menuAnchor) {
                    popBranchMenu()
                }
            }
            .tag(SidebarSelection.remoteRepo(session.id))
            .help("\(session.ref.owner)/\(session.ref.repo) @ \(session.displayRef)")
            .contextMenu {
                Button("Remove from Sidebar") { state.removeRemoteSession(session.id) }
                Button("Switch or Open Branch…") { popBranchMenu() }
                if session.treePaths == nil, !session.treeLoading {
                    Button("Browse Repo Files") {
                        Task { await state.loadRemoteTree(sessionID: session.id) }
                    }
                }
                Button("Reveal on GitHub") {
                    if let url = URL(string: "https://github.com/\(session.ref.owner)/"
                        + "\(session.ref.repo)/tree/\(session.displayRef)") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }
}

/// One node of a remote repo tree: plain folders and docs, `.remoteDoc` tags.
private struct RemoteNodeView: View {
    @EnvironmentObject private var state: AppState
    @AppStorage(DefaultsKeys.zoom, store: UserDefaults.pullmark) private var zoom = 1.0
    let session: RemoteRepoSession
    let node: PathTree.Node
    @Binding var collapsedDirs: Set<String>

    private var fonts: ChromeFonts { ChromeFonts(zoom: zoom) }

    var body: some View {
        if node.isDirectory {
            DisclosureGroup(isExpanded: Binding(
                get: { !collapsedDirs.contains(node.path) },
                set: { expanded in
                    if expanded {
                        collapsedDirs.remove(node.path)
                    } else {
                        collapsedDirs.insert(node.path)
                    }
                }
            )) {
                ForEach(node.children) { child in
                    RemoteNodeView(session: session, node: child,
                                   collapsedDirs: $collapsedDirs)
                }
            } label: {
                Label {
                    Text(node.name)
                } icon: {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                }
                .font(fonts.row)
            }
        } else if let filePath = node.filePath {
            Label {
                Text(node.name)
                    .lineLimit(1)
                    .truncationMode(.head)
            } icon: {
                Image(systemName: "doc.text")
                    .foregroundStyle(.secondary)
            }
            .font(fonts.row)
            .tag(SidebarSelection.remoteDoc(session.id, filePath))
            // Same gesture pair as local trees: single click previews
            // (through the List's selection), double click keeps.
            .overlay(DoubleClickCatcher {
                state.pinRemoteDoc(sessionID: session.id, path: filePath)
            })
            .contextMenu {
                Button("Keep Open") {
                    state.pinRemoteDoc(sessionID: session.id, path: filePath)
                }
            }
        }
    }
}

struct DetailView: View {
    @EnvironmentObject private var state: AppState
    @AppStorage(DefaultsKeys.zoom, store: UserDefaults.pullmark) private var zoom = 1.0

    var body: some View {
        switch state.selection {
        case nil:
            placeholder
        case .local(let url):
            if let file = state.localFile(for: url) {
                LocalFileView(file: file)
                    .id(url)
            } else {
                placeholder
            }
        case .prOverview(let id):
            if state.session(id) != nil {
                PROverviewView(sessionID: id)
                    .id(id)
            } else {
                placeholder
            }
        case .prFile(let id, let path):
            if state.session(id) != nil {
                PRFileView(sessionID: id, path: path)
                    .id(id + "|" + path)
            } else {
                placeholder
            }
        case .prDoc(let id, let path):
            if state.session(id) != nil {
                PRDocView(sessionID: id, path: path)
                    .id(id + "|doc|" + path)
            } else {
                placeholder
            }
        case .remoteRepo(let id):
            // A selected repo shows its README when we know of one (from
            // the loaded tree, or a root readme opened via link) — GitHub's
            // own rule for what a repo "is" at a glance.
            if let session = state.remoteSession(id) {
                if let readme = session.treePaths.flatMap({ PathTree.readmePath(in: $0) })
                    ?? PathTree.readmePath(in: session.docs) {
                    RemoteDocView(sessionID: id, path: readme)
                        .id(id + "|" + readme)
                } else {
                    remoteRepoPlaceholder(session)
                }
            } else {
                placeholder
            }
        case .remoteDoc(let id, let path):
            if state.remoteSession(id) != nil {
                RemoteDocView(sessionID: id, path: path)
                    .id(id + "|" + path)
            } else {
                placeholder
            }
        case .folder(let root):
            // A selected place shows its README (then index) when it has
            // one, the count placeholder when it doesn't.
            if let folder = state.folder(for: root), !folder.missing,
               let readme = PathTree.readmePath(in: folder.filePaths),
               let file = state.localFile(for: folder.fileURL(for: readme)) {
                LocalFileView(file: file)
                    .id(folder.fileURL(for: readme))
            } else {
                folderPlaceholder(root)
            }
        case .folderNode(let root, let path):
            if let folder = state.folder(for: root),
               let readme = PathTree.readmePath(in: folder.filePaths, directory: path),
               let file = state.localFile(for: folder.fileURL(for: readme)) {
                LocalFileView(file: file)
                    .id(folder.fileURL(for: readme))
            } else {
                placeholder
            }
        case .inboxItem, .recentItem:
            // Navigational rows: selecting them highlights and enables
            // keyboard actions; the document area shows the empty state.
            placeholder
        }
    }

    /// Selecting a folder root shows the place, not a file (spec §8.6):
    /// name, count, and the nudge to pick something.
    private func folderPlaceholder(_ root: URL) -> some View {
        let factor = DocumentZoom.clamped(zoom)
        let folder = state.folder(for: root)
        let count = folder?.filePaths.count ?? 0
        return VStack(spacing: 12 * factor) {
            Image(systemName: "folder")
                .font(.system(size: 42 * factor))
                .foregroundStyle(.secondary)
            Text(root.lastPathComponent)
                .font(.system(size: 15 * factor, weight: .semibold))
            Text(folder?.missing == true
                ? "Folder not found — it will revive when the path returns"
                : count == 1 ? "1 Markdown file — pick one from the sidebar"
                : "\(count) Markdown files — pick one from the sidebar")
                .font(.system(size: 13 * factor))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Selecting a remote repo root shows the place: repo, ref, and how
    /// much of it is browsable.
    private func remoteRepoPlaceholder(_ session: RemoteRepoSession) -> some View {
        let factor = DocumentZoom.clamped(zoom)
        let count = session.treePaths?.count
        return VStack(spacing: 12 * factor) {
            Image(systemName: "book.closed")
                .font(.system(size: 42 * factor))
                .foregroundStyle(.secondary)
            Text("\(session.ref.owner)/\(session.ref.repo)")
                .font(.system(size: 15 * factor, weight: .semibold))
            Text("@ \(session.displayRef)")
                .font(.system(size: 13 * factor))
                .foregroundStyle(.secondary)
            Text(count.map { $0 == 1 ? "1 Markdown file — pick one from the sidebar"
                    : "\($0) Markdown files — pick one from the sidebar" }
                ?? "Browse Repo Files in the sidebar to see what's here")
                .font(.system(size: 13 * factor))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Sits in the document area, so it follows the document zoom at full
    /// rate — an empty window should answer Zoom In visibly too.
    private var placeholder: some View {
        let factor = DocumentZoom.clamped(zoom)
        return VStack(spacing: 12 * factor) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 42 * factor))
                .foregroundStyle(.secondary)
            Text("Open a Markdown file or a GitHub pull request")
                .font(.system(size: 13 * factor))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
