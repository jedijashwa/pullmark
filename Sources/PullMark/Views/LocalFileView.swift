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
    @State private var currentBranch: String?
    @State private var didRestorePosition = false
    /// in-place edit mode: reading is the default; the toolbar pencil
    /// (⌘E) makes the page writable — click any block to reveal its source.
    @State private var editMode = false
    @State private var remoteBranches: [String] = []
    @State private var compare: CompareTarget?
    @State private var compareText: String?
    @State private var compareGeneration = 0
    /// An in-place editor is open: re-renders are deferred (a reload would
    /// destroy the draft mid-typing).
    @State private var inlineEditing = false
    @State private var reloadDeferred = false
    /// Scroll fraction to restore after an intentional re-render (an edit
    /// save or an external file change) — reloads land at the top otherwise.
    @State private var pendingScrollRestore: Double?
    /// Arrow navigation across a commit: reveal here after the reload.
    @State private var pendingRevealLine: Int?

    // Blame annotations
    @AppStorage(DefaultsKeys.blame) private var blameVisible = false
    @State private var blamePayloads: [BlameRunPayload]?
    @State private var blameNote: String?
    @State private var historyRequest: BlameHistoryRequest?

    private var documentWebView: MarkdownWebView {
        MarkdownWebView(
            html: html,
            onEditLocal: handleEditLocal,
            onEditingState: handleEditingState,
            onNextReveal: handleNextReveal,
            localResourceRoot: file.resourceRoot,
            onOpenLocalFile: handleOpenLocalFile,
            onOutline: handleOutline,
            onActiveSection: handleActiveSection,
            onBlameHistory: handleBlameHistory,
            onStats: handleStats,
            onPageLoaded: handlePageLoaded,
            proxy: proxy
        )
    }

    private var contentSplit: some View {
        HSplitView {
            documentWebView
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

    @ViewBuilder
    private var compareBanner: some View {
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
    }

    var body: some View {
        VStack(spacing: 0) {
            compareBanner
            if state.findBarVisible {
                FindBar(proxy: proxy, seed: $findSeed)
            }
            contentSplit
        }
        .background(Color(nsColor: .textBackgroundColor))
        .navigationTitle(file.url.lastPathComponent)
        .navigationSubtitle(subtitle)
        // The platform dirty indicator (dot in the close button) — subtitle
        // text alone is too quiet for unsaved manual-mode edits.
        .onAppear { NSApp.mainWindow?.isDocumentEdited = state.editedText[file.url] != nil }
        .onChange(of: state.editedText[file.url] != nil) { dirty in
            NSApp.mainWindow?.isDocumentEdited = dirty
        }
        // Overlay changes must re-register: export and Copy-as-Markdown
        // read ActiveDocument.markdown, and line ranges shift with edits.
        .onChange(of: state.editedText[file.url]) { _ in updateActiveDocument() }
        .onDisappear { saveReadingPosition() }
        .toolbar { toolbarItems }
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

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
            ToolbarItem { editToggle }
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

    private var editToggle: some View {
        Toggle(isOn: Binding(
            get: { editMode },
            set: { newValue in
                // Commit any open reveal FIRST (the flip re-renders the
                // page — an uncommitted draft would die with it), keep the
                // scroll position, and force-release the reload deferral:
                // the torn-down page can never post editingState itself.
                proxy.commitInlineEdit()
                proxy.scrollFraction { fraction in
                    Task { @MainActor in
                        if let fraction, fraction > 0.02 { pendingScrollRestore = fraction }
                        editMode = newValue
                        handleEditingState(false)
                    }
                }
            })) {
            Label("Edit", systemImage: "pencil")
        }
        .keyboardShortcut("e")
        .help(editMode ? "Done editing (⌘E)"
                       : "Edit this document (⌘E) — then click any block")
        .disabled(compare != nil || state.sourceViewVisible)
    }

    @ViewBuilder
    private var compareMenu: some View {
        Menu {
            if !commits.isEmpty {
                Section(commits.count >= 25 ? "History (25 most recent)" : "History") {
                    ForEach(commits) { commit in
                        Button("\(commit.shortSHA) · \(commit.date) · \(commit.subject)") {
                            startComparing(ref: commit.sha,
                                           label: "\(commit.shortSHA) (\(commit.date))")
                        }
                    }
                }
            }
            if !branches.isEmpty {
                Section(branches.count >= 20 ? "Recent Branches" : "Branches") {
                    ForEach(branches, id: \.self) { branch in
                        Button(branch) { startComparing(ref: branch, label: branch) }
                    }
                }
            }
            if !remoteBranches.isEmpty {
                Section(remoteBranches.count >= 20 ? "Recent Remote Branches" : "Remote Branches") {
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

    /// Unsaved manual-mode edits win over the on-disk text everywhere the
    /// document is shown, exported, or copied.
    private var displayText: String { state.editedText[file.url] ?? currentText }

    /// "~/Code/pullmark · main · edited" — folder, branch, and unsaved-edit
    /// state in the titlebar, where the eye already goes for context.
    private var subtitle: String {
        var parts = PathAbbreviator.abbreviate(file.url.deletingLastPathComponent().path)
        if let currentBranch { parts += " · \(currentBranch)" }
        if editMode { parts += " · editing" }
        if state.editedText[file.url] != nil { parts += " · edited" }
        return parts
    }

    /// In-place editor commit from the page. The seed is the text the
    /// editor was opened with — applyBlockEdit's guard compares it against
    /// the current lines, so a file changed underneath still aborts.
    private func handleOpenLocalFile(_ url: URL) { state.add(url: url) }
    private func handleOutline(_ items: [OutlineItem]) { outline = items }
    private func handleStats(_ documentStats: DocumentStats) { stats = documentStats }
    private func handleBlameHistory(_ start: Int, _ end: Int) {
        historyRequest = BlameHistoryRequest(lineStart: start, lineEnd: end)
    }
    private func handleActiveSection(_ id: String) {
        activeSection = id.isEmpty ? nil : id
        // Scroll-spy doubles as a progress heartbeat, so a plain ⌘Q (no
        // onDisappear) still keeps the spot.
        throttledPositionSave()
    }

    private func handleNextReveal(_ line: Int) {
        pendingRevealLine = line
    }

    private func handleEditingState(_ active: Bool) {
        inlineEditing = active
        if !active, reloadDeferred {
            reloadDeferred = false
            load()
        }
    }

    private func handleEditLocal(_ start: Int, _ end: Int, seed: String, replacement: String) {
        proxy.scrollFraction { fraction in
            Task { @MainActor in
                if let fraction, fraction > 0.02 { pendingScrollRestore = fraction }
                applyBlockEdit(BlockEditTarget(lineStart: start, lineEnd: end, seed: seed),
                               replacement: replacement)
            }
        }
    }

    private var html: String {
        let style = ThemeSelection.pageStyle(from: themeRaw)
        if compare != nil, let compareText {
            let segments = DiffPageBuilder.segments(old: compareText, new: displayText)
            return HTMLBuilder.diffPage(segments: segments, commentable: false,
                                        title: file.url.lastPathComponent,
                                        theme: style.theme,
                                        customCSS: style.customCSS)
        }
        if state.sourceViewVisible {
            return HTMLBuilder.sourcePage(markdown: displayText,
                                          title: file.url.lastPathComponent,
                                          theme: style.theme,
                                          customCSS: style.customCSS)
        }
        return HTMLBuilder.documentPage(markdown: displayText,
                                        title: file.url.lastPathComponent,
                                        localResources: true,
                                        theme: style.theme,
                                        customCSS: style.customCSS,
                                        editable: editMode,
                                        autosave: UserDefaults.standard
                                            .object(forKey: DefaultsKeys.autosaveEdits) as? Bool ?? true,
                                        blame: blameVisible ? blamePayloads : nil,
                                        blameNote: blameVisible ? blameNote : nil)
    }

    /// Block-editor apply: autosave writes straight to disk (the watcher
    /// re-renders); manual mode parks the result in the AppState overlay
    /// until ⌘S.
    private func applyBlockEdit(_ target: BlockEditTarget, replacement: String) {
        // Optimistic concurrency: if the file changed underneath the open
        // editor (another editor, an agent), the seed no longer matches its
        // line range — abort rather than splice into the wrong lines.
        guard TextLines.lines(in: displayText, from: target.lineStart, to: target.lineEnd)
                == target.seed else {
            state.lastNotice = "\(file.url.lastPathComponent) changed while you were editing "
                + "this block — nothing was saved. Re-open the block to edit the current version."
            pendingRevealLine = nil  // a refused save must not leave a
            proxy.cancelInlineEdit() // reveal armed for a later reload
            return
        }
        guard let newText = TextLines.replacing(in: displayText,
                                                from: target.lineStart,
                                                to: target.lineEnd,
                                                with: replacement) else {
            pendingRevealLine = nil
            proxy.cancelInlineEdit()
            return
        }
        if UserDefaults.standard.object(forKey: DefaultsKeys.autosaveEdits) as? Bool ?? true {
            if state.editedText[file.url] != nil {
                // Manual-mode leftovers plus autosave: route through the
                // guarded save so the disk-changed-underneath confirmation
                // still runs (and the overlay/base clear together).
                state.editedText[file.url] = newText
                state.saveEdits(for: file.url)
                return
            }
            do {
                EditHistory.snapshot(file.url)
                try newText.write(to: file.url, atomically: true, encoding: .utf8)
                state.editedText[file.url] = nil
                state.editedBase[file.url] = nil
            } catch {
                state.lastError = "Couldn't save \(file.url.lastPathComponent): \(error.localizedDescription)"
                proxy.cancelInlineEdit()
            }
        } else {
            // First overlay for this file: remember the disk text it was
            // based on, so ⌘S can detect a collision before overwriting.
            if state.editedText[file.url] == nil {
                state.editedBase[file.url] = currentText
            }
            state.editedText[file.url] = newText
        }
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
            // The overlay, not the disk text — export and ⌥⌘C must match
            // what the page is actually rendering.
            markdown: displayText,
            proxy: proxy,
            localRoot: file.resourceRoot
        ))
    }

    private func handlePageLoaded() {
        if let line = pendingRevealLine {
            pendingRevealLine = nil
            proxy.revealAtLine(line)
        }
        if let fraction = pendingScrollRestore {
            // An edit save or external change re-rendered the page — put
            // the reader back where they were.
            pendingScrollRestore = nil
            proxy.restoreScrollFraction(fraction)
            didRestorePosition = true
            return
        }
        if state.pendingSearchQuery != nil {
            consumePendingSearch()
        } else if state.findBarVisible, let query = proxy.activeFindQuery {
            // The page reloaded under an active find (e.g. blame arrived and
            // re-rendered the document): restore highlights and counts.
            findSeed = query
        } else if !didRestorePosition, compare == nil,
                  let fraction = ReadingPositions.fraction(for: activeDocumentID) {
            // First load only — blame/edit re-renders must not yank the
            // reader back to a stale position.
            proxy.restoreScrollFraction(fraction)
        }
        didRestorePosition = true
    }

    @State private var lastPositionSave = Date.distantPast

    private func throttledPositionSave() {
        guard Date().timeIntervalSince(lastPositionSave) > 5 else { return }
        lastPositionSave = Date()
        saveReadingPosition()
    }

    private func saveReadingPosition() {
        guard compare == nil else { return }
        let key = activeDocumentID
        proxy.scrollFraction { fraction in
            guard let fraction else { return }
            Task { @MainActor in ReadingPositions.save(fraction, for: key) }
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
        // A reload while an in-place editor is open would destroy the
        // draft — hold it until the editor closes.
        if inlineEditing {
            reloadDeferred = true
            return
        }
        // Keep the reader's place across the re-render (async capture from
        // the still-loaded page; the restore happens on the next load).
        proxy.scrollFraction { fraction in
            if let fraction, fraction > 0.02 {
                Task { @MainActor in pendingScrollRestore = fraction }
            }
        }
        do {
            currentText = try String(contentsOf: file.url, encoding: .utf8)
        } catch {
            currentText = "> [!CAUTION]\n> Could not read `\(PathAbbreviator.abbreviate(file.url.path))`: \(error.localizedDescription)"
        }
        // Heads-up the moment the underlying file diverges from what an
        // unsaved overlay was based on (another editor, an agent) — ⌘S
        // will also require explicit confirmation before overwriting.
        if state.editedText[file.url] != nil,
           let base = state.editedBase[file.url], currentText != base {
            state.lastNotice = "\(file.url.lastPathComponent) changed on disk while you have "
                + "unsaved edits. Saving (⌘S) will ask before overwriting."
        }
    }

    private func loadGitInfo() {
        let url = file.url
        Task.detached(priority: .utility) {
            guard let root = LocalGit.repoRoot(for: url) else { return }
            let commits = LocalGit.history(of: url)
            let branches = LocalGit.branches(in: root, remote: false)
            let remotes = LocalGit.branches(in: root, remote: true)
            let current = LocalGit.currentBranch(in: root)
            await MainActor.run {
                self.inGitRepo = true
                self.commits = commits
                self.branches = branches
                self.remoteBranches = remotes
                self.currentBranch = current
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
        compareGeneration += 1
        let generation = compareGeneration
        Task.detached(priority: .userInitiated) {
            let old = LocalGit.content(of: url, at: ref)
            await MainActor.run {
                // Scrubbing fires these faster than git answers — only the
                // newest request may land, or the page and banner disagree.
                guard generation == compareGeneration else { return }
                guard let old else {
                    state.lastError = "\(url.lastPathComponent) does not exist at \(label)."
                    stopComparing()
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
