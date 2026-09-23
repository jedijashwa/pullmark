import QuickLook
import SwiftUI

struct ContentView: View {
    /// Each window owns its state — sidebar, sessions, selection, edits —
    /// which is what makes ⌘N windows and native tabs independent.
    @StateObject private var state = AppState()
    @EnvironmentObject private var updates: UpdateChecker
    @AppStorage(Appearance.defaultsKey, store: UserDefaults.pullmark) private var appearanceRaw = Appearance.system.rawValue
    @AppStorage(DefaultsKeys.showHiddenFiles, store: UserDefaults.pullmark) private var showHiddenFiles = false
    /// The toolbar builder needs it: the margin-note item leaves the
    /// customization pool entirely while the feature is off.
    @AppStorage(DefaultsKeys.marginNotesEnabled, store: UserDefaults.pullmark) private var marginNotesEnabled = true
    @Environment(\.controlActiveState) private var controlActiveState
    /// The error alert's setup affordance (spec: github-connection).
    @ObservedObject private var connection = GitHubClient.shared.connection
    @State private var showGitHubSetup = false

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
                UpdatedBanner()
                DefaultAppBanner()
                RestoreOfferBanner()
                DetailView()
                    .overlay(alignment: .top) { ZoomHUD().padding(.top, 10) }
            }

        }
        // Physical "⌘+" (⇧⌘=) zooms in like the menu's ⌘= — see the catcher.
        .background(ZoomKeyCatcher())
        // Moves app toolbar items back out of the sidebar section when a
        // customize-palette drop lands them there (see AppToolbar).
        .background(ToolbarSectionEnforcer())
        // Mouse buttons 4/5 → back/forward, this window only (spec §7).
        .background(MouseNavMonitor(state: state))
        // Titlebar proxy icon + ⌘-click path menu for the open local file.
        // macOS 14 gets the real API (navigationDocument); 13 the fallback.
        .modifier(DocumentProxyModifier(url: selectedLocalURL))
        .frame(minWidth: 940, minHeight: 620)
        // The whole toolbar — window items AND the active surface's items —
        // lives in this single customizable block: SwiftUI only persists
        // customization for window-level `.toolbar(id:)` content, and one
        // unnamed toolbar item anywhere in the window would disable
        // customization outright (see AppToolbar). Surface views feed it
        // through SurfaceToolbar registration.
        //
        // The identity is PER SURFACE KIND, not a constant: saved
        // arrangements only restore for items present when the toolbar is
        // created — items merging in on a later surface switch rejoin from
        // their defaults, resurrecting anything the user removed (verified
        // live). A per-surface identity gives every surface its own
        // NSToolbar, created with its full item set, so every arrangement
        // saves and restores under its own key — which is also what makes
        // customizations per-surface rather than shared.
        .toolbar(id: toolbarIdentity) {
            AppToolbar(state: state,
                       kind: state.surfaceExpectation?.kind,
                       surface: state.expectedSurfaceToolbar,
                       reviewSessionID: reviewSessionID,
                       marginNotesEnabled: marginNotesEnabled,
                       appearanceRaw: $appearanceRaw)
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
            // Version-less on purpose: the notes carry their versions as
            // headings in the content, matching the post-update sheet.
            ReleaseNotesSheet(title: String(localized: "What's New in PullMark"),
                              markdown: updates.availableNotes,
                              fullHistory: { await updates.releaseNotesHistory() })
        }
        .sheet(isPresented: $updates.showWhatsNew) {
            ReleaseNotesSheet(title: String(localized: "What's New in PullMark"),
                              markdown: updates.whatsNewMarkdown,
                              fullHistory: { await updates.releaseNotesHistory() })
        }
        .sheet(isPresented: $updates.showHistory) {
            ReleaseNotesSheet(title: String(localized: "PullMark Release Notes"),
                              markdown: updates.historyMarkdown)
        }
        .alert("Something went wrong", isPresented: errorPresented) {
            // Signed out, most failures ARE the missing connection —
            // recents, inbox, restore, and deep-link opens all land
            // here, and the fix should too (spec: github-connection).
            // lastError carries no HTTP status, so signed-out is the
            // whole gate; connected users never see the button.
            if connection.status == .notConnected {
                Button("Set Up GitHub Access…") { showGitHubSetup = true }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(state.lastError ?? "")
        }
        .sheet(isPresented: $showGitHubSetup) { GitHubSetupSheet() }
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
        // The show-hidden flip changes what a folder scan even sees —
        // rebuild every root's tree (Settings toggle, ⇧⌘., or the View
        // menu all flow through the same stored flag).
        .onChange(of: showHiddenFiles) { _ in state.rescanAllFolders() }
        // Captures openSettings for SettingsOpener (release-notes deep
        // links) — the sendAction selector no-ops on modern macOS.
        .background(OpenSettingsGrabber())
        // handlesExternalEvents(["*"]) makes the scene claim incoming
        // URL events, so pullmark:// links arrive HERE, not at the app
        // delegate — route them to the shared handler.
        .onOpenURL { AppLinkRouter.handle($0) }
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

    /// One NSToolbar identity per surface KIND (not per document): the
    /// autosaved arrangement is keyed by this, so each surface remembers
    /// its own customization — and restores it correctly regardless of
    /// which surface the app launched on (see the toolbar comment above).
    /// Derived, never registered — see AppState.surfaceExpectation.
    private var toolbarIdentity: String {
        switch state.surfaceExpectation?.kind {
        case .localFile: return "main-local"
        case .remoteDoc: return "main-remote"
        case .prFile: return "main-pr-file"
        case .prDoc: return "main-pr-doc"
        case .prOverview: return "main-pr-overview"
        case .issue: return "main-issue"
        case nil: return "main"
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
    @SceneStorage(DefaultsKeys.sidebarPinnedExpanded) private var pinnedExpanded = true
    @SceneStorage(DefaultsKeys.sidebarIssuesExpanded) private var issuesExpanded = true
    @State private var showFollowRepo = false
    /// Space → Quick Look on the selected local row (spec §8.2).
    @State private var quickLookURL: URL?

    /// Which rows show their true path beneath the title (spec: pinned-
    /// and-session-reopen §2): aliased ones, and title twins within the
    /// same section.
    private var pinnedPathLineIDs: Set<String> {
        SidebarNaming.entriesNeedingPath(state.pins.map {
            .init(id: $0.id, title: $0.title, aliased: $0.alias != nil)
        })
    }

    private var locationPathLineIDs: Set<String> {
        SidebarNaming.entriesNeedingPath(state.unpinnedFolders.map {
            .init(id: $0.rootURL.path, title: $0.displayName, aliased: $0.alias != nil)
        })
    }

    // What you opened yourself outranks what was assigned to you: the
    // review-request subgroup sits below the opened pull requests.
    private var fonts: ChromeFonts { ChromeFonts(zoom: zoom) }

    var body: some View {
        List(selection: $state.selection) {
            // The working set: explicitly opened documents, flat and
            // ordered, plus the single italic preview entry last. Trees
            // answer "where does it live"; this section answers "what do
            // I have open" (Sublime's exact label for the same list).
            CollapsibleSection(String(localized: "Open Files"), isExpanded: $filesExpanded.preloadingOutlineRowsBeforeCollapse(),
                               headerActions: state.hasOpenFiles ? [
                SectionHeaderAction(id: "close-all", symbol: "xmark.circle.fill",
                                    help: String(localized: "Close All")) { state.closeAllOpenFiles() }
            ] : [], headerMenu: {
                // Close All only — the menu mirrors the header's own
                // affordances, and this header deliberately has no +
                // (Josh: "weird that one would show the open but not
                // have the plus").
                AnyView(Button("Close All") { state.closeAllOpenFiles() }
                    .disabled(!state.hasOpenFiles))
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
            // Pinned: what you keep, above where you browse (spec: pinned-
            // and-session-reopen §1). Folder pins are full roots with their
            // own trees; file pins are bookmarks. Hidden while empty.
            if !state.pins.isEmpty {
                let pathIDs = pinnedPathLineIDs
                CollapsibleSection(String(localized: "Pinned"),
                                   isExpanded: $pinnedExpanded.preloadingOutlineRowsBeforeCollapse()) {
                    ForEach(state.pins) { pin in
                        PinnedEntryView(pin: pin, showsPath: pathIDs.contains(pin.id))
                    }
                    .onMove { from, to in state.pins.move(fromOffsets: from, toOffset: to) }
                }
            }
            // Locations: browsable roots wherever they live — local folders
            // and GitHub repos share one section (Finder's word for exactly
            // this list); the icon and subtitle carry the origin.
            CollapsibleSection(String(localized: "Locations"), isExpanded: $foldersExpanded.preloadingOutlineRowsBeforeCollapse(),
                               headerActions: [
                SectionHeaderAction(id: "add-folder", symbol: "plus",
                                    help: String(localized: "Open Folder…")) { state.openFolderPanel() }
            ], headerMenu: {
                AnyView(Group {
                    Button("Open Folder…") { state.openFolderPanel() }
                    Button("Close All") { state.closeAllLocations() }
                        .disabled(state.folders.isEmpty && state.remoteSessions.isEmpty)
                })
            }) {
                if state.unpinnedFolders.isEmpty, state.remoteSessions.isEmpty {
                    Button("Open Folder…") { state.openFolderPanel() }
                        .font(fonts.callout)
                }
                let pathIDs = locationPathLineIDs
                ForEach(state.unpinnedFolders) { folder in
                    FolderRootGroup(folder: folder, showsPath: pathIDs.contains(folder.rootURL.path))
                }
                .onMove { from, to in state.moveLocations(fromOffsets: from, toOffset: to) }
                ForEach(state.remoteSessions) { session in
                    RemoteRepoGroup(session: session)
                }
                .onMove { from, to in state.remoteSessions.move(fromOffsets: from, toOffset: to) }
            }
            // GitHub work (spec: github-work): opened sessions, involvement
            // buckets, followed repositories — grouped by type (a Pull
            // Requests section and an Issues section) or by involvement
            // (one GitHub section, both kinds mixed, glyph per row).
            if state.workGrouping == .involvement {
                CollapsibleSection(String(localized: "GitHub"),
                                   isExpanded: $prsExpanded.preloadingOutlineRowsBeforeCollapse(),
                                   headerActions: [addPRAction],
                                   headerMenu: { AnyView(githubHeaderMenu) }) {
                    if state.prSessions.isEmpty, state.issueSessions.isEmpty {
                        Button("Open Pull Request…") { state.showAddPR = true }
                            .font(fonts.callout)
                    }
                    openedPRSessions
                    openedIssueSessions
                    workBuckets(kind: nil)
                    followedRepoGroups(kind: nil)
                }
            } else {
                CollapsibleSection(String(localized: "Pull Requests"),
                                   isExpanded: $prsExpanded.preloadingOutlineRowsBeforeCollapse(),
                                   headerActions: [addPRAction],
                                   headerMenu: { AnyView(prHeaderMenu) }) {
                    if state.prSessions.isEmpty {
                        Button("Open Pull Request…") { state.showAddPR = true }
                            .font(fonts.callout)
                    }
                    openedPRSessions
                    workBuckets(kind: .pr)
                    followedRepoGroups(kind: .pr)
                }
                if !state.issueSessions.isEmpty || hasIssueWork {
                    CollapsibleSection(String(localized: "Issues"),
                                       isExpanded: $issuesExpanded.preloadingOutlineRowsBeforeCollapse(),
                                       headerMenu: { AnyView(issuesHeaderMenu) }) {
                        openedIssueSessions
                        workBuckets(kind: .issue)
                        followedRepoGroups(kind: .issue)
                    }
                }
            }
            if !recentItems.isEmpty {
                CollapsibleSection(String(localized: "Recents"), isExpanded: $recentExpanded.preloadingOutlineRowsBeforeCollapse()) {
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
        // Return renames the selected root or pinned file (spec: pinned-
        // and-session-reopen §2).
        .background(RenameKeyMonitor(state: state))
        .sheet(isPresented: $showFollowRepo) { FollowRepoSheet() }
        .sheet(item: $state.imagesFolderPrompt) { prompt in ImagesFolderSheet(root: prompt.root) }
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
    // MARK: GitHub work (spec: github-work)

    private var addPRAction: SectionHeaderAction {
        SectionHeaderAction(id: "add-pr", symbol: "plus",
                            help: String(localized: "Open Pull Request…")) { state.showAddPR = true }
    }

    @ViewBuilder private var prHeaderMenu: some View {
        Button("Open Pull Request…") { state.showAddPR = true }
        Button("Follow Repository…") { showFollowRepo = true }
        Button("Close All") { state.closeAllPRSessions() }
            .disabled(state.prSessions.isEmpty)
    }

    @ViewBuilder private var issuesHeaderMenu: some View {
        Button("Follow Repository…") { showFollowRepo = true }
        Button("Close All") { state.closeAllIssueSessions() }
            .disabled(state.issueSessions.isEmpty)
    }

    @ViewBuilder private var githubHeaderMenu: some View {
        Button("Open Pull Request…") { state.showAddPR = true }
        Button("Follow Repository…") { showFollowRepo = true }
        Button("Close All") {
            state.closeAllPRSessions()
            state.closeAllIssueSessions()
        }
        .disabled(state.prSessions.isEmpty && state.issueSessions.isEmpty)
    }

    private var openedPRSessions: some View {
        ForEach(state.prSessions) { session in
            PRSidebarGroup(session: session)
        }
        .onMove { from, to in state.prSessions.move(fromOffsets: from, toOffset: to) }
    }

    private var openedIssueSessions: some View {
        ForEach(state.issueSessions) { session in
            IssueSidebarRow(session: session)
        }
        .onMove { from, to in state.issueSessions.move(fromOffsets: from, toOffset: to) }
    }

    /// A bucket's visible rows: pull requests honor the Markdown-only
    /// filter (issues have no files to filter by).
    private func bucketItems(_ bucket: GitHubWork.Bucket, kind: GitHubWork.Kind?) -> [GitHubWork.Item] {
        let items = kind.map { state.work.items(in: bucket, kind: $0) } ?? state.work.items(in: bucket)
        guard inboxMarkdownOnly else { return items }
        return items.filter { $0.kind == .issue || (state.inboxMDCount($0) ?? 1) > 0 }
    }

    /// Empty buckets stay hidden (spec §2).
    @ViewBuilder private func workBuckets(kind: GitHubWork.Kind?) -> some View {
        if inboxEnabled {
            let buckets = kind.map(GitHubWork.Bucket.buckets(for:)) ?? GitHubWork.Bucket.allCases
            ForEach(buckets) { bucket in
                let items = bucketItems(bucket, kind: kind)
                if !items.isEmpty {
                    WorkGroup(title: Self.bucketTitle(bucket), systemImage: Self.bucketSymbol(bucket),
                              items: items, bucket: bucket, showsKind: kind == nil,
                              moreKey: GitHubWork.Snapshot.bucketKey(bucket))
                }
            }
        }
    }

    @ViewBuilder private func followedRepoGroups(kind: GitHubWork.Kind?) -> some View {
        if inboxEnabled {
            ForEach(state.followedRepos) { repo in
                FollowedRepoGroup(repo: repo, kind: kind)
            }
        }
    }

    /// Whether the type layout has an Issues section to show at all.
    private var hasIssueWork: Bool {
        guard inboxEnabled else { return false }
        return GitHubWork.Bucket.buckets(for: .issue).contains { !state.work.items(in: $0, kind: .issue).isEmpty }
            || state.followedRepos.contains { !state.work.items(inRepo: $0.id, kind: .issue).isEmpty }
    }

    static func bucketTitle(_ bucket: GitHubWork.Bucket) -> String {
        switch bucket {
        case .reviewRequests: return String(localized: "Review Requests")
        case .created: return String(localized: "Created")
        case .assigned: return String(localized: "Assigned")
        case .participating: return String(localized: "Participating")
        }
    }

    static func bucketSymbol(_ bucket: GitHubWork.Bucket) -> String {
        switch bucket {
        case .reviewRequests: return "tray"
        case .created: return "pencil.circle"
        case .assigned: return "person.crop.circle"
        case .participating: return "bubble.left.and.bubble.right"
        }
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
            case .issue:
                guard let ref = item.ref else { return false }
                return !state.issueSessions.contains { $0.ref == ref }
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
        RemovableRow(help: isPreview ? String(localized: "Dismiss Preview") : String(localized: "Remove from Sidebar"),
                     remove: { isPreview ? state.dismissPreview()
                                         : state.removeLocalFile(file) }) {
            HStack(spacing: 4) {
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
                // The PR files' comment chip, for margin notes: which docs
                // still carry notes, at a glance. Live — the count watcher
                // sees an agent deleting notes as it addresses them.
                if let count = state.marginNoteCounts[file.url.path], count > 0 {
                    let notes = count == 1 ? String(localized: "1 margin note")
                        : String(localized: "\(count) margin notes")
                    Spacer(minLength: 2)
                    Label("\(count)", systemImage: "bubble.left")
                        .font(fonts.caption)
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                        .help(notes)
                        .accessibilityLabel(notes)
                }
            }
        }
        .overlay(isPreview ? DoubleClickCatcher { state.pinFile(at: file.url) } : nil)
        .help(PathAbbreviator.abbreviate(file.url.path)
            + (isPreview ? " — previewing; double-click to keep open" : ""))
        .contextMenu {
            if isPreview {
                Button("Keep Open") { state.pinFile(at: file.url) }
                Button("Dismiss Preview") { state.dismissPreview() }
                // Above ≡ Others for the last row and Below is always
                // empty, so the preview slot carries Others alone.
                Button("Close Others") { state.closeOpenFiles(.others, target: .preview) }
                    .disabled(state.localFiles.isEmpty)
            } else {
                Button("Remove from Sidebar") { state.removeLocalFile(file) }
                bulkCloseItems
            }
            if state.folderRootContaining(file.url) != nil {
                Button("Reveal in Location") { state.revealInLocation(file.url) }
            }
            Button("Pin…") { state.addPin(fileAt: file.url) }
            Divider()
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
            Button("Copy Path") { SidebarActions.copyPath(file.url) }
            SidebarActions.copyGitHubLinkItems(url: file.url, state: state)
        }
    }

    /// Close Others / Close Above / Close Below on a pinned row (spec:
    /// sidebar-section-affordances §8) — the tab bar's bulk closes,
    /// vertical. Disabled (never hidden) when a direction is empty, so
    /// the menu keeps a stable shape. Enablement reads render-time
    /// state (rows re-render on any working-set change); the row's
    /// index is re-resolved at CLICK time, since drag-reordering can
    /// move it between render and click.
    @ViewBuilder private var bulkCloseItems: some View {
        let count = state.localFiles.count
        let hasPreview = state.preview != nil
        if let index = state.localFiles.firstIndex(where: { $0.url == file.url }) {
            let disabled = { (scope: WorkingSetClose.Scope) in
                WorkingSetClose.plan(scope, target: .pinned(index: index),
                                     pinnedCount: count, hasPreview: hasPreview).isNoOp
            }
            Button("Close Others") { performBulkClose(.others) }
                .disabled(disabled(.others))
            Button("Close Above") { performBulkClose(.above) }
                .disabled(disabled(.above))
            Button("Close Below") { performBulkClose(.below) }
                .disabled(disabled(.below))
        }
    }

    private func performBulkClose(_ scope: WorkingSetClose.Scope) {
        guard let index = state.localFiles.firstIndex(where: { $0.url == file.url }) else { return }
        state.closeOpenFiles(scope, target: .pinned(index: index))
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
        RemovableRow(help: String(localized: "Dismiss Preview"),
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
            // Same shape as the local preview slot: Others alone.
            Button("Close Others") { state.closeOpenFiles(.others, target: .preview) }
                .disabled(state.localFiles.isEmpty)
        }
    }
}

/// Shared clipboard/Finder actions for sidebar rows.
enum SidebarActions {
    static func copyPath(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }

    /// Copy GitHub Link (spec: copy-github-link §3): resolve the
    /// checkout at click time and put the github.com URL on the
    /// pasteboard. A repo with no GitHub remote gets the quiet notice,
    /// never the error alert. Detached HEAD falls back to the SHA form,
    /// so the branch flavor never dead-ends.
    @MainActor
    static func copyGitHubLink(_ url: URL, isDirectory: Bool,
                               permalink: Bool, state: AppState) {
        let root = isDirectory
            ? LocalGit.repoRoot(forDirectory: url)
            : LocalGit.repoRoot(for: url)
        guard let root else { return }
        guard let repo = LocalGit.linkableGitHubRepo(in: root) else {
            state.lastNotice = String(localized: "This repository has no GitHub remote.")
            return
        }
        // The checkout root itself links as the bare tree/<ref> —
        // relativePath's lastPathComponent fallback is for files.
        let path = url.standardizedFileURL.path == root.standardizedFileURL.path
            ? "" : LocalGit.relativePath(of: url, in: root)
        // The menu gate hides untracked rows, but it degrades to
        // showing when trackedness is unknown (loose file, oversized
        // repo) or stale (a rare terminal `git rm` window) — so the
        // click asks git for the truth rather than copying a dead link.
        // The repo root itself is always linkable.
        if !path.isEmpty, !LocalGit.isTracked(path, in: root) {
            state.lastNotice = String(localized: "Not tracked in this repository.")
            return
        }
        let ref = permalink
            ? LocalGit.headSHA(in: root)
            : LocalGit.currentBranch(in: root) ?? LocalGit.headSHA(in: root)
        guard let ref else { return }
        let link = GitHubLink.url(
            owner: repo.owner, repo: repo.repo, ref: ref,
            path: path, isDirectory: isDirectory)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
    }
}

extension SidebarActions {
    /// "Copy GitHub Link" plus its ⌥ alternate for context menus (spec:
    /// copy-github-link §4). A @ViewBuilder FUNCTION, deliberately: a
    /// custom View struct with @EnvironmentObject silently renders
    /// nothing inside .contextMenu (the environment never crosses the
    /// menu bridge — verified live), so the items inline into the row's
    /// own builder and take state explicitly. Renders nothing outside a
    /// git checkout; the primary copies what Settings says, the
    /// alternate names the other flavor. macOS 13/14 lack
    /// modifierKeyAlternate and show only the primary item.
    /// Render-time presence for Copy GitHub Link: inside a checkout, and
    /// what GitHub has of the row (spec: copy-github-link §3/§8). The
    /// `.git` walk stays pure filesystem; presence comes from the
    /// RepoInfo an opened folder already holds — no subprocess at row
    /// render, ever. Nil means no item at all: outside any checkout, or
    /// a directory with nothing on GitHub under it. `.unknown` when no
    /// folder covers the repo (loose file, symlinked open path whose
    /// string form differs from git's toplevel): offer the item, the
    /// pre-cache behavior, and the click's own git check catches lies.
    /// A nested checkout's nearest root matches no toplevel the same
    /// way — its rows stay offered and resolve against the inner repo.
    @MainActor
    static func gitHubPresence(url: URL, isDirectory: Bool,
                               state: AppState) -> GitHubPresence.State? {
        guard let root = GitHubLink.nearestRepoRoot(url, isDirectory: isDirectory) else {
            return nil
        }
        // toplevel comes from git as a realpath ("/private/tmp/…"); the
        // walk standardizes NSString-style ("/tmp/…") — normalize the
        // git side the same way or the two never match under /tmp, /var,
        // /etc. Symlinked roots elsewhere still miss and default to
        // offering, which the click's own check backstops.
        guard let info = state.folders.lazy.compactMap(\.git)
            .first(where: { ($0.toplevel as NSString).standardizingPath == root })
        else { return .unknown }
        // Both paths standardized the same way, so the prefix relation
        // the walk established holds; dropFirst eats the "/" separator
        // (already absent when the row IS the root).
        let full = (url.path as NSString).standardizingPath
        let rel = String(full.dropFirst(min(root.count + 1, full.count)))
        let presence = GitHubPresence.classify(relativePath: rel, isDirectory: isDirectory,
                                               index: info.presence)
        // A directory with nothing on GitHub has no page to link and no
        // single reason to give: the item stays out of its menu.
        if isDirectory, case .absent = presence { return nil }
        return presence
    }

    static func reasonText(_ reason: GitHubPresence.Reason) -> String {
        switch reason {
        case .ignoredByGitignore: return String(localized: "Ignored by .gitignore")
        case .ignoredLocally: return String(localized: "Ignored locally")
        case .notCommitted: return String(localized: "Not committed yet")
        case .notPushed: return String(localized: "Not pushed yet")
        }
    }

    @MainActor @ViewBuilder
    static func copyGitHubLinkItems(url: URL, isDirectory: Bool = false,
                                    state: AppState) -> some View {
        switch gitHubPresence(url: url, isDirectory: isDirectory, state: state) {
        case nil:
            EmptyView()
        case .absent(let reason):
            // Disabled, reason in the title. A menu subtitle (a second
            // Text in the label) was the plan; the contextMenu bridge
            // drops it on macOS 26 — verified live: the item renders
            // with an empty line beneath — so the title carries it.
            Button {} label: {
                Text(verbatim: String(localized: "Copy GitHub Link") + " (" + reasonText(reason) + ")")
            }
            .disabled(true)
        case .onGitHub, .unknown:
            // The setting is read at CLICK time — context menu content
            // builds at row render, and a builder-time read would copy
            // a stale flavor after Settings changes. Only the alternate
            // TITLE reads at build (cosmetic; heals on next render).
            let primary = Button("Copy GitHub Link") {
                copyGitHubLink(url, isDirectory: isDirectory,
                               permalink: permalinkIsDefault, state: state)
            }
            if #available(macOS 15.0, *) {
                primary.modifierKeyAlternate(.option) {
                    Button(permalinkIsDefault ? "Copy GitHub Branch Link"
                                              : "Copy GitHub Permalink") {
                        copyGitHubLink(url, isDirectory: isDirectory,
                                       permalink: !permalinkIsDefault, state: state)
                    }
                }
            } else {
                primary
            }
        }
    }

    private static var permalinkIsDefault: Bool {
        UserDefaults.pullmark.string(forKey: DefaultsKeys.githubLinkStyle) == "commit"
    }
}

/// A folder root: closeable place with its tree (or flat list) below.
private struct FolderRootGroup: View {
    @EnvironmentObject private var state: AppState
    @AppStorage(DefaultsKeys.zoom, store: UserDefaults.pullmark) private var zoom = 1.0
    let folder: LocalFolder
    /// Set when this root lives in the Pinned section: the pin owns the
    /// alias and the Unpin action (spec: pinned-and-session-reopen §1).
    var pin: Pin? = nil
    /// Show the true path beneath the title (aliased, or a title twin).
    var showsPath = false

    private var renameID: String { pin?.id ?? "root:" + folder.rootURL.path }
    private var title: String { pin?.title ?? folder.displayName }
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

        header(String(localized: "Worktrees"))
        for worktree in git.worktrees {
            let path = worktree.path
            let isHere = path == git.toplevel
            item((worktree.branch ?? "detached") + " — " + PathAbbreviator.abbreviate(path),
                 checked: isHere, in: menu) {
                if !isHere { state.add(url: URL(fileURLWithPath: path)) }
            }
        }
        if let repoID = git.primaryGitHubRepo, !ghBranches.isEmpty {
            header(String(localized: "View Branch from GitHub"))
            for branch in ghBranches.prefix(100) where branch != git.branch {
                if let worktree = git.worktrees.first(where: { $0.branch == branch }) {
                    let path = worktree.path
                    item(String(localized: "\(branch) — worktree"), in: menu) {
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
            // A branch the remote never saw would 404 at tree/<branch>;
            // the repo page is the honest target then.
            let branch = git.upstreamExists ? git.branch : nil
            item(String(localized: "Open on GitHub"), in: menu) {
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
        ).preloadingOutlineRowsBeforeCollapse()) {
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
                Text("Showing the first \(folder.filePaths.count) Markdown files")
                    .font(fonts.caption)
                    .foregroundStyle(.secondary)
                    .help("This folder has more Markdown files than PullMark scans — open a subfolder as its own Location to see the rest")
            }
        } label: {
            rootRow
        }
    }

    private var rootRow: some View {
        RemovableRow(help: "Remove from Sidebar",
                     remove: { state.removeFolder(folder.rootURL) }) {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    RenamableTitle(id: renameID, title: title,
                                   name: folder.rootURL.lastPathComponent, font: fonts.row) { draft in
                        if let pin {
                            state.setAlias(draft, forPin: pin.id)
                        } else {
                            state.setAlias(draft, forRoot: folder.rootURL)
                        }
                    }
                    if showsPath {
                        Text(PathAbbreviator.abbreviate(folder.rootURL.path))
                            .font(fonts.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
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
            ? String(localized: "Folder not found — last seen at \(PathAbbreviator.abbreviate(folder.rootURL.path))")
            : PathAbbreviator.abbreviate(folder.rootURL.path))
        .contextMenu {
            if let pin {
                Button("Unpin") { state.unpin(id: pin.id) }
            } else {
                Button("Pin") { state.addPin(folderAt: folder.rootURL) }
            }
            Button("Rename…") { state.renamingEntry = renameID }
            Button("Remove from Sidebar") { state.removeFolder(folder.rootURL) }
            Divider()
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([folder.rootURL])
            }
            Button("Copy Path") { SidebarActions.copyPath(folder.rootURL) }
            SidebarActions.copyGitHubLinkItems(url: folder.rootURL, isDirectory: true, state: state)
            Button("Refresh Folder") { state.rescanFolder(root: folder.rootURL) }
            Button("Images Folder…") { state.imagesFolderPrompt = AppState.ImagesFolderPrompt(root: folder.rootURL) }
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
                        let ref = (git.upstreamExists ? git.branch : nil).map { "/tree/\($0)" } ?? ""
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
        Button("Pin…") { state.addPin(fileAt: url) }
        Divider()
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        Button("Copy Path") { SidebarActions.copyPath(url) }
        SidebarActions.copyGitHubLinkItems(url: url, state: state)
    }
}

/// One Pinned row (spec: pinned-and-session-reopen §1): a pinned folder
/// is a full root with its own tree, exactly like a Location; a pinned
/// file is a bookmark that previews on click and keeps open on
/// double-click.
private struct PinnedEntryView: View {
    @EnvironmentObject private var state: AppState
    let pin: Pin
    let showsPath: Bool

    var body: some View {
        switch pin.kind {
        case .folder:
            if let folder = state.folder(for: pin.url) {
                FolderRootGroup(folder: folder, pin: pin, showsPath: showsPath)
            }
        case .file:
            PinnedFileRow(pin: pin, showsPath: showsPath)
        }
    }
}

private struct PinnedFileRow: View {
    @EnvironmentObject private var state: AppState
    @AppStorage(DefaultsKeys.zoom, store: UserDefaults.pullmark) private var zoom = 1.0
    let pin: Pin
    let showsPath: Bool

    var body: some View {
        let fonts = ChromeFonts(zoom: zoom)
        let missing = !FileManager.default.fileExists(atPath: pin.path)
        Label {
            VStack(alignment: .leading, spacing: 1) {
                RenamableTitle(id: pin.id, title: pin.title, name: pin.name, font: fonts.row) { draft in
                    state.setAlias(draft, forPin: pin.id)
                }
                if showsPath {
                    Text(PathAbbreviator.abbreviate((pin.path as NSString).deletingLastPathComponent))
                        .font(fonts.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        } icon: {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
                .drawingGroup()
        }
        .foregroundStyle(missing ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
        .tag(SidebarSelection.pinnedFile(pin.id))
        .contentShape(Rectangle())
        // Click previews, like a tree row; the gesture rides alongside
        // List selection so the row still highlights. Not while its own
        // title is being edited.
        .simultaneousGesture(TapGesture().onEnded {
            if state.renamingEntry != pin.id { state.previewPinnedFile(pin) }
        })
        .overlay(DoubleClickCatcher { state.openPinnedFile(pin) })
        .help(missing
            ? String(localized: "File not found — last seen at \(PathAbbreviator.abbreviate(pin.path))")
            : PathAbbreviator.abbreviate(pin.path))
        .contextMenu {
            Button("Keep Open") { state.openPinnedFile(pin) }
            Button("Rename…") { state.renamingEntry = pin.id }
            Button("Unpin") { state.unpin(id: pin.id) }
            Divider()
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([pin.url]) }
            Button("Copy Path") { SidebarActions.copyPath(pin.url) }
            SidebarActions.copyGitHubLinkItems(url: pin.url, state: state)
        }
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
            ).preloadingOutlineRowsBeforeCollapse()) {
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
                        Button("Pin…") { state.addPin(folderAt: folder.fileURL(for: node.path)) }
                        Divider()
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting(
                                [folder.fileURL(for: node.path)])
                        }
                        Button("Copy Path") {
                            SidebarActions.copyPath(folder.fileURL(for: node.path))
                        }
                        SidebarActions.copyGitHubLinkItems(url: folder.fileURL(for: node.path), isDirectory: true, state: state)
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
                    Button("Pin…") { state.addPin(fileAt: folder.fileURL(for: node.path)) }
                    Divider()
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [folder.fileURL(for: node.path)])
                    }
                    Button("Copy Path") {
                        SidebarActions.copyPath(folder.fileURL(for: node.path))
                    }
                    SidebarActions.copyGitHubLinkItems(
                        url: folder.fileURL(for: node.path), state: state)
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

/// A hover-revealed section-header action (spec:
/// sidebar-section-affordances §1–§2). Mail's convention: the glyph
/// sits BESIDE the label — the trailing edge belongs to the system
/// collapse chevron and the badge. Hover-only controls are invisible
/// to keyboard and VoiceOver users, so every action here must also
/// exist as a menu command.
private struct SectionHeaderAction: Identifiable {
    let id: String
    let symbol: String
    let help: String
    let action: () -> Void
}

/// A sidebar section the user can fold away. Native collapsing (chevron in
/// the header) needs macOS 14's `Section(isExpanded:)`; on macOS 13 the
/// section renders permanently expanded. A non-zero `badge` renders a
/// count at the header's trailing edge (visible even while collapsed).
private struct CollapsibleSection<Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    var badge = 0
    /// Hover-revealed buttons beside the label (see SectionHeaderAction).
    var headerActions: [SectionHeaderAction] = []
    /// Optional right-click actions on the section header itself (e.g.
    /// Close All on Open Files).
    var headerMenu: (() -> AnyView)?
    @ViewBuilder let content: () -> Content
    @AppStorage(DefaultsKeys.zoom, store: UserDefaults.pullmark) private var zoom = 1.0
    /// Same plain onHover approach as RemovableRow — its stale-latch
    /// edges are accepted there, and consistency beats new tracking
    /// machinery. The buttons only exist while hovered, so they can't
    /// eat clicks meant for the header.
    @State private var headerHovered = false

    init(_ title: String, isExpanded: Binding<Bool>, badge: Int = 0,
         headerActions: [SectionHeaderAction] = [],
         headerMenu: (() -> AnyView)? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self._isExpanded = isExpanded
        self.badge = badge
        self.headerActions = headerActions
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
            if headerHovered {
                ForEach(headerActions) { item in
                    Button(action: item.action) {
                        Image(systemName: item.symbol)
                            .font(fonts.caption)
                            // Semibold to match the section chevron's
                            // stroke — at text weight the bare plus reads
                            // as punctuation, not a button (Josh's call).
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .help(item.help)
                    .accessibilityLabel(item.help)
                }
            }
            Spacer()
            if badge > 0 {
                Text("\(badge)")
                    .font(fonts.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    // Header content ignores the rows' trailing inset —
                    // unpadded, the count hugs the sidebar's edge.
                    .padding(.trailing, 10)
                    .accessibilityLabel(badge == 1 ? String(localized: "1 unread")
                        : String(localized: "\(badge) unread"))
            }
        }
        .contentShape(Rectangle())
        .onHover { headerHovered = $0 }
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
        RemovableRow(help: String(localized: "Remove from Recents"),
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
                case .issue:
                    Image(systemName: "smallcircle.filled.circle")
                        .foregroundStyle(.secondary)
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
            return missing ? String(localized: "File not found — last seen at \(path)") : path
        case .pr, .issue:
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
        DisclosureGroup(isExpanded: $expanded.preloadingOutlineRowsBeforeCollapse()) {
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
                    .help(count == 1 ? String(localized: "1 changed Markdown file")
                        : String(localized: "\(count) changed Markdown files"))
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
            ).preloadingOutlineRowsBeforeCollapse()) {
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
                    let comments = count == 1 ? String(localized: "1 unresolved review comment")
                        : String(localized: "\(count) unresolved review comments")
                    Spacer(minLength: 2)
                    Label("\(count)", systemImage: "bubble.left")
                        .font(fonts.caption)
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                        .help(comments)
                        .accessibilityLabel(comments)
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
        DisclosureGroup(isExpanded: $expanded.preloadingOutlineRowsBeforeCollapse()) {
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
            ).preloadingOutlineRowsBeforeCollapse()) {
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
            } else if !FileManager.default.fileExists(atPath: url.path) {
                // A dead history landing (spec §4.1): name what was here
                // instead of skipping past it. On-disk-but-closed files
                // never reach this — traversal revives them first.
                unavailable(for: .local(url),
                            reason: "This file has been moved or deleted.",
                            detail: PathAbbreviator.abbreviate(url.path))
            } else {
                placeholder
            }
        case .prOverview(let id):
            if state.session(id) != nil {
                PROverviewView(sessionID: id)
                    .id(id)
            } else {
                unavailable(for: .prOverview(id),
                            reason: "Couldn’t load this pull request.")
            }
        case .issue(let id):
            if state.issueSession(id) != nil {
                IssueView(sessionID: id)
                    .id(id)
            } else {
                unavailable(for: .issue(id), reason: "Couldn’t load this issue.")
            }
        case .prFile(let id, let path):
            if state.session(id) != nil {
                PRFileView(sessionID: id, path: path)
                    .id(id + "|" + path)
            } else {
                unavailable(for: .prFile(id, path),
                            reason: "Couldn’t load this pull request.")
            }
        case .prDoc(let id, let path):
            if state.session(id) != nil {
                PRDocView(sessionID: id, path: path)
                    .id(id + "|doc|" + path)
            } else {
                unavailable(for: .prDoc(id, path),
                            reason: "Couldn’t load this pull request.")
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
                unavailable(for: .remoteRepo(id),
                            reason: "Couldn’t load this repository.")
            }
        case .remoteDoc(let id, let path):
            if state.remoteSession(id) != nil {
                RemoteDocView(sessionID: id, path: path)
                    .id(id + "|" + path)
            } else {
                unavailable(for: .remoteDoc(id, path),
                            reason: "Couldn’t load this repository.")
            }
        case .folder(let root):
            // A selected place shows its README (then index) when it has
            // one, the count placeholder when it doesn't.
            if state.folder(for: root) == nil {
                unavailable(for: .folder(root),
                            reason: "This folder has been moved or deleted.",
                            detail: PathAbbreviator.abbreviate(root.path))
            } else if let folder = state.folder(for: root), !folder.missing,
                      let readme = PathTree.readmePath(in: folder.filePaths),
                      let file = state.localFile(for: folder.fileURL(for: readme)) {
                LocalFileView(file: file)
                    .id(folder.fileURL(for: readme))
            } else {
                folderPlaceholder(root)
            }
        case .folderNode(let root, let path):
            if state.folder(for: root) == nil {
                unavailable(for: .folderNode(root, path),
                            reason: "This folder has been moved or deleted.",
                            detail: PathAbbreviator.abbreviate(root.path))
            } else if let folder = state.folder(for: root),
                      let readme = PathTree.readmePath(in: folder.filePaths, directory: path),
                      let file = state.localFile(for: folder.fileURL(for: readme)) {
                LocalFileView(file: file)
                    .id(folder.fileURL(for: readme))
            } else {
                placeholder
            }
        case .inboxItem, .recentItem, .pinnedFile:
            // Navigational rows: selecting them highlights and enables
            // keyboard actions; the document area shows the empty state.
            placeholder
        }
    }

    /// A dead history landing (spec back-forward-navigation §4.1): the
    /// entry's snapshotted name and symbol over a one-line reason, in the
    /// placeholder's visual style. Back never silently skips a dead
    /// entry — at least the reader learns what the document was. While a
    /// revival fetch is in flight this is the loading state instead.
    private func unavailable(for selection: SidebarSelection,
                             reason: String, detail: String? = nil) -> some View {
        let factor = DocumentZoom.clamped(zoom)
        let display = state.historyDisplay(for: selection)
        let reviving = state.historyRevival == selection
        return VStack(spacing: 12 * factor) {
            Image(systemName: display.symbol)
                .font(.system(size: 42 * factor))
                .foregroundStyle(.secondary)
            Text(display.title)
                .font(.system(size: 15 * factor, weight: .semibold))
            if reviving {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Reopening…")
                }
                .font(.system(size: 13 * factor))
                .foregroundStyle(.secondary)
            } else {
                Text(reason)
                    .font(.system(size: 13 * factor))
                    .foregroundStyle(.secondary)
                if let detail {
                    Text(detail)
                        .font(.system(size: 13 * factor))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

// MARK: - Images folder (spec: rich-editor §9)

/// Where pasted and dropped images land for one Location: a root-relative
/// folder, or automatic (the folder the Location's Markdown already
/// references most, else `<document>.assets/`).
private struct ImagesFolderSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let root: URL
    @State private var folder = ""

    private var detected: String? {
        state.folders.first { $0.rootURL == root }.flatMap { state.detectedImagesFolder(for: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Images Folder").font(.headline)
            Text("Pasted and dropped images are saved here, relative to \(root.lastPathComponent). Leave it empty to use the folder this Location's documents already reference.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField(detected ?? "images", text: $folder)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            if let detected {
                Text("Detected: \(detected)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { folder = state.imagesFolderOverride(forRoot: root) ?? "" }
    }

    private func save() {
        state.setImagesFolderOverride(folder, forRoot: root)
        dismiss()
    }
}
