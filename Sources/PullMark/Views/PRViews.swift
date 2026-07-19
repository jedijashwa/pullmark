import SwiftUI

// MARK: - PR overview

struct PROverviewView: View {
    @EnvironmentObject private var state: AppState
    let sessionID: String

    @State private var reviewSummary = ""
    @State private var submitting = false
    @State private var confirmation: String?
    @State private var findSeed: String?
    @StateObject private var proxy = WebViewProxy()
    @AppStorage(Theme.defaultsKey) private var themeRaw = Theme.github.rawValue

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
                if !session.drafts.isEmpty {
                    draftsSection(session)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)
                }
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
                .background(Color(nsColor: .textBackgroundColor))
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

    private func draftsSection(_ session: PRSession) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
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

                TextField("Review summary (optional)", text: $reviewSummary, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Menu("Submit Review") {
                        Button("Comment") { submit(event: "COMMENT") }
                        Button("Approve") { submit(event: "APPROVE") }
                        Button("Request Changes") { submit(event: "REQUEST_CHANGES") }
                    }
                    .fixedSize()
                    Button("Save as Pending on GitHub") { submit(event: nil) }
                        .help("Uploads the comments as a pending (draft) review you can finish on GitHub")
                    if submitting {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                }
                .disabled(submitting)
            }
            .padding(4)
        } label: {
            Label("Review draft — \(session.drafts.count) comment\(session.drafts.count == 1 ? "" : "s")",
                  systemImage: "text.bubble")
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
    @AppStorage(DefaultsKeys.diffLayout) private var layoutRaw = DiffLayout.inline.rawValue
    @State private var baseText: String?
    @State private var headText: String?
    @State private var loading = true
    @State private var loadError: String?
    @State private var commentTarget: CommentTarget?
    @State private var outline: [OutlineItem] = []
    @State private var activeSection: String?
    @State private var stats: DocumentStats?
    @State private var replyTarget: ReplyTarget?
    @State private var findSeed: String?
    @StateObject private var proxy = WebViewProxy()
    @AppStorage(DefaultsKeys.outlinePanel) private var outlineVisible = false
    @AppStorage(Theme.defaultsKey) private var themeRaw = Theme.github.rawValue
    @AppStorage(DefaultsKeys.blame) private var blameVisible = false
    @State private var blamePayloads: [BlameRunPayload]?
    @State private var blameNote: String?
    @State private var historyRequest: BlameHistoryRequest?

    private var layout: DiffLayout { DiffLayout(rawValue: layoutRaw) ?? .inline }

    private var session: PRSession? { state.session(sessionID) }
    private var file: PullRequestFile? { session?.files.first { $0.filename == path } }

    var body: some View {
        VStack(spacing: 0) {
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
                HSplitView {
                    MarkdownWebView(
                        html: html,
                        onCommentRequest: { message in
                            commentTarget = CommentTarget(
                                lineStart: message.lineStart,
                                lineEnd: message.lineEnd,
                                side: message.side,
                                suggestionSeed: suggestionSeed(for: message)
                            )
                        },
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
                .background(Color(nsColor: .textBackgroundColor))
            }
        }
        .navigationTitle(path)
        .toolbar {
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
                    .help("Inline or side-by-side rendered diff")
                }
            }
            ToolbarItem {
                if mode == .result {
                    BlameToggle(visible: $blameVisible)
                }
            }
        }
        .task(id: sessionID + "|" + path + "|" + (session?.details.head.sha ?? "")) {
            await load()
        }
        .onDisappear {
            state.unregisterActiveDocument(id: activeDocumentID)
        }
        .onChange(of: blameVisible) { _ in loadBlameIfNeeded() }
        .onChange(of: mode) { _ in
            loadBlameIfNeeded()
            updateActiveDocument()
        }
        .modifier(PendingSearchConsumer(target: .prFile(sessionID, path),
                                        consume: consumePendingSearch))
        .sheet(item: $commentTarget) { target in
            CommentComposer(sessionID: sessionID, path: path, target: target)
        }
        .sheet(item: $replyTarget) { target in
            ThreadReplyComposer(sessionID: sessionID, rootID: target.id)
        }
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
            let outdated = placed.outdated.map { thread in
                ThreadPayload(lineLabel: thread.lineLabel,
                              comments: thread.comments.map(CommentPayload.init),
                              rootID: thread.root.id,
                              resolved: session?.threadMeta[thread.root.id]?.isResolved)
            }
            return HTMLBuilder.diffPage(segments: segments,
                                        outdatedThreads: outdated,
                                        layout: layout == .split ? "split" : "inline",
                                        remote: HTMLBuilder.RemoteAssets(filePath: path),
                                        title: path,
                                        theme: theme,
                                        customCSS: style.customCSS)
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
}

// MARK: - Comment composer

struct CommentComposer: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    let sessionID: String
    let path: String
    let target: CommentTarget

    @State private var text = ""
    @State private var posting = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Comment on \(path)")
                .font(.headline)
            Text(draft.lineDescription)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 130)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.35))
                )

            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            HStack {
                if target.suggestionSeed != nil {
                    Button {
                        insertSuggestion()
                    } label: {
                        Label("Insert Suggestion", systemImage: "plus.diamond")
                    }
                    .help("Insert a ```suggestion block pre-filled with the current lines")
                }
                Text("Comments must target lines that are part of the PR diff.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add to Review") {
                    state.addDraft(sessionID: sessionID, draft)
                    dismiss()
                }
                .disabled(trimmed.isEmpty || posting)
                Button("Comment Now") { postNow() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty || posting)
                if posting {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .padding(20)
        .frame(width: 500)
    }

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// GitHub applies the suggestion in place of the commented lines, so the
    /// block starts as their current content for the user to edit.
    private func insertSuggestion() {
        guard let seed = target.suggestionSeed else { return }
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        text += "```suggestion\n\(seed)\n```\n"
    }

    private var draft: DraftComment {
        DraftComment(path: path, lineStart: target.lineStart, lineEnd: target.lineEnd,
                     side: target.side, body: trimmed)
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
    @AppStorage(Theme.defaultsKey) private var themeRaw = Theme.github.rawValue
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
                .background(Color(nsColor: .textBackgroundColor))
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
