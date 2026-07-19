import SwiftUI

struct LocalFileView: View {
    @EnvironmentObject private var state: AppState
    let file: LocalFile

    @State private var currentText = ""
    @State private var watcher: FileWatcher?
    @State private var outline: [OutlineItem] = []
    @State private var activeSection: String?
    @State private var stats: DocumentStats?
    @State private var findSeed: String?
    @StateObject private var proxy = WebViewProxy()
    @AppStorage(DefaultsKeys.outlinePanel) private var outlineVisible = false
    @AppStorage(Theme.defaultsKey) private var themeRaw = Theme.github.rawValue

    // Git history / branch comparison
    struct CompareTarget: Equatable {
        let ref: String
        let label: String
    }
    @State private var inGitRepo = false
    @State private var commits: [LocalGit.Commit] = []
    @State private var branches: [String] = []
    @State private var remoteBranches: [String] = []
    @State private var compare: CompareTarget?
    @State private var compareText: String?

    // Blame annotations
    @AppStorage(DefaultsKeys.blame) private var blameVisible = false
    @State private var blamePayloads: [BlameRunPayload]?
    @State private var blameNote: String?
    @State private var historyRequest: BlameHistoryRequest?

    var body: some View {
        VStack(spacing: 0) {
            if let compare {
                HStack(spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath")
                    Text("Comparing with \(compare.label)")
                    Spacer()
                    Button("Done") { stopComparing() }
                }
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.blue.opacity(0.14))
            }
            if state.findBarVisible {
                FindBar(proxy: proxy, seed: $findSeed)
            }
            HSplitView {
                MarkdownWebView(
                    html: html,
                    localResourceRoot: file.resourceRoot,
                    onOpenLocalFile: { url in state.add(url: url) },
                    onOutline: { outline = $0 },
                    onActiveSection: { activeSection = $0.isEmpty ? nil : $0 },
                    onBlameHistory: { start, end in
                        historyRequest = BlameHistoryRequest(lineStart: start, lineEnd: end)
                    },
                    onStats: { stats = $0 },
                    onPageLoaded: { handlePageLoaded() },
                    proxy: proxy
                )
                .overlay(alignment: .bottomTrailing) {
                    if compare == nil, let stats {
                        DocumentStatsPill(stats: stats)
                    }
                }
                .layoutPriority(1)
                if outlineVisible {
                    OutlineSidebar(items: outline, proxy: proxy, activeID: activeSection)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .navigationTitle(file.url.lastPathComponent)
        .navigationSubtitle(PathAbbreviator.abbreviate(file.url.deletingLastPathComponent().path))
        .toolbar {
            ToolbarItem {
                compareMenu
            }
            // No git context, no Blame button: the toggle only appears for
            // files inside a repository.
            if inGitRepo {
                ToolbarItem {
                    BlameToggle(visible: $blameVisible)
                        .disabled(compare != nil)
                }
            }
            ToolbarItem {
                OutlineToggle(visible: $outlineVisible)
            }
            ToolbarItem {
                Button {
                    load()
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                .help("Reload from disk")
            }
        }
        .onAppear {
            load()
            loadGitInfo()
            watcher = FileWatcher(url: file.url) { load() }
            updateActiveDocument()
        }
        .onDisappear {
            watcher = nil
            state.unregisterActiveDocument(id: activeDocumentID)
        }
        .onChange(of: blameVisible) { _ in loadBlame() }
        .onChange(of: currentText) { _ in
            loadBlame()
            updateActiveDocument()
        }
        .onChange(of: inGitRepo) { _ in loadBlame() }
        .onChange(of: compare) { _ in updateActiveDocument() }
        .modifier(PendingSearchConsumer(target: .local(file.url),
                                        consume: consumePendingSearch))
        .sheet(item: $historyRequest) { request in
            BlameHistorySheet {
                await BlameService.localHistory(client: state.client, fileURL: file.url,
                                                lineStart: request.lineStart,
                                                lineEnd: request.lineEnd)
            }
        }
    }

    @ViewBuilder
    private var compareMenu: some View {
        Menu {
            if !commits.isEmpty {
                Section("History") {
                    ForEach(commits) { commit in
                        Button("\(commit.shortSHA) · \(commit.date) · \(commit.subject)") {
                            startComparing(ref: commit.sha,
                                           label: "\(commit.shortSHA) (\(commit.date))")
                        }
                    }
                }
            }
            if !branches.isEmpty {
                Section("Branches") {
                    ForEach(branches, id: \.self) { branch in
                        Button(branch) { startComparing(ref: branch, label: branch) }
                    }
                }
            }
            if !remoteBranches.isEmpty {
                Section("Remote Branches") {
                    ForEach(remoteBranches, id: \.self) { branch in
                        Button(branch) { startComparing(ref: branch, label: branch) }
                    }
                }
            }
            if compare != nil {
                Divider()
                Button("Stop Comparing") { stopComparing() }
            }
        } label: {
            Label("Compare", systemImage: "clock.arrow.circlepath")
        }
        .disabled(!inGitRepo)
        .help(inGitRepo ? "Compare with a previous revision or branch"
                        : "Not inside a git repository")
    }

    private var html: String {
        let style = ThemeSelection.pageStyle(from: themeRaw)
        if compare != nil, let compareText {
            let segments = DiffPageBuilder.segments(old: compareText, new: currentText)
            return HTMLBuilder.diffPage(segments: segments, commentable: false,
                                        title: file.url.lastPathComponent,
                                        theme: style.theme,
                                        customCSS: style.customCSS)
        }
        if state.sourceViewVisible {
            return HTMLBuilder.sourcePage(markdown: currentText,
                                          title: file.url.lastPathComponent,
                                          theme: style.theme,
                                          customCSS: style.customCSS)
        }
        return HTMLBuilder.documentPage(markdown: currentText,
                                        title: file.url.lastPathComponent,
                                        localResources: true,
                                        theme: style.theme,
                                        customCSS: style.customCSS,
                                        blame: blameVisible ? blamePayloads : nil,
                                        blameNote: blameVisible ? blameNote : nil)
    }

    private var activeDocumentID: String { "local:" + file.url.path }

    /// Export and Copy-as-Markdown target rendered documents, not diffs:
    /// while a comparison is showing the registration is dropped.
    private func updateActiveDocument() {
        guard compare == nil else {
            state.unregisterActiveDocument(id: activeDocumentID)
            return
        }
        state.registerActiveDocument(ActiveDocument(
            id: activeDocumentID,
            exportBaseName: file.url.deletingPathExtension().lastPathComponent,
            markdown: currentText,
            proxy: proxy,
            localRoot: file.resourceRoot
        ))
    }

    private func handlePageLoaded() {
        if state.pendingSearchQuery != nil {
            consumePendingSearch()
        } else if state.findBarVisible, let query = proxy.activeFindQuery {
            // The page reloaded under an active find (e.g. blame arrived and
            // re-rendered the document): restore highlights and counts.
            findSeed = query
        }
    }

    /// Query handed over by the all-files search palette: show the find bar
    /// seeded with it so the term is highlighted and scrolled into view.
    private func consumePendingSearch() {
        guard let query = state.pendingSearchQuery else { return }
        state.pendingSearchQuery = nil
        findSeed = query
        state.findBarVisible = true
    }

    private func load() {
        do {
            currentText = try String(contentsOf: file.url, encoding: .utf8)
        } catch {
            currentText = "> [!CAUTION]\n> Could not read `\(PathAbbreviator.abbreviate(file.url.path))`: \(error.localizedDescription)"
        }
    }

    private func loadGitInfo() {
        let url = file.url
        Task.detached(priority: .utility) {
            guard let root = LocalGit.repoRoot(for: url) else { return }
            let commits = LocalGit.history(of: url)
            let branches = LocalGit.branches(in: root, remote: false)
            let remotes = LocalGit.branches(in: root, remote: true)
            await MainActor.run {
                self.inGitRepo = true
                self.commits = commits
                self.branches = branches
                self.remoteBranches = remotes
            }
        }
    }

    private func loadBlame() {
        guard blameVisible, inGitRepo else { return }
        let url = file.url
        let text = currentText
        Task {
            let payloads = await BlameService.localPayloads(client: state.client,
                                                            fileURL: url, markdown: text)
            // The file may have been edited while blame was computed.
            guard text == currentText else { return }
            blamePayloads = payloads
            blameNote = payloads == nil
                ? "Blame unavailable — the file is not tracked by git." : nil
        }
    }

    private func startComparing(ref: String, label: String) {
        let url = file.url
        Task.detached(priority: .userInitiated) {
            let old = LocalGit.content(of: url, at: ref)
            await MainActor.run {
                guard let old else {
                    state.lastError = "\(url.lastPathComponent) does not exist at \(label)."
                    return
                }
                compareText = old
                compare = CompareTarget(ref: ref, label: label)
            }
        }
    }

    private func stopComparing() {
        compare = nil
        compareText = nil
    }
}
