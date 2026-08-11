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
    @State private var comparePresenter = MenuActionPresenter()

    private var session: RemoteRepoSession? { state.remoteSession(sessionID) }

    private var remoteContext: RemoteResourceContext? {
        guard let session, let sha = session.commitSHA else { return nil }
        return RemoteResourceContext(ref: session.ref, commitSHA: sha)
    }

    @AppStorage(DefaultsKeys.marginNotesVisible, store: UserDefaults.pullmark) private var marginNotesVisible = true

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
        // Margin notes in remote files render read-only: the bubbles show
        // (a doc annotated by its authors reads the same everywhere), but
        // there is no file on disk to write to, so no authoring chrome.
        let notes = marginNotesVisible
            ? MarginNotePayload.payloads(from: MarginNotes.parse(markdown)) : []
        return HTMLBuilder.documentPage(markdown: markdown, title: path,
                                        remote: HTMLBuilder.RemoteAssets(filePath: path),
                                        theme: style.theme,
                                        customCSS: style.customCSS,
                                        blame: blameVisible ? blamePayloads : nil,
                                        blameNote: blameVisible ? blameNote : nil,
                                        marginNotes: notes)
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
        .task(id: sessionID + "|" + path) {
            await load()
        }
        .onAppear { updateSurfaceToolbar() }
        .onDisappear {
            state.unregisterActiveDocument(id: activeDocumentID)
        }
        // The window toolbar renders from the registered snapshot — every
        // value that drives an item's enabled state re-registers.
        .onChange(of: loading) { _ in updateSurfaceToolbar() }
        .onChange(of: loadError) { _ in updateSurfaceToolbar() }
        // Toolbar Reload (View → Reload Document stays local-only).
        .modifier(DocumentCommandHandler(state: state) { _ in
            if state.take(.reload) { reloadFromOrigin() }
        })
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

    /// What the window-level toolbar (AppToolbar) shows for this surface.
    private func updateSurfaceToolbar() {
        var surface = SurfaceToolbar(id: activeDocumentID)
        if let session {
            surface.shareURL = RemoteDocLink.blobURL(owner: session.ref.owner,
                                                     repo: session.ref.repo,
                                                     ref: session.displayRef,
                                                     path: path)
            if RemoteDocLink.isCommitSHA(session.displayRef) {
                surface.reloadDisabledReason = "This document was opened at a "
                    + "specific commit — its content can't change"
            }
        }
        surface.compareAvailable = !loading && loadError == nil
        surface.compareUnavailableReason = "The document hasn't finished loading"
        surface.popCompare = { popCompareMenu(from: $0) }
        state.registerSurfaceToolbar(surface)
    }

    /// Toolbar Reload: forget the resolved commit so the branch re-resolves
    /// to its current tip, refetch the document, then refresh the browsed
    /// sidebar tree at the new commit if one was loaded. Never offered for
    /// sessions opened at a specific commit (see updateSurfaceToolbar).
    private func reloadFromOrigin() {
        guard let session, !RemoteDocLink.isCommitSHA(session.displayRef),
              !loading else { return }
        let hadTree = session.treePaths != nil
        state.unpinRemoteSession(sessionID: sessionID)
        Task {
            await load()
            if hadTree { await state.loadRemoteTree(sessionID: sessionID) }
        }
    }

    private func popCompareMenu(from view: NSView) {
        // Branches load on the first click (never on appear — opening a doc
        // shouldn't cost a branches call nobody asked for).
        if branches.isEmpty {
            guard let session else { return }
            Task {
                do {
                    branches = try await state.client.branchNames(session.ref)
                    presentCompareMenu(from: view)
                } catch {
                    state.lastError = AppState.remoteFailureMessage(
                        error, what: "branches of \(session.ref.owner)/\(session.ref.repo)")
                }
            }
        } else {
            presentCompareMenu(from: view)
        }
    }

    private func presentCompareMenu(from view: NSView) {
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

/// The branch menu every remote-repo surface pops (sidebar chip and
/// provenance bar): the branch list switches the session in place
/// (✓ current; ⌥ on any item opens that branch as a sibling Location),
/// an explicit Open Branch Separately submenu does the same discoverably,
/// and Open on GitHub rounds it out. Hand-built from live state — never a
/// SwiftUI Menu (it caches rows).
@MainActor
enum RemoteBranchMenu {
    /// Pops `menu` under `anchor`, or at the pointer when the anchor never
    /// materialized (List rows don't always realize background
    /// NSViewRepresentables) — the menu must appear either way.
    static func pop(_ menu: NSMenu, from anchor: NSView?) {
        if let anchor, anchor.window != nil {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -6), in: anchor)
        } else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    static func present(session: RemoteRepoSession, branches: [String],
                        state: AppState, anchor: NSView?,
                        presenter: MenuActionPresenter) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        var actions: [() -> Void] = []
        func item(_ title: String, checked: Bool = false,
                  alternate: Bool = false, in target: NSMenu,
                  run: @escaping () -> Void) {
            let item = NSMenuItem(title: title,
                                  action: #selector(MenuActionPresenter.fire(_:)),
                                  keyEquivalent: "")
            item.target = presenter
            item.tag = actions.count
            item.state = checked ? .on : .off
            if alternate {
                item.isAlternate = true
                item.keyEquivalentModifierMask = .option
            }
            actions.append(run)
            target.addItem(item)
        }
        func header(_ title: String, in target: NSMenu) {
            if #available(macOS 14.0, *) {
                target.addItem(NSMenuItem.sectionHeader(title: title))
            } else {
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.isEnabled = false
                target.addItem(item)
            }
        }

        let shown = branches.prefix(100)
        header(shown.count < branches.count ? "Switch To (first 100)" : "Switch To", in: menu)
        for branch in shown {
            item(branch, checked: branch == session.displayRef, in: menu) {
                state.switchRemoteSession(id: session.id, toRef: branch)
            }
            item("Open \(branch) Separately", alternate: true, in: menu) {
                Task {
                    await state.openRemoteRepo(owner: session.ref.owner, repo: session.ref.repo,
                                               refName: branch, loadTree: false)
                }
            }
        }
        menu.addItem(.separator())
        let separately = NSMenuItem(title: "Open Branch Separately", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for branch in shown where branch != session.displayRef {
            item(branch, in: submenu) {
                Task {
                    await state.openRemoteRepo(owner: session.ref.owner, repo: session.ref.repo,
                                               refName: branch, loadTree: false)
                }
            }
        }
        separately.submenu = submenu
        menu.addItem(separately)
        menu.addItem(.separator())
        item("Open on GitHub", in: menu) {
            if let url = URL(string: "https://github.com/\(session.ref.owner)/"
                + "\(session.ref.repo)/tree/\(session.displayRef)") {
                NSWorkspace.shared.open(url)
            }
        }
        presenter.actions = actions
        pop(menu, from: anchor)
    }
}

/// The compact ref control shown on repo rows and the provenance bar —
/// branch glyph + name + disclosure chevron, one click to the branch menu
/// (the Xcode-titlebar idiom brought to the row).
/// AppKit click target for controls inside List rows: SwiftUI Buttons and
/// tap gestures in a sidebar row's label never receive plain clicks (the
/// row's selection machinery wins — verified empirically), but an embedded
/// NSView's mouseDown fires before any of it. The catcher doubles as the
/// menu anchor, so the menu pops exactly under the control.
struct RowClickCatcher: NSViewRepresentable {
    final class Catcher: NSView {
        var action: () -> Void = {}
        override func mouseDown(with event: NSEvent) {
            // Not calling super: the click belongs to the control, and the
            // menu it pops would swallow the selection change anyway.
            action()
        }
    }

    let box: MenuAnchorBox
    let action: () -> Void

    func makeNSView(context: Context) -> Catcher {
        let view = Catcher()
        view.action = action
        box.view = view
        return view
    }

    func updateNSView(_ view: Catcher, context: Context) {
        view.action = action
        box.view = view
    }
}

struct BranchChip: View {
    let text: String
    /// Optional to accept ChromeFonts values (nil at zoom 1 = stock size).
    var font: Font? = .caption
    let anchor: MenuAnchorBox
    let action: () -> Void

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 8, weight: .semibold))
            Text(text)
                .lineLimit(1)
                .truncationMode(.middle)
            Image(systemName: "chevron.down")
                .font(.system(size: 6, weight: .bold))
                .opacity(0.8)
        }
        .font(font)
        .foregroundStyle(.secondary)
        .overlay(RowClickCatcher(box: anchor, action: action))
        .help("Branches and worktrees")
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Branch: \(text)")
    }
}

/// The ask dialog for GitHub Markdown links — a sheet, not an alert,
/// because it carries the Remember checkbox: checked (the default), the
/// choice becomes the standing policy; unchecked, the choice applies once
/// and the unchecked state itself is remembered for next time.
struct RemoteLinkPromptSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let prompt: RemoteLinkPrompt

    @State private var remember: Bool

    init(prompt: RemoteLinkPrompt) {
        self.prompt = prompt
        _remember = State(initialValue:
            UserDefaults.pullmark.object(forKey: DefaultsKeys.remoteLinkRemember) as? Bool ?? true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Open GitHub Markdown links in PullMark?")
                .font(.headline)
            HStack(spacing: 6) {
                Image(systemName: "book.closed")
                    .foregroundStyle(.secondary)
                Text("\(prompt.link.owner)/\(prompt.link.repo)")
                    .fontWeight(.medium)
                Text("@ \(prompt.link.ref) · \(prompt.link.path)")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.callout)
            Text("PullMark can fetch this file and render it in-app, or send it to your "
                + "browser. Hold ⌘ while clicking a link for the other behavior; the "
                + "default lives in Settings → General.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Remember my selection", isOn: $remember)
                .help("Make this choice the default for GitHub Markdown links")
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Open in Browser") {
                    state.resolveRemoteLinkPrompt(prompt, openInApp: false, remember: remember)
                    dismiss()
                }
                Button("Open in PullMark") {
                    state.resolveRemoteLinkPrompt(prompt, openInApp: true, remember: remember)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 440)
    }
}

/// The always-visible origin strip: `owner/repo @ ref · path`, plus the
/// affordance for switching to the other source (GitHub in the browser).
struct RemoteProvenanceBar: View {
    @EnvironmentObject private var state: AppState
    let session: RemoteRepoSession
    let path: String

    @State private var branches: [String] = []
    @State private var menuAnchor = MenuAnchorBox()
    @State private var menuPresenter = MenuActionPresenter()

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
        guard let view = menuAnchor.view else { return }
        RemoteBranchMenu.present(session: session, branches: branches,
                                 state: state, anchor: view, presenter: menuPresenter)
    }

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
            // The ref is the switch-branch affordance, right where it's read.
            BranchChip(text: session.displayRef, font: .callout,
                       anchor: menuAnchor) {
                popBranchMenu()
            }
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
                    .help("Pinned to commit \(sha) — the ref's tip as of this session's last fetch.")
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
