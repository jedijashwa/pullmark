import SwiftUI

// MARK: - PR overview

struct PROverviewView: View {
    @EnvironmentObject private var state: AppState
    let sessionID: String

    @State private var reviewSummary = ""
    @State private var submitting = false
    @State private var confirmation: String?
    @State private var conversationText = ""
    @State private var postingComment = false
    @State private var findSeed: String?
    @StateObject private var proxy = WebViewProxy()
    @AppStorage(Theme.defaultsKey) private var themeRaw = Theme.standard.rawValue

    var body: some View {
        if let session = state.session(sessionID) {
            VStack(alignment: .leading, spacing: 0) {
                if session.updateAvailable {
                    PRUpdateBanner(sessionID: sessionID)
                }
                if state.findBarVisible {
                    FindBar(proxy: proxy, seed: $findSeed)
                }
                header(session)
                    .padding([.horizontal, .top], 20)
                    .padding(.bottom, 12)
                reviewSection(session)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                Divider()
                let style = ThemeSelection.pageStyle(from: themeRaw)
                MarkdownWebView(
                    html: HTMLBuilder.documentPage(
                        markdown: session.details.body?.isEmpty == false
                            ? session.details.body!
                            : "_No description provided._",
                        title: session.details.title,
                        theme: style.theme,
                        customCSS: style.customCSS
                    ),
                    onPageLoaded: {
                        // Restore find highlights if the page re-renders
                        // beneath an active find (same as the file views).
                        if state.findBarVisible, let query = proxy.activeFindQuery {
                            findSeed = query
                        }
                    },
                    proxy: proxy
                )
                .background(ThemePaper.color(for: themeRaw))
            }
            .navigationTitle(String("\(session.ref.owner)/\(session.ref.repo) #\(session.ref.number)"))
        } else {
            EmptyView()
        }
    }

    private func header(_ session: PRSession) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(session.details.title)
                .font(.title2.bold())
            HStack(spacing: 8) {
                let status = PRStatus(details: session.details)
                Label(status.label, systemImage: status.systemImage)
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(status.color.opacity(0.18), in: Capsule())
                    .foregroundStyle(status.color)
                if let login = session.details.user?.login {
                    Text("opened by \(login)")
                        .foregroundStyle(.secondary)
                }
                Link("View on GitHub", destination: session.details.htmlUrl)
            }
            .font(.callout)
            Text(filesSummary(session))
                .font(.callout)
                .foregroundStyle(.secondary)
            if let confirmation {
                Label(confirmation, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            }
        }
    }

    /// The whole verdict lives here: drafts (when any), an optional
    /// summary, and first-class Approve / Request Changes / Comment —
    /// available with zero comments too, like GitHub's own Review button.
    private func reviewSection(_ session: PRSession) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if !session.drafts.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(session.drafts) { draft in
                                HStack(alignment: .top) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("\(draft.path) · \(draft.lineDescription)")
                                            .font(.caption.bold())
                                            .foregroundStyle(.secondary)
                                        Text(draft.body)
                                            .lineLimit(3)
                                    }
                                    Spacer()
                                    Button {
                                        state.removeDraft(sessionID: sessionID, draftID: draft.id)
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Discard this draft comment")
                                }
                                .padding(6)
                                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }
                    .frame(maxHeight: 180)
                }

                TextField("Review summary (optional)", text: $reviewSummary, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)

                HStack(spacing: 10) {
                    if !session.drafts.isEmpty {
                        Button("Save as Pending on GitHub") { submit(event: nil) }
                            .fixedSize()
                            .help("Uploads the comments as a pending (draft) review you can finish on GitHub")
                    }
                    ProgressView()
                        .controlSize(.small)
                        .opacity(submitting ? 1 : 0)
                    Spacer()
                    Button("Comment") { submit(event: "COMMENT") }
                        .fixedSize()
                        .disabled(!reviewActionable(session))
                        .help("Submit the review without a verdict")
                    Button("Request Changes") { submit(event: "REQUEST_CHANGES") }
                        .fixedSize()
                        .disabled(!reviewActionable(session))
                        .help("Ask for changes before this can merge")
                    Button("Approve") { submit(event: "APPROVE") }
                        .buttonStyle(.borderedProminent)
                        .fixedSize()
                        .help("Approve this pull request")
                }
                .disabled(submitting)

                // Conversation comments post immediately to the PR's
                // timeline — separate from any review verdict.
                HStack(spacing: 10) {
                    TextField("Comment on the pull request conversation…",
                              text: $conversationText, axis: .vertical)
                        .lineLimit(1...4)
                        .textFieldStyle(.roundedBorder)
                    Button("Post") { postConversationComment() }
                        .fixedSize()
                        .disabled(conversationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || postingComment)
                        .help("Post to the PR conversation right away (not part of a review)")
                }
            }
            .padding(4)
        } label: {
            Label(session.drafts.isEmpty
                    ? "Review"
                    : "Review — \(session.drafts.count) draft comment\(session.drafts.count == 1 ? "" : "s")",
                  systemImage: "text.bubble")
        }
    }

    /// GitHub rejects a COMMENT or REQUEST_CHANGES review that carries
    /// neither a body nor comments; Approve stands on its own.
    private func reviewActionable(_ session: PRSession) -> Bool {
        !session.drafts.isEmpty
            || !reviewSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func postConversationComment() {
        guard let session = state.session(sessionID) else { return }
        let body = conversationText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        postingComment = true
        confirmation = nil
        Task {
            do {
                try await state.client.createIssueComment(session.ref, body: body)
                conversationText = ""
                confirmation = "Comment posted to the conversation."
            } catch {
                state.lastError = error.localizedDescription
            }
            postingComment = false
        }
    }

    private func filesSummary(_ session: PRSession) -> String {
        let md = session.markdownFiles.count
        var parts = ["\(md) Markdown file\(md == 1 ? "" : "s") changed"]
        if session.otherFileCount > 0 {
            parts.append("\(session.otherFileCount) other file\(session.otherFileCount == 1 ? "" : "s") not shown")
        }
        return parts.joined(separator: " · ")
    }

    private func submit(event: String?) {
        guard let session = state.session(sessionID) else { return }
        submitting = true
        confirmation = nil
        let summary = reviewSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                try await state.client.createReview(
                    session.ref,
                    commitID: session.details.head.sha,
                    body: summary.isEmpty ? nil : summary,
                    event: event,
                    drafts: session.drafts
                )
                state.clearDrafts(sessionID: sessionID)
                reviewSummary = ""
                confirmation = event == nil
                    ? "Saved as a pending review on GitHub."
                    : "Review submitted."
            } catch {
                state.lastError = error.localizedDescription
            }
            submitting = false
        }
    }
}

// MARK: - PR file (rendered diff)

struct PRFileView: View {
    @EnvironmentObject private var state: AppState
    let sessionID: String
    let path: String

    enum Mode: String, CaseIterable, Identifiable {
        case renderedDiff = "Rendered Diff"
        case sourceDiff = "Source Diff"
        case result = "Result"
        var id: String { rawValue }
    }

    enum DiffLayout: String, CaseIterable, Identifiable {
        case inline = "Inline"
        case split = "Side by Side"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .renderedDiff
    @ObservedObject private var shortcuts = ShortcutStore.shared

    /// View-menu commands that act on this view's own state: the toolbar
    /// pickers have no key equivalents of their own.
    private func handleDocumentCommand(_ request: DocumentCommandRequest?) {
        guard request != nil else { return }
        if state.take(.showRenderedDiff) { mode = .renderedDiff }
        if state.take(.showSourceDiff) { mode = .sourceDiff }
        if state.take(.showResult) { mode = .result }
        if state.take(.flipDiffLayout) {
            layoutRaw = (layout == .inline ? DiffLayout.split : DiffLayout.inline).rawValue
        }
    }
    @AppStorage(DefaultsKeys.diffLayout) private var layoutRaw = DiffLayout.inline.rawValue
    @State private var baseText: String?
    @State private var headText: String?
    @State private var loading = true
    @State private var loadError: String?
    @State private var commentTarget: CommentTarget?
    @State private var fileCommentVisible = false
    @State private var outline: [OutlineItem] = []
    @State private var activeSection: String?
    @State private var stats: DocumentStats?
    @State private var replyTarget: ReplyTarget?
    @State private var findSeed: String?
    @StateObject private var proxy = WebViewProxy()
    @AppStorage(DefaultsKeys.outlinePanel) private var outlineVisible = false
    @AppStorage(Theme.defaultsKey) private var themeRaw = Theme.standard.rawValue
    @AppStorage(DefaultsKeys.blame) private var blameVisible = false
    @State private var blamePayloads: [BlameRunPayload]?
    @State private var blameNote: String?
    @State private var historyRequest: BlameHistoryRequest?

    private var layout: DiffLayout { DiffLayout(rawValue: layoutRaw) ?? .inline }

    private var session: PRSession? { state.session(sessionID) }
    private var file: PullRequestFile? { session?.files.first { $0.filename == path } }

    private var loadTaskID: String {
        sessionID + "|" + path + "|" + (session?.details.head.sha ?? "")
    }

    private func modeChanged(_ newMode: Mode) {
        loadBlameIfNeeded()
        updateActiveDocument()
    }

    @ViewBuilder
    private var stackedContent: some View {
        if session?.updateAvailable == true {
            PRUpdateBanner(sessionID: sessionID)
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
                Button("Retry") { Task { await load() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            documentArea
        }
    }

    var body: some View {
        VStack(spacing: 0) { stackedContent }
            .navigationTitle(path)
            .toolbar { fileToolbar }
            .task(id: loadTaskID) { await load() }
            .onDisappear { state.unregisterActiveDocument(id: activeDocumentID) }
            .modifier(DocumentCommandHandler(state: state, handle: handleDocumentCommand))
            .onChange(of: blameVisible) { _ in loadBlameIfNeeded() }
            .onChange(of: mode, perform: modeChanged)
            .modifier(PendingSearchConsumer(target: .prFile(sessionID, path),
                                            consume: consumePendingSearch))
            .modifier(fileSheets)
    }

    /// The four sheets, bundled off the main modifier chain (type-checker
    /// budget again).
    private var fileSheets: PRFileSheets {
        PRFileSheets(
            commentTarget: $commentTarget,
            fileCommentVisible: $fileCommentVisible,
            replyTarget: $replyTarget,
            historyRequest: $historyRequest,
            sessionID: sessionID,
            path: path,
            history: { [weak state] in
                guard let state, let session = state.session(sessionID) else {
                    throw GitHubClient.APIError(status: -1, message: "The PR session is no longer available.")
                }
                return try await BlameService.remoteHistory(
                    client: state.client, ref: session.ref,
                    path: path, sha: session.details.head.sha)
            }
        )
    }

    private var activeDocumentID: String { "prFile:" + sessionID + "|" + path }

    /// Only the Result mode is a document (diff modes never register), and
    /// only once the head content is loaded; a deleted file's placeholder
    /// note is not worth exporting.
    private func updateActiveDocument() {
        guard mode == .result, !loading, loadError == nil,
              let headText, file?.status != "removed" else {
            state.unregisterActiveDocument(id: activeDocumentID)
            return
        }
        state.registerActiveDocument(ActiveDocument(
            id: activeDocumentID,
            exportBaseName: ((path as NSString).lastPathComponent as NSString).deletingPathExtension,
            markdown: headText,
            proxy: proxy,
            remoteContext: remoteContext
        ))
    }

    private func setThreadResolved(rootID: Int, resolved: Bool) {
        guard let session, let meta = session.threadMeta[rootID] else {
            state.lastError = "Thread state unavailable — try refreshing the PR."
            return
        }
        Task {
            do {
                try await state.client.setThreadResolved(nodeID: meta.nodeID, resolved: resolved)
                await state.reloadComments(sessionID: sessionID)
            } catch {
                state.lastError = error.localizedDescription
            }
        }
    }

    private var remoteContext: RemoteResourceContext? {
        guard let session else { return nil }
        return RemoteResourceContext(ref: session.ref, commitSHA: session.details.head.sha)
    }

    /// Current content of the targeted new-file lines, used to pre-fill a
    /// ```suggestion block. Only meaningful on the new side.
    private func suggestionSeed(for message: BridgeMessage) -> String? {
        guard message.side == "RIGHT", let headText else { return nil }
        return TextLines.lines(in: headText, from: message.lineStart, to: message.lineEnd)
    }

    private var html: String {
        guard let file else { return "" }
        let style = ThemeSelection.pageStyle(from: themeRaw)
        let theme = style.theme
        switch mode {
        case .result:
            let markdown = file.status == "removed"
                ? "> [!NOTE]\n> This file was deleted in the pull request."
                : (headText ?? "")
            if state.sourceViewVisible, file.status != "removed" {
                return HTMLBuilder.sourcePage(markdown: markdown, title: path,
                                              theme: theme,
                                              customCSS: style.customCSS)
            }
            return HTMLBuilder.documentPage(markdown: markdown, title: path,
                                            remote: HTMLBuilder.RemoteAssets(filePath: path),
                                            theme: theme,
                                            customCSS: style.customCSS,
                                            blame: blameVisible ? blamePayloads : nil,
                                            blameNote: blameVisible ? blameNote : nil)
        case .sourceDiff:
            return HTMLBuilder.patchPage(
                patch: file.patch ?? "No textual diff available for this file.",
                title: path,
                theme: theme,
                customCSS: style.customCSS
            )
        case .renderedDiff:
            var segments = DiffPageBuilder.segments(old: baseText ?? "", new: headText ?? "")
            let threads = ReviewThreads.group(
                (session?.reviewComments ?? []).filter { $0.path == path }
            )
            let placed = ReviewThreads.place(threads, in: segments,
                                             meta: session?.threadMeta ?? [:])
            segments = placed.segments
            func payload(_ thread: ReviewThread) -> ThreadPayload {
                ThreadPayload(lineLabel: thread.lineLabel,
                              comments: thread.comments.map(CommentPayload.init),
                              rootID: thread.root.id,
                              resolved: session?.threadMeta[thread.root.id]?.isResolved)
            }
            // Whole-file comments were never anchored — their own section,
            // not the outdated bucket.
            let fileThreads = placed.outdated.filter(\.isFileLevel).map(payload)
            let outdated = placed.outdated.filter { !$0.isFileLevel }.map(payload)
            let allNew = file.status == "added"
            return HTMLBuilder.diffPage(segments: segments,
                                        outdatedThreads: outdated,
                                        fileThreads: fileThreads,
                                        layout: (layout == .split && !allNew) ? "split" : "inline",
                                        remote: HTMLBuilder.RemoteAssets(filePath: path),
                                        title: path,
                                        theme: theme,
                                        customCSS: style.customCSS,
                                        allNew: allNew)
        }
    }

    /// The web view + optional outline column (extracted from body for the
    /// type-checker).
    private var documentArea: some View {
        HSplitView {
            MarkdownWebView(
                html: html,
                onCommentRequest: { commentTarget = makeCommentTarget(from: $0) },
                remoteContext: remoteContext,
                onOpenRemoteFile: { repoPath in
                    state.openRemoteDoc(sessionID: sessionID, path: repoPath)
                },
                onOutline: { outline = $0 },
                onActiveSection: { activeSection = $0.isEmpty ? nil : $0 },
                onThreadReply: { replyTarget = ReplyTarget(id: $0) },
                onThreadResolve: { rootID, resolved in
                    setThreadResolved(rootID: rootID, resolved: resolved)
                },
                onBlameHistory: { start, end in
                    historyRequest = BlameHistoryRequest(lineStart: start, lineEnd: end)
                },
                onStats: { stats = $0 },
                onPageLoaded: { handlePageLoaded() },
                proxy: proxy
            )
            .overlay(alignment: .bottomTrailing) {
                if mode == .result, let stats {
                    DocumentStatsPill(stats: stats)
                }
            }
            .layoutPriority(1)
            if outlineVisible {
                OutlineSidebar(items: outline, proxy: proxy, activeID: activeSection)
            }
        }
        .background(ThemePaper.color(for: themeRaw))
    }

    private func makeCommentTarget(from message: BridgeMessage) -> CommentTarget {
        let seed = suggestionSeed(for: message)
        let sideText = message.side == "RIGHT" ? headText : baseText
        return CommentTarget(
            lineStart: message.lineStart,
            lineEnd: message.lineEnd,
            side: message.side,
            suggestionSeed: seed,
            // Pencil without a seed (head text not loaded yet) degrades to
            // the plain composer.
            editSuggestion: message.edit && seed != nil,
            sourceText: sideText.flatMap {
                TextLines.lines(in: $0, from: message.lineStart, to: message.lineEnd)
            }
        )
    }

    /// Extracted from body so the modifier chain stays inside the
    /// type-checker's budget.
    @ToolbarContentBuilder
    private var fileToolbar: some ToolbarContent {
        ToolbarItem {
            OutlineToggle(visible: $outlineVisible)
        }
        ToolbarItem(placement: .principal) {
            Picker("View", selection: $mode) {
                ForEach(Mode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        }
        ToolbarItem {
            if mode == .renderedDiff {
                Picker("Layout", selection: $layoutRaw) {
                    ForEach(DiffLayout.allCases) { layout in
                        Text(layout.rawValue).tag(layout.rawValue)
                    }
                }
                .pickerStyle(.menu)
                // A brand-new file renders inline regardless: split
                // mode would show an all-hatched old column against
                // the untinted document — half the pane saying nothing.
                .disabled(file?.status == "added")
                .help(file?.status == "added"
                    ? "New files always render inline — there is no old side to compare"
                    : "Inline or side-by-side rendered diff")
            }
        }
        ToolbarItem {
            if mode == .result {
                BlameToggle(visible: $blameVisible)
            }
        }
        ToolbarItem {
            Button {
                fileCommentVisible = true
            } label: {
                Label("Comment on File", systemImage: "plus.bubble")
            }
            .help("Comment on this file as a whole, not a specific line")
        }
        // The sidebar shouldn't be the only way around a PR: back to
        // the overview, and step or jump between its Markdown files.
        ToolbarItemGroup(placement: .navigation) {
            if let session {
                PRFileNavigation(sessionID: sessionID, path: path, session: session)
            }
        }
    }

    /// Fetches blame once per loaded head content; failures degrade to a
    /// one-line note in the annotation area.
    private func loadBlameIfNeeded() {
        guard blameVisible, mode == .result, let session, let headText,
              file?.status != "removed",
              blamePayloads == nil, blameNote == nil else { return }
        let ref = session.ref
        let sha = session.details.head.sha
        let path = path
        Task {
            do {
                blamePayloads = try await BlameService.remotePayloads(
                    client: state.client, ref: ref, path: path, sha: sha, markdown: headText)
            } catch {
                blameNote = "Blame unavailable — \(error.localizedDescription)"
            }
        }
    }

    private func load() async {
        guard let session, let file else { return }
        loading = true
        loadError = nil
        blamePayloads = nil
        blameNote = nil
        do {
            if file.status == "added" {
                baseText = ""
            } else {
                baseText = try await state.client.fileContent(
                    session.ref,
                    path: file.previousFilename ?? path,
                    at: session.mergeBaseSHA
                )
            }
            if file.status == "removed" {
                headText = ""
            } else {
                headText = try await state.client.fileContent(
                    session.ref,
                    path: path,
                    at: session.details.head.sha
                )
                if let headText {
                    // Feed the all-files search palette (memory-only cache).
                    state.cachePRContent(sessionID: sessionID, path: path, text: headText)
                }
            }
        } catch {
            loadError = error.localizedDescription
        }
        loading = false
        loadBlameIfNeeded()
        updateActiveDocument()
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
}

struct CommentTarget: Identifiable {
    let id = UUID()
    let lineStart: Int
    let lineEnd: Int
    let side: String
    var suggestionSeed: String?
    /// Edit-as-suggestion: the composer opens as an editor on the block's
    /// source and submits the change wrapped in a ```suggestion block.
    var editSuggestion = false
    /// The block's source on the target side, one string; feeds the
    /// composer's line picker so a comment can narrow to specific lines.
    var sourceText: String?

    /// The block's lines, indexed so row i is source line `lineStart + i`.
    var sourceLines: [String] {
        sourceText.map { $0.components(separatedBy: "\n") } ?? []
    }
}

// MARK: - Comment composer

struct CommentComposer: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    let sessionID: String
    let path: String
    let target: CommentTarget

    @State private var text = ""
    @State private var replacement = ""
    @State private var posting = false
    @State private var error: String?
    @FocusState private var replacementFocused: Bool
    /// The targeted line range — starts as the whole block, narrowable
    /// through the line picker. 1-based source line numbers.
    @State private var selStart: Int
    @State private var selEnd: Int
    /// Last plainly-clicked line; shift-click extends from here.
    @State private var anchor: Int?

    init(sessionID: String, path: String, target: CommentTarget) {
        self.sessionID = sessionID
        self.path = path
        self.target = target
        _selStart = State(initialValue: target.lineStart)
        _selEnd = State(initialValue: target.lineEnd)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(target.editSuggestion ? "Suggest an edit to \(path)" : "Comment on \(path)")
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            if target.lineEnd > target.lineStart, !target.sourceLines.isEmpty {
                linePicker
            } else {
                Text(draft.lineDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if target.editSuggestion {
                // The block's source, ready to edit; submitted as a
                // ```suggestion the author applies with one click. Neutral
                // chrome — the focus ring, not a colored border, signals
                // editability on macOS.
                TextEditor(text: $replacement)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor),
                                in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                    .frame(minHeight: 150, maxHeight: 320)
                    .focused($replacementFocused)
                if replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Clearing all text suggests deleting these lines.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                TextField("", text: $text,
                          prompt: Text("Add an optional note explaining the change"),
                          axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)
            } else {
                TextEditor(text: $text)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor),
                                in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                    .frame(minHeight: 130, maxHeight: 320)
            }

            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            // Helpers live above the action row — sharing one row with
            // three buttons squeezed everything until labels truncated.
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                if !target.editSuggestion, target.suggestionSeed != nil {
                    Button {
                        insertSuggestion()
                    } label: {
                        Label("Insert Suggestion", systemImage: "plus.diamond")
                    }
                    .fixedSize()
                    .help("Insert a ```suggestion block pre-filled with the current lines")
                }
                // Out-of-diff targets fail at post time (or reject the whole
                // review for drafts) — the warning matters in BOTH modes.
                Text(target.editSuggestion
                    ? "Suggestions must target lines that are part of the PR diff."
                    : "Comments must target lines that are part of the PR diff.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }

            // HIG order: primary rightmost with Cancel beside it, the
            // alternative commit further left. Reviewing is this app's whole
            // point, so batching into the pending review is the default.
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                    .opacity(posting ? 1 : 0)
                Spacer()
                Button(target.editSuggestion ? "Suggest Now" : "Comment Now") { postNow() }
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                    .disabled(!submittable || posting)
                    .fixedSize()
                    .help("Post immediately, outside any pending review (⇧⌘↩)")
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .fixedSize()
                Button("Add to Review") {
                    state.addDraft(sessionID: sessionID, draft)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                // ⌘↩ — Return alone inserts a newline while an editor
                // has focus, so plain .defaultAction would never fire.
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!submittable || posting)
                .fixedSize()
                .help("Queue in your pending review — it posts when you submit the review (⌘↩)")
            }
        }
        .padding(20)
        .frame(minWidth: 580)
        .onAppear {
            if target.editSuggestion, let seed = currentSeed {
                replacement = seed
                replacementFocused = true
            }
        }
    }

    // MARK: Line targeting

    private var narrowed: Bool {
        selStart != target.lineStart || selEnd != target.lineEnd
    }

    /// The picker locks once a suggestion is in play with content the
    /// selection no longer matches: in suggestion mode after the seed has
    /// been edited (silently re-seeding would discard the user's work),
    /// and in plain mode once an inserted ```suggestion fence exists (a
    /// suggestion replaces exactly the lines the comment targets, so
    /// narrowing afterwards would corrupt the file when applied).
    private var pickerLocked: Bool {
        if target.editSuggestion {
            return replacement != (currentSeed ?? "")
        }
        return text.contains("```suggestion")
    }

    private var linePicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(draft.lineDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if narrowed, !pickerLocked {
                    Button("All Lines") { select(target.lineStart, target.lineEnd) }
                        .buttonStyle(.link)
                        .font(.subheadline)
                }
                Spacer()
                Text(pickerLocked
                    ? (target.editSuggestion
                        ? "Line selection is locked while your edit is in progress."
                        : "Line selection is locked while a suggestion block is in the comment.")
                    : "Click a line to target just it; shift-click extends the range.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(target.sourceLines.enumerated()), id: \.offset) { offset, line in
                        pickerRow(number: target.lineStart + offset, text: line)
                    }
                }
            }
            .frame(maxHeight: 132)
            .background(Color(nsColor: .textBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
        }
    }

    private func pickerRow(number: Int, text lineText: String) -> some View {
        let selected = number >= selStart && number <= selEnd
        return Button {
            rowClicked(number)
        } label: {
            HStack(spacing: 8) {
                Text("\(number)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(selected ? .secondary : .tertiary)
                    .frame(width: 36, alignment: .trailing)
                Text(lineText.isEmpty ? " " : lineText)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
            .background(selected ? Color.accentColor.opacity(0.14) : .clear)
        }
        .buttonStyle(.plain)
        .disabled(pickerLocked)
        .accessibilityLabel("Line \(number): \(lineText)")
        .accessibilityValue(selected ? "targeted" : "")
        .accessibilityHint("Click to target only this line; shift-click to extend the range")
    }

    private func rowClicked(_ number: Int) {
        let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
        if shift, let anchor {
            select(min(anchor, number), max(anchor, number))
        } else {
            anchor = number
            select(number, number)
        }
    }

    private func select(_ start: Int, _ end: Int) {
        let wasSeed = replacement == (currentSeed ?? "")
        selStart = start
        selEnd = end
        // Suggestions replace exactly the targeted lines, so an untouched
        // seed follows the selection.
        if target.editSuggestion, wasSeed {
            replacement = currentSeed ?? ""
        }
    }

    /// The current content of the targeted lines (new side), narrowed with
    /// the selection.
    private var currentSeed: String? {
        guard target.suggestionSeed != nil else { return nil }
        let lines = target.sourceLines
        guard !lines.isEmpty else { return target.suggestionSeed }
        let lower = max(0, selStart - target.lineStart)
        let upper = min(lines.count - 1, selEnd - target.lineStart)
        guard lower <= upper else { return target.suggestionSeed }
        return lines[lower...upper].joined(separator: "\n")
    }

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Suggestion mode requires an actual change (or a note); a suggestion
    /// identical to the current lines would be a no-op review comment.
    private var submittable: Bool {
        if target.editSuggestion {
            return replacement != (currentSeed ?? "") || !trimmed.isEmpty
        }
        return !trimmed.isEmpty
    }

    /// The posted body: suggestion mode wraps the edited replacement (plus
    /// the optional note) via Suggestion.body; plain mode posts the text.
    private var composedBody: String {
        target.editSuggestion
            ? Suggestion.body(note: text, replacement: replacement)
            : trimmed
    }

    /// GitHub applies the suggestion in place of the commented lines, so the
    /// block starts as their current content for the user to edit.
    private func insertSuggestion() {
        guard let seed = currentSeed else { return }
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        text += "```suggestion\n\(seed)\n```\n"
    }

    private var draft: DraftComment {
        DraftComment(path: path, lineStart: selStart, lineEnd: selEnd,
                     side: target.side, body: composedBody)
    }

    private func postNow() {
        guard let session = state.session(sessionID) else { return }
        posting = true
        error = nil
        Task {
            do {
                try await state.client.createComment(
                    session.ref,
                    commitID: session.details.head.sha,
                    comment: draft
                )
                await state.reloadComments(sessionID: sessionID)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            posting = false
        }
    }
}

/// PRFileView's sheets as one modifier — keeps the view's main chain
/// inside the type-checker's budget.
private struct PRFileSheets: ViewModifier {
    @Binding var commentTarget: CommentTarget?
    @Binding var fileCommentVisible: Bool
    @Binding var replyTarget: ReplyTarget?
    @Binding var historyRequest: BlameHistoryRequest?
    let sessionID: String
    let path: String
    let history: () async throws -> HistoryPanelData

    func body(content: Content) -> some View {
        content
            .sheet(item: $commentTarget) { target in
                CommentComposer(sessionID: sessionID, path: path, target: target)
            }
            .sheet(isPresented: $fileCommentVisible) {
                FileCommentComposer(sessionID: sessionID, path: path)
            }
            .sheet(item: $replyTarget) { target in
                ThreadReplyComposer(sessionID: sessionID, rootID: target.id)
            }
            .sheet(item: $historyRequest) { _ in
                BlameHistorySheet(load: history)
            }
    }
}

/// Toolbar navigation for a PR file: back to the overview, previous/next
/// Markdown file, and a jump menu — the sidebar stays optional. Extracted
/// from PRFileView's toolbar to keep the type-checker solvent.
private struct PRFileNavigation: View {
    @EnvironmentObject private var state: AppState
    let sessionID: String
    let path: String
    let session: PRSession

    var body: some View {
        Button {
            state.selection = .prOverview(sessionID)
        } label: {
            // Icon-only: the toolbar also holds the mode picker, layout,
            // and comment buttons — a titled back button overflows the
            // whole strip at the minimum window width.
            Label("Back to \(session.ref.repo) #\(session.ref.number)",
                  systemImage: "chevron.backward")
                .labelStyle(.iconOnly)
        }
        .help("Back to the pull request overview (\(session.ref.repo) #\(session.ref.number))")
        if session.markdownFiles.count > 1 {
            Button { step(-1) } label: {
                Label("Previous File", systemImage: "chevron.up")
            }
            .disabled(!canStep(-1))
            .help("Previous Markdown file in this pull request")
            Button { step(1) } label: {
                Label("Next File", systemImage: "chevron.down")
            }
            .disabled(!canStep(1))
            .help("Next Markdown file in this pull request")
            Menu {
                ForEach(session.markdownFiles) { file in
                    Button {
                        state.selection = .prFile(sessionID, file.filename)
                    } label: {
                        if file.filename == path {
                            Label(file.filename, systemImage: "checkmark")
                        } else {
                            Text(file.filename)
                        }
                    }
                }
            } label: {
                Text(positionLabel)
                    .monospacedDigit()
            }
            .help("Jump to another Markdown file in this pull request")
        }
    }

    private var index: Int? {
        session.markdownFiles.firstIndex { $0.filename == path }
    }

    private func canStep(_ delta: Int) -> Bool {
        guard let index else { return false }
        return session.markdownFiles.indices.contains(index + delta)
    }

    private func step(_ delta: Int) {
        guard let index, session.markdownFiles.indices.contains(index + delta) else { return }
        state.selection = .prFile(sessionID, session.markdownFiles[index + delta].filename)
    }

    private var positionLabel: String {
        guard let index else { return "\(session.markdownFiles.count) files" }
        return "\(index + 1) of \(session.markdownFiles.count)"
    }
}

// MARK: - Browsed repo document

/// A repo Markdown file opened via a link from PR content, rendered at the
/// PR's head commit.
struct PRDocView: View {
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
    @AppStorage(DefaultsKeys.outlinePanel) private var outlineVisible = false
    @AppStorage(Theme.defaultsKey) private var themeRaw = Theme.standard.rawValue
    @AppStorage(DefaultsKeys.blame) private var blameVisible = false
    @State private var blamePayloads: [BlameRunPayload]?
    @State private var blameNote: String?
    @State private var historyRequest: BlameHistoryRequest?

    private var session: PRSession? { state.session(sessionID) }

    private var html: String {
        let style = ThemeSelection.pageStyle(from: themeRaw)
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
                HSplitView {
                    MarkdownWebView(
                        html: html,
                        remoteContext: session.map {
                            RemoteResourceContext(ref: $0.ref, commitSHA: $0.details.head.sha)
                        },
                        onOpenRemoteFile: { repoPath in
                            state.openRemoteDoc(sessionID: sessionID, path: repoPath)
                        },
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
                        if let stats {
                            DocumentStatsPill(stats: stats)
                        }
                    }
                    .layoutPriority(1)
                    if outlineVisible {
                        OutlineSidebar(items: outline, proxy: proxy, activeID: activeSection)
                    }
                }
                .background(ThemePaper.color(for: themeRaw))
            }
        }
        .navigationTitle(path)
        .toolbar {
            ToolbarItem {
                BlameToggle(visible: $blameVisible)
            }
            ToolbarItem {
                OutlineToggle(visible: $outlineVisible)
            }
        }
        .task(id: sessionID + "|" + path + "|" + (session?.details.head.sha ?? "")) {
            await load()
        }
        .onDisappear {
            state.unregisterActiveDocument(id: activeDocumentID)
        }
        .onChange(of: blameVisible) { _ in loadBlameIfNeeded() }
        .modifier(PendingSearchConsumer(target: .prDoc(sessionID, path),
                                        consume: consumePendingSearch))
        .sheet(item: $historyRequest) { _ in
            let ref = session?.ref
            let sha = session?.details.head.sha
            BlameHistorySheet {
                guard let ref, let sha else {
                    throw GitHubClient.APIError(status: -1, message: "The PR session is no longer available.")
                }
                return try await BlameService.remoteHistory(client: state.client, ref: ref,
                                                            path: path, sha: sha)
            }
        }
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

    private func loadBlameIfNeeded() {
        guard blameVisible, let session, !markdown.isEmpty,
              blamePayloads == nil, blameNote == nil else { return }
        let ref = session.ref
        let sha = session.details.head.sha
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
        guard let session else { return }
        loading = true
        loadError = nil
        blamePayloads = nil
        blameNote = nil
        do {
            markdown = try await state.client.fileContent(session.ref, path: path,
                                                          at: session.details.head.sha)
            // Feed the all-files search palette (memory-only cache).
            state.cachePRContent(sessionID: sessionID, path: path, text: markdown)
        } catch {
            loadError = error.localizedDescription
        }
        loading = false
        loadBlameIfNeeded()
        updateActiveDocument()
    }

    private var activeDocumentID: String { "prDoc:" + sessionID + "|" + path }

    private func updateActiveDocument() {
        guard !loading, loadError == nil, let session else {
            state.unregisterActiveDocument(id: activeDocumentID)
            return
        }
        state.registerActiveDocument(ActiveDocument(
            id: activeDocumentID,
            exportBaseName: ((path as NSString).lastPathComponent as NSString).deletingPathExtension,
            markdown: markdown,
            proxy: proxy,
            remoteContext: RemoteResourceContext(ref: session.ref,
                                                 commitSHA: session.details.head.sha)
        ))
    }
}

// MARK: - Thread reply

struct ReplyTarget: Identifiable {
    let id: Int
}

/// A comment on a whole file — no line anchor. GitHub only accepts these
/// on the immediate-comment endpoint, so there is no "Add to Review" here.
struct FileCommentComposer: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    let sessionID: String
    let path: String

    @State private var text = ""
    @State private var posting = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Comment on \(path)")
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("Applies to the whole file, not a specific line")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                .frame(minHeight: 120, maxHeight: 280)
            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            HStack(spacing: 10) {
                Text("Posts immediately — file comments can't join a pending review.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                ProgressView()
                    .controlSize(.small)
                    .opacity(posting ? 1 : 0)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .fixedSize()
                Button("Comment") { post() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || posting)
                    .fixedSize()
            }
        }
        .padding(20)
        .frame(minWidth: 520)
    }

    private func post() {
        guard let session = state.session(sessionID) else { return }
        posting = true
        error = nil
        Task {
            do {
                try await state.client.createFileComment(
                    session.ref,
                    commitID: session.details.head.sha,
                    path: path,
                    body: text.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                await state.reloadComments(sessionID: sessionID)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            posting = false
        }
    }
}

struct ThreadReplyComposer: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    let sessionID: String
    let rootID: Int

    @State private var text = ""
    @State private var posting = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reply to thread")
                .font(.headline)
            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 110)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.35)))
            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Reply") { send() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || posting)
                if posting {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func send() {
        guard let session = state.session(sessionID) else { return }
        posting = true
        error = nil
        Task {
            do {
                try await state.client.replyToReviewComment(
                    session.ref, rootID: rootID,
                    body: text.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                await state.reloadComments(sessionID: sessionID)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            posting = false
        }
    }
}

// MARK: - Add PR sheet

struct AddPRSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var input = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Open Pull Request")
                .font(.headline)
            TextField("https://github.com/owner/repo/pull/123 or owner/repo#123", text: $input)
                .textFieldStyle(.roundedBorder)
                .frame(width: 420)
                .onSubmit { add() }
            Text("Works with private repos using your existing gh or git credentials.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: 420, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Open") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || input.trimmingCharacters(in: .whitespaces).isEmpty)
                if busy {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .padding(20)
    }

    private func add() {
        busy = true
        error = nil
        Task {
            do {
                try await state.addPR(input)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}
