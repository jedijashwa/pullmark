import SwiftUI

/// A block region picked for in-place editing: 1-based inclusive source
/// lines plus the text the editor started from (the commit's seed guard).
struct BlockEditTarget: Identifiable {
    let id = UUID()
    let lineStart: Int
    let lineEnd: Int
    let seed: String
}

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
    @ObservedObject private var shortcuts = ShortcutStore.shared
    @AppStorage(DefaultsKeys.outlinePanel, store: UserDefaults.pullmark) private var outlineVisible = false
    @AppStorage(Theme.defaultsKey, store: UserDefaults.pullmark) private var themeRaw = Theme.standard.rawValue
    @AppStorage(DefaultsKeys.marginNotesVisible, store: UserDefaults.pullmark) private var marginNotesVisible = true
    @AppStorage(DefaultsKeys.marginNotesEnabled, store: UserDefaults.pullmark) private var marginNotesEnabled = false

    // Git history / branch comparison
    struct CompareTarget: Equatable {
        let ref: String
        let label: String
        /// Set when the NEW side is frozen too (two revisions, not
        /// working-file-vs-revision) — the banner names both sides.
        var newLabel: String? = nil
    }
    @State private var comparePresenter = MenuActionPresenter()
    @State private var inGitRepo = false
    @State private var commits: [LocalGit.Commit] = []
    @State private var branches: [String] = []
    @State private var currentBranch: String?
    @State private var didRestorePosition = false
    /// In-place edit mode: reading is the default; the toolbar pencil
    /// (⌘E) makes the page writable — click any block to reveal its source.
    @State private var editMode = false
    @State private var remoteBranches: [String] = []
    @State private var tags: [String] = []
    /// Working file differs from HEAD — the Compare button's quiet dot.
    @State private var hasHeadChanges = false
    @State private var compare: CompareTarget?
    @State private var compareText: String?
    /// Frozen new-side contents (two-revision compares); nil means the
    /// new side is the live working file.
    @State private var compareNewText: String?
    @State private var compareGeneration = 0
    /// The Compare menu's "Compare Revisions…" sheet.
    @State private var revisionsSheetShown = false
    /// An in-place editor is open: re-renders are deferred (a reload would
    /// destroy the draft mid-typing).
    @State private var inlineEditing = false
    @State private var reloadDeferred = false
    /// Scroll fraction to restore after an intentional re-render (an edit
    /// save or an external file change) — reloads land at the top otherwise.
    @State private var pendingScrollRestore: Double?
    /// Arrow navigation across a commit: reveal here after the reload.
    @State private var pendingRevealLine: Int?
    /// Autosave takes ONE history snapshot per edit-mode session — a
    /// 25-block editing walk must not churn the whole 20-snapshot Revert
    /// history with intermediate states.
    @State private var sessionSnapshotTaken = false
    /// ⌘E just enabled edit mode: auto-reveal once the editable page loads.
    @State private var pendingAutoReveal = false

    // Blame annotations
    @AppStorage(DefaultsKeys.blame, store: UserDefaults.pullmark) private var blameVisible = false
    @State private var blamePayloads: [BlameRunPayload]?
    @State private var blameNote: String?
    @State private var historyRequest: BlameHistoryRequest?

    private var documentWebView: MarkdownWebView {
        MarkdownWebView(
            html: html,
            onEditLocal: handleEditLocal,
            onEditingState: handleEditingState,
            onNoteAdd: handleNoteAdd,
            onNoteEdit: handleNoteEdit,
            onNoteDelete: handleNoteDelete,
            onNextReveal: handleNextReveal,
            localResourceRoot: file.resourceRoot,
            onOpenLocalFile: handleOpenLocalFile,
            onLocalLinkFailed: { state.lastNotice = $0 },
            onOpenGitHubLink: { link, url, inverted in
                state.handleGitHubLink(link, url: url, inverted: inverted)
            },
            onOutline: handleOutline,
            onActiveSection: handleActiveSection,
            onBlameHistory: handleBlameHistory,
            onStats: handleStats,
            onPageLoaded: handlePageLoaded,
            onLightboxRequest: { presentLightbox($0, proxy: proxy, state: state) },
            proxy: proxy
        )
    }

    private var contentSplit: some View {
        HStack(spacing: 0) {
            documentWebView
                .overlay(alignment: .bottomTrailing) {
                    if compare == nil, state.lightbox == nil, let stats {
                        DocumentStatsPill(stats: stats)
                    }
                }
                // The modal lives on the web-view chain — the one spot
                // SwiftUI reliably layers above the platform web view.
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
            // Full takeover: the outline folds away while inspecting.
            if outlineVisible, state.lightbox == nil {
                OutlineSidebar(items: outline, proxy: proxy, activeID: activeSection)
            }
        }
    }

    @ViewBuilder
    private var compareBanner: some View {
        if let compare {
            HStack(spacing: 10) {
                Image(systemName: "clock.arrow.circlepath")
                // Two frozen refs read as a range (raw refs, mono, an
                // arrow for direction); one ref keeps the sentence form —
                // "with" always names the baseline, never the new side.
                (compare.newLabel.map {
                    Text("Comparing ")
                        + Text("\(compare.label) → \($0)").font(.body.monospaced())
                } ?? Text("Comparing with \(compare.label)"))
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
        .background(ThemePaper.color(for: themeRaw))
        // The in-editor edit-mode toggle key lives in the page's JS (the
        // web view owns focus while a reveal is open) — keep it in sync
        // with the rebindable shortcut.
        // Read the emitted value, not the store: @Published fires in
        // willSet, so shortcuts.overrides is still the OLD binding here.
        .onReceive(shortcuts.$overrides) { updated in
            proxy.setEditToggleKey(updated.combo(for: .editMode))
        }
        .modifier(DocumentCommandHandler(state: state, handle: handleDocumentCommand))
        .navigationTitle(file.url.lastPathComponent)
        .navigationSubtitle(subtitle)
        .onDisappear { saveReadingPosition() }
        .onAppear {
            load()
            loadGitInfo()
            watcher = FileWatcher(url: file.url) {
                load()
                refreshChangeDot()
            }
            updateActiveDocument()
            updateSurfaceToolbar()
            consumePendingCompare()
        }
        // A compare request can also land while this file is already
        // showing (pullmark --diff on an open document) — no fresh
        // onAppear happens, so watch the dictionary itself. And one
        // deferred mid-edit applies once the editor closes.
        .onChange(of: state.pendingCompares) { _ in consumePendingCompare() }
        .onChange(of: inlineEditing) { editing in
            if !editing { consumePendingCompare() }
        }
        .onDisappear {
            watcher = nil
            state.unregisterActiveDocument(id: activeDocumentID)
        }
        // The window toolbar renders from the registered snapshot — every
        // value that drives an item's on/off or enabled state re-registers.
        .onChange(of: editMode) { _ in updateSurfaceToolbar() }
        .onChange(of: inGitRepo) { _ in updateSurfaceToolbar() }
        .onChange(of: compare == nil) { _ in updateSurfaceToolbar() }
        .onChange(of: hasHeadChanges) { _ in updateSurfaceToolbar() }
        .onChange(of: state.sourceViewVisible) { _ in updateSurfaceToolbar() }
        .onChange(of: blameVisible) { _ in loadBlame() }
        .onChange(of: currentText) { _ in
            loadBlame()
            updateActiveDocument()
        }
        .onChange(of: inGitRepo) { _ in loadBlame() }
        .modifier(PagePreferenceApplier(proxy: proxy))
        // Commits don't touch the file, so the watcher can't see them: the
        // compare menu, blame, and titlebar branch went stale the moment
        // one landed. Refresh when the app returns from a terminal…
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in loadGitInfo() }
        // …and when the in-app commit sheet lands one (no deactivation).
        .onChange(of: state.gitStateTick) { _ in loadGitInfo() }
        // A first commit (or a new one) changes what blame should show.
        .onChange(of: commits) { _ in loadBlame() }
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
        .sheet(isPresented: $revisionsSheetShown) {
            CompareRevisionsSheet(commits: commits, branches: branches,
                                  remoteBranches: remoteBranches, tags: tags) { old, new in
                if let new {
                    startComparingRefs(oldRef: old, newRef: new)
                } else {
                    startComparing(ref: old, label: old == "HEAD" ? "the last commit" : old)
                }
            }
        }
    }

    /// The window-level toolbar (AppToolbar) renders this surface's items
    /// from here; the closures reach back into this view's live state.
    private func updateSurfaceToolbar() {
        var surface = SurfaceToolbar(id: activeDocumentID)
        surface.shareURL = file.url
        surface.editMode = editMode
        surface.editDisabled = compare != nil || state.sourceViewVisible
        surface.setEditMode = { setEditMode($0) }
        // Always available for local files: even outside a git repo the
        // menu offers Compare with File….
        surface.compareAvailable = true
        surface.popCompare = { popCompareMenu(from: $0) }
        surface.comparing = compare != nil
        surface.compareGitAvailable = inGitRepo
        surface.compareHasChanges = hasHeadChanges
        surface.blameAvailable = inGitRepo
        surface.blameDisabled = compare != nil
        surface.marginNoteDisabled = compare != nil || state.sourceViewVisible
        state.registerSurfaceToolbar(surface)
    }

    /// Menu commands that act on this view's own state (View → Reload
    /// Document, Edit → Edit Mode).
    private func handleDocumentCommand(_ request: DocumentCommandRequest?) {
        guard request != nil else { return }
        if state.take(.reload) { load() }
        if state.take(.toggleEditMode) { handleToggleEditMode() }
        if state.take(.toggleCompare) {
            if compare != nil {
                stopComparing()
            } else if inGitRepo {
                startComparing(ref: "HEAD", label: "the last commit")
            }
        }
        if state.take(.addMarginNote) { openNoteComposer(fileLevel: false) }
        if state.take(.addFileMarginNote) { openNoteComposer(fileLevel: true) }
    }

    /// Menu-driven note composers. Comparisons and the source view show
    /// text that isn't the document; hidden notes would make an invisible
    /// write — all three bail to a notice instead of half-working.
    private func openNoteComposer(fileLevel: Bool) {
        guard compare == nil, !state.sourceViewVisible else { return }
        guard marginNotesEnabled else {
            state.lastNotice = "Margin notes are off — turn them on in "
                + "Settings → Experimental."
            return
        }
        guard marginNotesVisible else {
            state.lastNotice = "Margin notes are hidden — choose View → Show Margin Notes first."
            return
        }
        proxy.openNoteComposer(fileLevel: fileLevel)
    }

    /// Builds the compare NSMenu from live git state at click time and
    /// pops it on the window toolbar button's anchor (the button lives in
    /// AppToolbar; SwiftUI's toolbar Menu would cache stale rows).
    private func popCompareMenu(from view: NSView) {
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
        func addAction(_ title: String, checked: Bool = false,
                       _ run: @escaping () -> Void) {
            let item = NSMenuItem(title: title,
                                  action: #selector(MenuActionPresenter.fire(_:)),
                                  keyEquivalent: "")
            item.target = comparePresenter
            item.tag = actions.count
            item.state = checked ? .on : .off
            actions.append(run)
            menu.addItem(item)
        }
        if !commits.isEmpty {
            addHeader(commits.count >= 25 ? "History (25 most recent)" : "History")
            for commit in commits {
                addAction("\(commit.shortSHA) · \(commit.date) · \(commit.subject)") {
                    startComparing(ref: commit.sha,
                                   label: "\(commit.shortSHA) (\(commit.date))")
                }
            }
        }
        if !branches.isEmpty {
            addHeader(branches.count >= 20 ? "Recent Branches" : "Branches")
            for branch in branches {
                // The checkmark marks where the working file already is.
                addAction(branch, checked: branch == currentBranch) {
                    startComparing(ref: branch, label: branch)
                }
            }
        }
        if !tags.isEmpty {
            addHeader(tags.count >= 20 ? "Recent Tags" : "Tags")
            for tag in tags {
                addAction(tag) { startComparing(ref: tag, label: tag) }
            }
        }
        if !remoteBranches.isEmpty {
            addHeader(remoteBranches.count >= 20 ? "Recent Remote Branches"
                                                 : "Remote Branches")
            for branch in remoteBranches {
                addAction(branch) { startComparing(ref: branch, label: branch) }
            }
        }
        // The quieter forms, tucked at the bottom: another file as the
        // baseline (works without git), and a frozen two-revision pair.
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        addAction("Compare with File…") { pickCompareFile() }
        if inGitRepo, !commits.isEmpty {
            addAction("Compare Revisions…") { revisionsSheetShown = true }
        }
        if compare != nil {
            menu.addItem(.separator())
            addAction("Stop Comparing") { stopComparing() }
        }
        comparePresenter.actions = actions
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -6), in: view)
    }

    /// Compare with File… — any file on disk becomes the baseline (the
    /// old side); the working file stays the live new side.
    private func pickCompareFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the file to compare with — it becomes the old side."
        panel.prompt = "Compare"
        guard panel.runModal() == .OK, let other = panel.url else { return }
        startComparingFile(other)
    }

    /// "~/Code/pullmark · main · edited" — folder, branch, and unsaved-edit
    /// state in the titlebar, where the eye already goes for context.
    private var subtitle: String {
        var parts = PathAbbreviator.abbreviate(file.url.deletingLastPathComponent().path)
        if let currentBranch { parts += " · \(currentBranch)" }
        if editMode { parts += " · editing" }
        return parts
    }

    /// In-place editor commit from the page. The seed is the text the
    /// editor was opened with — applyBlockEdit's guard compares it against
    /// the current lines, so a file changed underneath still aborts.
    private func handleOpenLocalFile(_ url: URL) { state.openViaLink(url: url) }
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

    /// The one way in and out of edit mode — toolbar toggle, Edit → Edit
    /// Mode, and the page's own key all land here. Commits any open reveal
    /// FIRST (the flip re-renders the page and an uncommitted draft would
    /// die with it), keeps the scroll position, and force-releases the
    /// reload deferral: the torn-down page can never post editingState.
    private func setEditMode(_ newValue: Bool) {
        // Entering edit mode is the clearest "I'm not just looking" signal.
        if newValue { state.pinPreviewIfNeeded(url: file.url) }
        proxy.commitInlineEdit()
        proxy.scrollFraction { fraction in
            proxy.firstVisibleLine { line in
                Task { @MainActor in
                    let scrolled = (fraction ?? 0) > 0.02
                    if scrolled, let fraction { pendingScrollRestore = fraction }
                    editMode = newValue
                    if newValue {
                        sessionSnapshotTaken = false
                        // From a scrolled position, auto-reveal the block
                        // the reader is on — the first-block default would
                        // drag them to the top (the revealed editor's
                        // focus scroll outlives the fraction restore).
                        if scrolled, let line {
                            pendingRevealLine = line
                        } else {
                            pendingAutoReveal = true
                        }
                    }
                    handleEditingState(false)
                }
            }
        }
    }

    private func handleToggleEditMode() {
        // Comparing a revision replaces the document with a diff; editing
        // it would write the wrong text back.
        guard compare == nil, !state.sourceViewVisible else { return }
        setEditMode(!editMode)
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
            let segments = DiffPageBuilder.segments(old: compareText,
                                                    new: compareNewText ?? currentText)
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
        // Bubbles render whenever the file carries notes (correct
        // rendering of the file's content); the experimental switch gates
        // only the authoring chrome — affordances and Edit/Delete.
        let notes = marginNotesVisible
            ? MarginNotePayload.payloads(from: MarginNotes.parse(currentText)) : []
        return HTMLBuilder.documentPage(markdown: currentText,
                                        title: file.url.lastPathComponent,
                                        localResources: true,
                                        theme: style.theme,
                                        customCSS: style.customCSS,
                                        editable: editMode,
                                        blame: blameVisible ? blamePayloads : nil,
                                        blameNote: blameVisible ? blameNote : nil,
                                        marginNotes: notes,
                                        noteAuthoring: marginNotesVisible && marginNotesEnabled)
    }

    /// Block-editor apply: edit-mode commits write straight to disk — the
    /// mode boundary is the save gesture (seed-guarded; one history
    /// snapshot per editing session).
    private func applyBlockEdit(_ target: BlockEditTarget, replacement: String) {
        // Authoring beats previewing: writing to a previewed file pins it.
        state.pinPreviewIfNeeded(url: file.url)
        // Optimistic concurrency: if the file changed underneath the open
        // editor (another editor, an agent), the seed no longer matches its
        // line range — abort rather than splice into the wrong lines.
        guard TextLines.lines(in: currentText, from: target.lineStart, to: target.lineEnd)
                == target.seed else {
            state.lastNotice = "\(file.url.lastPathComponent) changed while you were editing "
                + "this block — nothing was saved. Re-open the block to edit the current version."
            pendingRevealLine = nil  // a refused save must not leave a
            proxy.cancelInlineEdit() // reveal armed for a later reload
            return
        }
        // Textareas hand back LF regardless of the file's endings: an
        // edit that's byte-identical after normalizing must not touch the
        // file, and a real edit must keep the file's dominant EOL rather
        // than splicing mixed endings into a CRLF document.
        let seedLF = target.seed
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var effective = replacement
        if effective == seedLF {
            pendingRevealLine = nil
            proxy.cancelInlineEdit()
            return
        }
        if currentText.contains("\r\n") {
            effective = effective.replacingOccurrences(of: "\n", with: "\r\n")
        }
        guard let newText = TextLines.replacing(in: currentText,
                                                from: target.lineStart,
                                                to: target.lineEnd,
                                                with: effective) else {
            pendingRevealLine = nil
            proxy.cancelInlineEdit()
            return
        }
        do {
            if !sessionSnapshotTaken {
                EditHistory.snapshot(file.url)
                sessionSnapshotTaken = true
            }
            try newText.write(to: file.url, atomically: true, encoding: .utf8)
        } catch {
            state.lastError = "Couldn't save \(file.url.lastPathComponent): \(error.localizedDescription)"
            proxy.cancelInlineEdit()
        }
    }

    // MARK: Margin notes

    /// Adding a note under a block (afterLine = the block's last source
    /// line; 0 = file-level, which lands after any front matter).
    /// A non-nil itemIndent means the note lives inside a list item —
    /// indented to the item's content, packed tight (spec:
    /// nested-comment-targets).
    private func handleNoteAdd(_ afterLine: Int, body: String, itemIndent: String?) {
        // Annotating is commitment beyond reading: it pins a preview.
        state.pinPreviewIfNeeded(url: file.url)
        let author = MarginNoteAuthor.current(viewerLogin: state.viewerLogin)
        applyNoteChange { text in
            let at = afterLine > 0 ? afterLine
                : (MarkdownBlocks.frontMatterEndLine(text.components(separatedBy: "\n")) ?? 0)
            return MarginNotes.inserting(author: author, body: body, afterLine: at,
                                         itemIndent: afterLine > 0 ? itemIndent : nil,
                                         in: text)
        }
    }

    private func handleNoteEdit(_ index: Int, body: String) {
        applyNoteChange { text in
            let notes = MarginNotes.parse(text)
            guard notes.indices.contains(index) else { return nil }
            return MarginNotes.replacingBody(of: notes[index], with: body, in: text)
        }
    }

    private func handleNoteDelete(_ index: Int) {
        applyNoteChange { text in
            let notes = MarginNotes.parse(text)
            guard notes.indices.contains(index) else { return nil }
            return MarginNotes.removing(notes[index], from: text)
        }
    }

    /// The shared note write path: surgery on LF-normalized text (CRLF
    /// files round-trip through it losslessly), one Revert snapshot per
    /// gesture, and the reader's scroll position preserved across the
    /// re-render. A nil transform means the file changed underneath the
    /// bubble — surface it, write nothing.
    private func applyNoteChange(_ transform: @escaping (String) -> String?) {
        proxy.scrollFraction { fraction in
            Task { @MainActor in
                if let fraction, fraction > 0.02 { pendingScrollRestore = fraction }
                let wasCRLF = currentText.contains("\r\n")
                let lf = currentText
                    .replacingOccurrences(of: "\r\n", with: "\n")
                    .replacingOccurrences(of: "\r", with: "\n")
                guard var newText = transform(lf) else {
                    state.lastNotice = "\(file.url.lastPathComponent) changed while you were "
                        + "annotating — nothing was saved. The current notes are shown now."
                    return
                }
                if wasCRLF {
                    newText = newText.replacingOccurrences(of: "\n", with: "\r\n")
                }
                do {
                    EditHistory.snapshot(file.url)
                    try newText.write(to: file.url, atomically: true, encoding: .utf8)
                } catch {
                    state.lastError = "Couldn't save \(file.url.lastPathComponent): "
                        + error.localizedDescription
                }
            }
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
            markdown: currentText,
            proxy: proxy,
            localRoot: file.resourceRoot
        ))
    }

    private func handlePageLoaded() {
        // Fresh page, fresh JS state: re-teach it the edit-mode toggle key.
        proxy.setEditToggleKey(shortcuts.combo(for: .editMode))
        // Third consume point: on a cold launch the incarnation that
        // reaches page-load is the one that survives restore settling.
        consumePendingCompare()
        if let line = pendingRevealLine {
            pendingRevealLine = nil
            pendingAutoReveal = false
            proxy.revealAtLine(line)
        }
        if pendingAutoReveal, editMode {
            pendingAutoReveal = false
            proxy.revealFocused()
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
    }

    private func loadGitInfo() {
        let url = file.url
        Task.detached(priority: .utility) {
            guard let root = LocalGit.repoRoot(for: url) else { return }
            let commits = LocalGit.history(of: url)
            let branches = LocalGit.branches(in: root, remote: false)
            let remotes = LocalGit.branches(in: root, remote: true)
            let tags = LocalGit.tags(in: root)
            let current = LocalGit.currentBranch(in: root)
            // No history yet (unborn HEAD, or a file never committed):
            // "changed since HEAD" would be noise.
            let changed = commits.isEmpty ? false : LocalGit.hasChanges(url)
            await MainActor.run {
                self.inGitRepo = true
                self.commits = commits
                self.branches = branches
                self.remoteBranches = remotes
                self.tags = tags
                self.currentBranch = current
                self.hasHeadChanges = changed
            }
        }
    }

    /// The dot alone, off-main — the watcher fires on every save and the
    /// full git-info reload (four calls) would be waste.
    private func refreshChangeDot() {
        guard inGitRepo, !commits.isEmpty else { return }
        let url = file.url
        Task.detached(priority: .utility) {
            let changed = LocalGit.hasChanges(url)
            await MainActor.run { self.hasHeadChanges = changed }
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

    /// A pullmark://compare deep link (the CLI's --diff/--diff-with
    /// flags) targeting this file: a STANDING instruction, consumed
    /// whenever this file shows with no comparison up. Entries are
    /// retired by resolution errors, by Done/Stop, or by the user
    /// starting a different compare — never by task callbacks, which
    /// can belong to incarnations SwiftUI already discarded (session
    /// restore and multi-file opens both recreate this view mid-flight;
    /// both bit, live). Mid-edit the instruction waits: a compare
    /// reload would destroy the open editor's draft.
    private func consumePendingCompare() {
        guard compare == nil, !inlineEditing else { return }
        let key = file.url.standardizedFileURL.path
        guard let request = state.pendingCompares[key] else { return }
        if case .againstFile(let other) = request {
            startComparingFile(other, userInitiated: false)
            return
        }
        guard LocalGit.repoRoot(for: file.url) != nil else {
            state.lastError = "\(file.url.lastPathComponent) isn't in a git "
                + "repository, so there's nothing to compare against."
            retirePendingCompare()
            return
        }
        switch request {
        case .workingAgainstRef(let ref):
            startComparing(ref: ref, label: ref == "HEAD" ? "the last commit" : ref,
                           userInitiated: false)
        case .refAgainstRef(let old, let new):
            startComparingRefs(oldRef: old, newRef: new, userInitiated: false)
        case .againstFile:
            break // handled above
        }
    }

    private func retirePendingCompare() {
        state.pendingCompares.removeValue(forKey: file.url.standardizedFileURL.path)
    }

    /// Both sides frozen: the file at two refs. The live file plays no
    /// part, so later edits don't disturb the page. userInitiated marks
    /// a human choice, which retires any standing deep-link request —
    /// the deep-link consume path passes false so the instruction it's
    /// applying survives view churn.
    private func startComparingRefs(oldRef: String, newRef: String,
                                    userInitiated: Bool = true) {
        if userInitiated { retirePendingCompare() }
        let url = file.url
        compareGeneration += 1
        let generation = compareGeneration
        Task.detached(priority: .userInitiated) {
            let old = LocalGit.content(of: url, at: oldRef)
            let new = LocalGit.content(of: url, at: newRef)
            await MainActor.run {
                guard generation == compareGeneration else { return }
                let name = url.lastPathComponent
                guard let old else {
                    state.lastError = "\(name) does not exist at \(oldRef)."
                    stopComparing()
                    return
                }
                guard let new else {
                    state.lastError = "\(name) does not exist at \(newRef)."
                    stopComparing()
                    return
                }
                compareText = old
                compareNewText = new
                compare = CompareTarget(ref: oldRef, label: oldRef, newLabel: newRef)
            }
        }
    }

    /// Another file on disk as the baseline (old side); the working file
    /// stays the live new side. Works without git.
    private func startComparingFile(_ other: URL, userInitiated: Bool = true) {
        if userInitiated { retirePendingCompare() }
        compareGeneration += 1
        let generation = compareGeneration
        Task.detached(priority: .userInitiated) {
            let old = try? String(contentsOf: other, encoding: .utf8)
            await MainActor.run {
                guard generation == compareGeneration else { return }
                guard let old else {
                    state.lastError = "Could not read \(other.lastPathComponent)."
                    stopComparing()
                    return
                }
                compareText = old
                compareNewText = nil
                compare = CompareTarget(ref: "file:\(other.path)",
                                        label: other.lastPathComponent)
            }
        }
    }

    private func startComparing(ref: String, label: String,
                                userInitiated: Bool = true) {
        if userInitiated { retirePendingCompare() }
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
                compareNewText = nil
                compare = CompareTarget(ref: ref, label: label)
            }
        }
    }

    private func stopComparing() {
        compare = nil
        compareText = nil
        compareNewText = nil
        // Done/Stop (and error resolutions, which land here) retire any
        // standing deep-link request — dismissed means dismissed.
        retirePendingCompare()
    }
}
