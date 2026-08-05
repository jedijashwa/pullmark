import SwiftUI

/// A Markdown document read straight from a GitHub repo (no PR involved).
/// Rendering matches PRDocView; what's new is provenance: the bar above the
/// content always says which repo@ref the text came from — never a hover —
/// and doubles as the way back to GitHub.
struct RemoteDocView: View {
    @EnvironmentObject private var state: AppState
    let sessionID: String
    let path: String

    @State private var markdown = ""
    @State private var loading = true
    @State private var loadError: String?
    @State private var outline: [OutlineItem] = []
    @State private var activeSection: String?
    @State private var stats: DocumentStats?
    @State private var findSeed: String?
    @StateObject private var proxy = WebViewProxy()
    @AppStorage(DefaultsKeys.outlinePanel, store: UserDefaults.pullmark) private var outlineVisible = false
    @AppStorage(Theme.defaultsKey, store: UserDefaults.pullmark) private var themeRaw = Theme.standard.rawValue
    @AppStorage(DefaultsKeys.blame, store: UserDefaults.pullmark) private var blameVisible = false
    @State private var blamePayloads: [BlameRunPayload]?
    @State private var blameNote: String?
    @State private var historyRequest: BlameHistoryRequest?

    // Branch comparison: the same document fetched at another branch,
    // rendered as the usual block diff (other branch = old, this = new).
    private struct RemoteCompare: Equatable {
        let ref: String
        let label: String
    }
    @State private var compare: RemoteCompare?
    @State private var compareText: String?
    @State private var compareGeneration = 0
    @State private var branches: [String] = []
    @State private var compareAnchor = MenuAnchorBox()
    @State private var comparePresenter = MenuActionPresenter()

    private var session: RemoteRepoSession? { state.remoteSession(sessionID) }

    private var remoteContext: RemoteResourceContext? {
        guard let session, let sha = session.commitSHA else { return nil }
        return RemoteResourceContext(ref: session.ref, commitSHA: sha)
    }

    private var html: String {
        let style = ThemeSelection.pageStyle(from: themeRaw)
        if compare != nil, let compareText {
            let segments = DiffPageBuilder.segments(old: compareText, new: markdown)
            return HTMLBuilder.diffPage(segments: segments,
                                        remote: HTMLBuilder.RemoteAssets(filePath: path),
                                        commentable: false,
                                        title: path,
                                        theme: style.theme,
                                        customCSS: style.customCSS)
        }
        if state.sourceViewVisible {
            return HTMLBuilder.sourcePage(markdown: markdown, title: path,
                                          theme: style.theme,
                                          customCSS: style.customCSS)
        }
        return HTMLBuilder.documentPage(markdown: markdown, title: path,
                                        remote: HTMLBuilder.RemoteAssets(filePath: path),
                                        theme: style.theme,
                                        customCSS: style.customCSS,
                                        blame: blameVisible ? blamePayloads : nil,
                                        blameNote: blameVisible ? blameNote : nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let session {
                RemoteProvenanceBar(session: session, path: path)
            }
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
            if loading {
                ProgressView("Loading \(path)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 36))
                        .foregroundStyle(.orange)
                    Text(loadError)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 480)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    MarkdownWebView(
                        html: html,
                        remoteContext: remoteContext,
                        onOpenRemoteFile: { repoPath in
                            state.openRemoteSessionDoc(sessionID: sessionID, path: repoPath)
                        },
                        onOpenGitHubLink: { link, url, inverted in
                            state.handleGitHubLink(link, url: url, inverted: inverted)
                        },
                        onOutline: { outline = $0 },
                        onActiveSection: { activeSection = $0.isEmpty ? nil : $0 },
                        onBlameHistory: { start, end in
                            historyRequest = BlameHistoryRequest(lineStart: start, lineEnd: end)
                        },
                        onStats: { stats = $0 },
                        onPageLoaded: { handlePageLoaded() },
                        onLightboxRequest: { presentLightbox($0, proxy: proxy, state: state) },
                        proxy: proxy
                    )
                    .modifier(PagePreferenceApplier(proxy: proxy))
                    .overlay(alignment: .bottomTrailing) {
                        if state.lightbox == nil, let stats {
                            DocumentStatsPill(stats: stats)
                        }
                    }
                    .overlay {
                        if let content = state.lightbox {
                            LightboxModal(content: content,
                                          onContentFrame: { proxy.setInspectRegion($0) },
                                          onUIHover: { proxy.setInspectUIHover($0) }) {
                                state.lightbox = nil
                                proxy.setInspecting(false)
                            }
                            .id(content.id)
                        }
                    }
                    .layoutPriority(1)
                    if outlineVisible, state.lightbox == nil {
                        OutlineSidebar(items: outline, proxy: proxy, activeID: activeSection)
                    }
                }
                .background(ThemePaper.color(for: themeRaw))
            }
        }
        .navigationTitle(path)
        .toolbar {
            ToolbarItem {
                compareMenu
            }
            ToolbarItem {
                BlameToggle(visible: $blameVisible)
            }
            ToolbarItem {
                OutlineToggle(visible: $outlineVisible)
            }
        }
        .task(id: sessionID + "|" + path) {
            await load()
        }
        .onDisappear {
            state.unregisterActiveDocument(id: activeDocumentID)
        }
        .onChange(of: blameVisible) { _ in loadBlameIfNeeded() }
        .onChange(of: state.remoteAnchor) { anchor in
            // A link to a different heading of the doc already on screen —
            // no reload happens, so consume the anchor here.
            guard let anchor, anchor.sessionID == sessionID, anchor.path == path,
                  !loading else { return }
            state.remoteAnchor = nil
            proxy.scrollToAnchor(anchor.fragment)
        }
        .modifier(PendingSearchConsumer(target: .remoteDoc(sessionID, path),
                                        consume: consumePendingSearch))
        .sheet(item: $historyRequest) { _ in
            let ref = session?.ref
            let sha = session?.commitSHA
            BlameHistorySheet {
                guard let ref, let sha else {
                    throw GitHubClient.APIError(status: -1, message: "The repository session is no longer available.")
                }
                return try await BlameService.remoteHistory(client: state.client, ref: ref,
                                                            path: path, sha: sha)
            }
        }
    }

    /// Hand-built NSMenu (never a SwiftUI toolbar Menu — it caches rows
    /// bridged for earlier state; same rule as the local compare menu).
    private var compareMenu: some View {
        Button {
            popCompareMenu()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "clock.arrow.circlepath")
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .opacity(0.8)
            }
        }
        .accessibilityLabel("Compare")
        .background(MenuAnchorReader(box: compareAnchor))
        .disabled(loading || loadError != nil)
        .help("Compare with another branch")
    }

    private func popCompareMenu() {
        // Branches load on the first click (never on appear — opening a doc
        // shouldn't cost a branches call nobody asked for).
        if branches.isEmpty {
            guard let session else { return }
            Task {
                do {
                    branches = try await state.client.branchNames(session.ref)
                    presentCompareMenu()
                } catch {
                    state.lastError = AppState.remoteFailureMessage(
                        error, what: "branches of \(session.ref.owner)/\(session.ref.repo)")
                }
            }
        } else {
            presentCompareMenu()
        }
    }

    private func presentCompareMenu() {
        guard let view = compareAnchor.view else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        var actions: [() -> Void] = []
        func addHeader(_ title: String) {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            if #available(macOS 14.0, *) {
                menu.addItem(NSMenuItem.sectionHeader(title: title))
            } else {
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
        }
        func addAction(_ title: String, _ run: @escaping () -> Void) {
            let item = NSMenuItem(title: title,
                                  action: #selector(MenuActionPresenter.fire(_:)),
                                  keyEquivalent: "")
            item.target = comparePresenter
            item.tag = actions.count
            actions.append(run)
            menu.addItem(item)
        }
        let others = branches.filter { $0 != session?.displayRef }
        if !others.isEmpty {
            addHeader(others.count >= 100 ? "Branches (first 100)" : "Branches")
            for branch in others.prefix(100) {
                addAction(branch) { startComparing(ref: branch, label: branch) }
            }
        } else {
            addHeader("No other branches")
        }
        if compare != nil {
            menu.addItem(.separator())
            addAction("Stop Comparing") { stopComparing() }
        }
        comparePresenter.actions = actions
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -6), in: view)
    }

    private func startComparing(ref: String, label: String) {
        guard let session else { return }
        compareGeneration += 1
        let generation = compareGeneration
        Task {
            do {
                // The contents API takes a branch name directly — the other
                // side always reads that branch's current tip.
                let old = try await state.client.fileContent(session.ref, path: path, at: ref)
                guard generation == compareGeneration else { return }
                compareText = old
                compare = RemoteCompare(ref: ref, label: label)
            } catch {
                guard generation == compareGeneration else { return }
                state.lastError = "\((path as NSString).lastPathComponent) isn't available on \(label): "
                    + error.localizedDescription
            }
        }
    }

    private func stopComparing() {
        compare = nil
        compareText = nil
    }

    private func handlePageLoaded() {
        if let anchor = state.remoteAnchor, anchor.sessionID == sessionID, anchor.path == path {
            state.remoteAnchor = nil
            proxy.scrollToAnchor(anchor.fragment)
        }
        if state.pendingSearchQuery != nil {
            consumePendingSearch()
        } else if state.findBarVisible, let query = proxy.activeFindQuery {
            findSeed = query
        }
    }

    private func consumePendingSearch() {
        guard let query = state.pendingSearchQuery else { return }
        state.pendingSearchQuery = nil
        findSeed = query
        state.findBarVisible = true
    }

    private func loadBlameIfNeeded() {
        guard blameVisible, let session, let sha = session.commitSHA, !markdown.isEmpty,
              blamePayloads == nil, blameNote == nil else { return }
        let ref = session.ref
        let path = path
        let text = markdown
        Task {
            do {
                blamePayloads = try await BlameService.remotePayloads(
                    client: state.client, ref: ref, path: path, sha: sha, markdown: text)
            } catch {
                blameNote = "Blame unavailable — \(error.localizedDescription)"
            }
        }
    }

    private func load() async {
        guard session != nil else { return }
        loading = true
        loadError = nil
        blamePayloads = nil
        blameNote = nil
        do {
            let sha = try await state.ensureRemoteSHA(sessionID: sessionID)
            guard let session else { return }
            markdown = try await state.client.fileContent(session.ref, path: path, at: sha)
            // Feed the all-files search palette (memory-only cache).
            state.cachePRContent(sessionID: sessionID, path: path, text: markdown)
        } catch {
            loadError = AppState.remoteFailureMessage(error, what: path)
        }
        loading = false
        loadBlameIfNeeded()
        updateActiveDocument()
    }

    private var activeDocumentID: String { "remoteDoc:" + sessionID + "|" + path }

    private func updateActiveDocument() {
        guard !loading, loadError == nil else {
            state.unregisterActiveDocument(id: activeDocumentID)
            return
        }
        state.registerActiveDocument(ActiveDocument(
            id: activeDocumentID,
            exportBaseName: ((path as NSString).lastPathComponent as NSString).deletingPathExtension,
            markdown: markdown,
            proxy: proxy,
            remoteContext: remoteContext
        ))
    }
}

/// The always-visible origin strip: `owner/repo @ ref · path`, plus the
/// affordance for switching to the other source (GitHub in the browser).
struct RemoteProvenanceBar: View {
    let session: RemoteRepoSession
    let path: String

    private var blobURL: URL? {
        URL(string: "https://github.com/\(session.ref.owner)/\(session.ref.repo)"
            + "/blob/\(session.displayRef)/"
            + path.split(separator: "/").map { String($0).addingPercentEncoding(
                withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/"))
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "book.closed")
                .foregroundStyle(.secondary)
            Text("\(session.ref.owner)/\(session.ref.repo)")
                .fontWeight(.medium)
            Text("@ \(session.displayRef)")
                .foregroundStyle(.secondary)
            Text("·")
                .foregroundStyle(.tertiary)
            Text(path)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            if let sha = session.commitSHA {
                Text(String(sha.prefix(7)))
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .help("Pinned to commit \(sha) — the ref was resolved when this session opened.")
            }
            Spacer()
            if let blobURL {
                Button("Open on GitHub") {
                    NSWorkspace.shared.open(blobURL)
                }
                .buttonStyle(.link)
                .font(.callout)
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Document from GitHub: \(session.ref.owner)/\(session.ref.repo) at \(session.displayRef), \(path)")
    }
}
