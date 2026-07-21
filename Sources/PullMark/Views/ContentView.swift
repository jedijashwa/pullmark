import SwiftUI

struct ContentView: View {
    /// Each window owns its state — sidebar, sessions, selection, edits —
    /// which is what makes ⌘N windows and native tabs independent.
    @StateObject private var state = AppState()
    @EnvironmentObject private var updates: UpdateChecker
    /// Observed so the toolbar's shortcut hints follow a rebind.
    @ObservedObject private var shortcuts = ShortcutStore.shared
    @AppStorage(Appearance.defaultsKey) private var appearanceRaw = Appearance.system.rawValue
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 270)
        } detail: {
            VStack(spacing: 0) {
                AppUpdateBanner()
                DefaultAppBanner()
                DetailView()
            }
        }
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
}

struct SidebarView: View {
    @EnvironmentObject private var state: AppState

    @AppStorage(DefaultsKeys.inboxEnabled) private var inboxEnabled = true
    @AppStorage(DefaultsKeys.inboxMarkdownOnly) private var inboxMarkdownOnly = true
    // Per-window like the rest of the sidebar (@AppStorage would live-sync
    // a collapse in one window into every other window).
    @SceneStorage(DefaultsKeys.sidebarLocalExpanded) private var localExpanded = true
    @SceneStorage(DefaultsKeys.sidebarPRsExpanded) private var prsExpanded = true
    @SceneStorage(DefaultsKeys.sidebarInboxExpanded) private var inboxExpanded = true
    @SceneStorage(DefaultsKeys.sidebarRecentExpanded) private var recentExpanded = true

    // What you opened yourself outranks what was assigned to you: the
    // review-request inbox sits below Local Files and Pull Requests.
    var body: some View {
        List(selection: $state.selection) {
            CollapsibleSection("Local Files", isExpanded: $localExpanded) {
                if state.localFiles.isEmpty {
                    Text("Open a file or folder to get started.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                ForEach(state.localFiles) { file in
                    Label(file.displayName, systemImage: "doc.text")
                        .tag(SidebarSelection.local(file.url))
                        .contextMenu {
                            Button("Remove from Sidebar") { state.removeLocalFile(file) }
                        }
                }
            }
            CollapsibleSection("Pull Requests", isExpanded: $prsExpanded) {
                if state.prSessions.isEmpty {
                    Text("Open a PR to review its Markdown changes.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                ForEach(state.prSessions) { session in
                    PRSidebarGroup(session: session)
                }
            }
            if inboxEnabled, !visibleInbox.isEmpty {
                // The unread count keeps demotion honest: collapsed or
                // scrolled away, new requests still announce themselves.
                CollapsibleSection("Review Requests", isExpanded: $inboxExpanded,
                                   badge: visibleInbox.filter(state.inboxIsUnread).count) {
                    ForEach(visibleInbox) { item in
                        InboxRow(item: item)
                    }
                }
            }
            if !recentItems.isEmpty {
                CollapsibleSection("Recent", isExpanded: $recentExpanded) {
                    ForEach(recentItems) { item in
                        RecentRow(item: item)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    /// With Markdown-only on (default), review requests PullMark can't
    /// render stay hidden; a PR whose file count is still loading shows
    /// until the count proves it Markdown-free.
    private var visibleInbox: [GitHubClient.InboxPR] {
        guard inboxMarkdownOnly else { return state.inbox }
        return state.inbox.filter { (state.inboxMDCount($0) ?? 1) > 0 }
    }

    /// Recents not already open in the sidebar.
    private var recentItems: [RecentItem] {
        state.recents.filter { item in
            switch item.kind {
            case .file:
                return !state.localFiles.contains { $0.url.path == item.path }
            case .folder:
                return true
            case .pr:
                guard let ref = item.ref else { return false }
                return !state.prSessions.contains { $0.ref == ref }
            }
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
    @ViewBuilder let content: () -> Content

    init(_ title: String, isExpanded: Binding<Bool>, badge: Int = 0,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self._isExpanded = isExpanded
        self.badge = badge
        self.content = content
    }

    private var header: some View {
        HStack {
            Text(title)
            Spacer()
            if badge > 0 {
                Text("\(badge)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(badge) unread")
            }
        }
    }

    var body: some View {
        if #available(macOS 14.0, *) {
            Section(isExpanded: $isExpanded) { content() } header: { header }
        } else {
            Section { content() } header: { header }
        }
    }
}

/// A review-requested PR: unread dot, title over repo#number, and a
/// Markdown-file badge (dimmed when the PR touches no Markdown — PullMark
/// can open it, but the reading room has nothing to show).
private struct InboxRow: View {
    @EnvironmentObject private var state: AppState
    let item: GitHubClient.InboxPR

    var body: some View {
        Button {
            state.openInboxItem(item)
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)
                    .opacity(state.inboxIsUnread(item) ? 1 : 0)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .lineLimit(1)
                        .fontWeight(state.inboxIsUnread(item) ? .semibold : .regular)
                    Text("\(item.ref.owner)/\(item.ref.repo)#\(item.ref.number)"
                        + (item.draft ? " · draft" : ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let count = state.inboxMDCount(item), count > 0 {
                    Label("\(count)", systemImage: "doc.text")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                        .help(count == 1 ? "1 Markdown file" : "\(count) Markdown files")
                }
            }
        }
        .buttonStyle(.plain)
        .help(state.inboxMDCount(item) == 0
            ? "No Markdown files in this pull request" : item.title)
    }
}

private struct RecentRow: View {
    @EnvironmentObject private var state: AppState
    let item: RecentItem

    var body: some View {
        Button {
            state.openRecent(item)
        } label: {
            Label {
                HStack(spacing: 4) {
                    Text(item.title)
                        .lineLimit(1)
                    if item.kind == .pr, let status = item.prStatus, status != .open {
                        Text(status.label)
                            .font(.caption2)
                            .foregroundStyle(status.color)
                    }
                }
            } icon: {
                switch item.kind {
                case .file:
                    Image(systemName: "doc.text")
                        .foregroundStyle(.secondary)
                case .folder:
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                case .pr:
                    let status = item.prStatus ?? .open
                    Image(systemName: status.systemImage)
                        .foregroundStyle(status.color.opacity(0.75))
                }
            }
        }
        .buttonStyle(.plain)
        .help(helpText)
        .contextMenu {
            Button("Remove from Recents") { state.removeRecent(id: item.id) }
        }
    }

    private var helpText: String {
        switch item.kind {
        case .file, .folder:
            return item.path.map { PathAbbreviator.abbreviate($0) } ?? item.title
        case .pr:
            let status = item.prStatus.map { " — \($0.label)" } ?? ""
            return "\(item.owner ?? "")/\(item.repo ?? "")#\(item.number ?? 0)\(status)"
        }
    }
}

private struct PRSidebarGroup: View {
    @EnvironmentObject private var state: AppState
    let session: PRSession
    @State private var expanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(session.markdownFiles) { file in
                Label {
                    Text(file.filename)
                        .lineLimit(1)
                        .truncationMode(.head)
                } icon: {
                    Image(systemName: icon(for: file.status))
                        .foregroundStyle(color(for: file.status))
                }
                .tag(SidebarSelection.prFile(session.id, file.filename))
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
                .tag(SidebarSelection.prDoc(session.id, path))
            }
        } label: {
            // Interpolating the Int directly would go through LocalizedStringKey
            // and render with digit grouping ("#45,206").
            let title: String = "\(session.ref.repo) #\(session.ref.number)"
            let status = PRStatus(details: session.details)
            Label {
                Text(title)
            } icon: {
                Image(systemName: status.systemImage)
                    .foregroundStyle(status.color)
            }
            .tag(SidebarSelection.prOverview(session.id))
            .help(status.label)
            .contextMenu {
                Button("Remove from Sidebar") { state.removePR(session.id) }
            }
        }
    }

    private func icon(for status: String) -> String {
        switch status {
        case "added": return "plus.circle"
        case "removed": return "minus.circle"
        case "renamed": return "arrow.right.circle"
        default: return "pencil.circle"
        }
    }

    private func color(for status: String) -> Color {
        switch status {
        case "added": return .green
        case "removed": return .red
        default: return .secondary
        }
    }
}

struct DetailView: View {
    @EnvironmentObject private var state: AppState

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
        }
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text("Open a Markdown file or a GitHub pull request")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
