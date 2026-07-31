import SwiftUI

// MARK: - PR overview

struct PROverviewView: View {
    @EnvironmentObject private var state: AppState
    let sessionID: String

    @State private var confirmation: String?
    @State private var conversationText = ""
    @State private var reviewPopoverVisible = false
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
                if session.commentsUnavailable {
                    CommentsUnavailableBanner(sessionID: sessionID)
                }
                if state.findBarVisible {
                    FindBar(proxy: proxy, seed: $findSeed)
                }
                header(session)
                    .padding([.horizontal, .top], 20)
                    .padding(.bottom, 12)
                conversationSection(session)
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
                    onLightboxRequest: { presentLightbox($0, proxy: proxy, state: state) },
                    proxy: proxy
                )
                .modifier(ContentWidthApplier(proxy: proxy))
                .background(ThemePaper.color(for: themeRaw))
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
            }
            .navigationTitle(String("\(session.ref.owner)/\(session.ref.repo) #\(session.ref.number)"))
            .toolbar {
                // The review control itself is window-level (ContentView's
                // toolbar) so it survives toolbar overflow on every surface.
                ToolbarItem {
                    ShareLink(item: session.details.htmlUrl)
                        .help("Share a link to this pull request")
                }
            }
            // Review Changes… (menu or shortcut) opens the popover on
            // whichever PR surface is active — here, the overview.
            .modifier(DocumentCommandHandler(state: state) { _ in
                if state.take(.reviewChanges) { reviewPopoverVisible = true }
            })
            // Presented from the root view, not the toolbar button, so it
            // opens even while the toolbar has collapsed the review
            // control into the overflow menu (see ReviewPopoverPresenter).
            .modifier(ReviewPopoverPresenter(sessionID: sessionID,
                                             isPresented: $reviewPopoverVisible))
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
            // Honesty about non-Markdown files: their threads have no
            // surface here, but they must not silently vanish (spec §2).
            if hiddenCommentCount(session) > 0 {
                let count = hiddenCommentCount(session)
                Text("\(count) review comment\(count == 1 ? "" : "s") on files not shown in PullMark")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let confirmation {
                Label(confirmation, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            }
        }
    }

    /// Conversation comments post immediately to the PR's timeline —
    /// separate from any review verdict. The review itself (pending
    /// comments, summary, verdict) lives in the toolbar's review popover.
    private func conversationSection(_ session: PRSession) -> some View {
        HStack(spacing: 10) {
            TextField("Comment on the pull request conversation…",
                      text: $conversationText, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
            ProgressView()
                .controlSize(.small)
                .opacity(postingComment ? 1 : 0)
            Button("Post") { postConversationComment() }
                .fixedSize()
                .disabled(conversationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || postingComment)
                .help("Post to the PR conversation right away (not part of a review)")
        }
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

    private func hiddenCommentCount(_ session: PRSession) -> Int {
        ThreadVisibility.hiddenFileCommentCount(
            comments: session.reviewComments,
            visiblePaths: Set(session.markdownFiles.map(\.filename)))
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
        if state.take(.reviewChanges) { reviewPopoverVisible = true }
    }
    @State private var reviewPopoverVisible = false
    @AppStorage(DefaultsKeys.diffLayout) private var layoutRaw = DiffLayout.inline.rawValue
    @State private var baseText: String?
    @State private var headText: String?
    @State private var loading = true
    @State private var loadError: String?
    @State private var fileCommentVisible = false
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
            // View ▸ Show Resolved Conversations flips in place — no page
            // reload, the reader's position survives.
            .onChange(of: state.resolvedConversationsVisible) {
                proxy.setResolvedConversationsVisible($0)
            }
            .modifier(PendingSearchConsumer(target: .prFile(sessionID, path),
                                            consume: consumePendingSearch))
            // Presented from the root view, not the toolbar button, so it
            // opens even while the toolbar has collapsed the review
            // control into the overflow menu (see ReviewPopoverPresenter).
            .modifier(ReviewPopoverPresenter(sessionID: sessionID,
                                             isPresented: $reviewPopoverVisible))
            .modifier(fileSheets)
    }

    /// The sheets, bundled off the main modifier chain (type-checker
    /// budget again). Line comments and thread replies compose in-page
    /// now (spec §5) — only the whole-file composer and blame history
    /// remain sheet-shaped.
    private var fileSheets: PRFileSheets {
        PRFileSheets(
            fileCommentVisible: $fileCommentVisible,
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

    /// Grouped threads for this file, and the viewer's pending comments on
    /// it — one source of truth with the review popover (spec §3).
    private var fileThreadGroups: [ReviewThread] {
        ReviewThreads.group((session?.reviewComments ?? []).filter { $0.path == path })
    }

    private var filePendingComments: [PendingComment] {
        (session?.pendingComments ?? []).filter { $0.path == path }
    }

    private var html: String {
        guard let file else { return "" }
        let style = ThemeSelection.pageStyle(from: themeRaw)
        let theme = style.theme
        let reviewPending = session?.reviewInProgress ?? false
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
                                            blameNote: blameVisible ? blameNote : nil,
                                            threads: file.status == "removed" ? nil
                                                : ThreadVisibility.resultAnchored(
                                                    fileThreadGroups,
                                                    meta: session?.threadMeta ?? [:]),
                                            pending: file.status == "removed" ? nil
                                                : ThreadVisibility.resultPending(
                                                    filePendingComments, path: path),
                                            commentableLines: file.status == "removed" ? nil
                                                : CommentableLines.payload(patch: file.patch),
                                            reviewPending: reviewPending)
        case .sourceDiff:
            let patch = file.patch ?? "No textual diff available for this file."
            return HTMLBuilder.patchPage(
                patch: patch,
                title: path,
                theme: theme,
                customCSS: style.customCSS,
                threads: PatchAnchors.place(threads: fileThreadGroups,
                                            meta: session?.threadMeta ?? [:],
                                            pending: filePendingComments,
                                            patch: file.patch ?? ""),
                patchLines: file.patch.map(PatchComposerLines.payloads(patch:)),
                reviewPending: reviewPending
            )
        case .renderedDiff:
            var segments = DiffPageBuilder.segments(old: baseText ?? "", new: headText ?? "")
            let threads = fileThreadGroups
            let placed = ReviewThreads.place(threads, in: segments,
                                             meta: session?.threadMeta ?? [:])
            segments = PendingAnchors.place(filePendingComments, in: placed.segments)
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
                                        allNew: allNew,
                                        commentableLines: CommentableLines.payload(patch: file.patch),
                                        reviewPending: reviewPending)
        }
    }

    /// The web view + optional outline column (extracted from body for the
    /// type-checker).
    private var documentArea: some View {
        HStack(spacing: 0) {
            MarkdownWebView(
                html: html,
                onComposerSubmit: { handleComposerSubmit($0) },
                onComposerDraft: { key, text in saveComposerDraft(key: key, text: text) },
                remoteContext: remoteContext,
                onOpenRemoteFile: { repoPath in
                    state.openRemoteDoc(sessionID: sessionID, path: repoPath)
                },
                onOutline: { outline = $0 },
                onActiveSection: { activeSection = $0.isEmpty ? nil : $0 },
                onThreadReplySubmit: { rootID, body, draftKey in
                    sendThreadReply(rootID: rootID, body: body, draftKey: draftKey)
                },
                onThreadResolve: { rootID, resolved in
                    setThreadResolved(rootID: rootID, resolved: resolved)
                },
                onResolvedVisibility: { state.resolvedConversationsVisible = $0 },
                onBlameHistory: { start, end in
                    historyRequest = BlameHistoryRequest(lineStart: start, lineEnd: end)
                },
                onStats: { stats = $0 },
                onPageLoaded: { handlePageLoaded() },
                onLightboxRequest: { presentLightbox($0, proxy: proxy, state: state) },
                proxy: proxy
            )
            .modifier(ContentWidthApplier(proxy: proxy))
            .overlay(alignment: .bottomTrailing) {
                if mode == .result, state.lightbox == nil, let stats {
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

    /// A submission from the in-page composer: "Start a review" / "Add
    /// review comment" queue into the pending review (the existing sync
    /// path); "Add single comment" posts immediately, outside any review.
    /// A failed immediate post restores the text as a draft on the block
    /// so nothing typed is ever lost.
    private func handleComposerSubmit(_ submission: ComposerSubmission) {
        let comment = PendingComment(path: path,
                                     lineStart: submission.lineStart,
                                     lineEnd: submission.lineEnd,
                                     side: submission.side,
                                     body: submission.body)
        if submission.review {
            state.addPendingComment(sessionID: sessionID, comment)
            return
        }
        guard let session else { return }
        Task {
            do {
                try await state.client.createComment(
                    session.ref,
                    commitID: session.details.head.sha,
                    comment: comment
                )
                await state.reloadComments(sessionID: sessionID)
                // If a pending review exists, GitHub may have absorbed the
                // "immediate" comment into it — re-adopt so the app shows
                // where the comment actually landed.
                await state.adoptPendingReview(sessionID: sessionID)
            } catch {
                restoreDraftAfterFailure(key: submission.draftKey, text: submission.body)
                state.lastError = "Could not post the comment: \(error.localizedDescription)"
            }
        }
    }

    private func sendThreadReply(rootID: Int, body: String, draftKey: String) {
        guard let session else { return }
        Task {
            do {
                try await state.client.replyToReviewComment(session.ref, rootID: rootID,
                                                            body: body)
                await state.reloadComments(sessionID: sessionID)
            } catch {
                restoreDraftAfterFailure(key: draftKey, text: body)
                state.lastError = "Could not post the reply: \(error.localizedDescription)"
            }
        }
    }

    /// Click-away draft sync from the page; empty text discards.
    private func saveComposerDraft(key: String, text: String) {
        guard let session else { return }
        ComposerDraftStore.save(jsKey: key, text: text, ref: session.ref,
                                headSHA: session.details.head.sha, path: path)
    }

    /// A post failed after the page already cleared its composer: put the
    /// text back on disk AND into the live page so reopening restores it.
    private func restoreDraftAfterFailure(key: String, text: String) {
        guard !key.isEmpty else { return }
        saveComposerDraft(key: key, text: text)
        proxy.setComposerDrafts([key: text])
    }

    /// Extracted from body so the modifier chain stays inside the
    /// type-checker's budget.
    ///
    /// Declaration order is also collapse priority: when the window
    /// narrows, SwiftUI moves LATER-declared items into the "»" overflow
    /// menu first (verified empirically). Navigation (Back/step/jump) is
    /// wayfinding and must survive the squeeze, so it comes first; the
    /// outline toggle, layout picker, blame toggle, and comment shortcut
    /// are the sacrificial tail — the same order Xcode and Safari shed
    /// secondary items. (The review control outranks them all: it is
    /// window-level, see ContentView.)
    @ToolbarContentBuilder
    private var fileToolbar: some ToolbarContent {
        // The sidebar shouldn't be the only way around a PR: back to
        // the overview, and step or jump between its Markdown files.
        ToolbarItemGroup(placement: .navigation) {
            if let session {
                PRFileNavigation(sessionID: sessionID, path: path, session: session)
            }
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
            OutlineToggle(visible: $outlineVisible)
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
        // A fresh page starts with resolved conversations hidden; re-apply
        // the window's current choice.
        if state.resolvedConversationsVisible {
            proxy.setResolvedConversationsVisible(true)
        }
        // Persisted click-away drafts survive reloads and relaunches: push
        // this file's drafts back into the page (spec §5).
        if let session {
            proxy.setComposerDrafts(ComposerDraftStore.load(
                ref: session.ref, headSHA: session.details.head.sha, path: path))
        }
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

/// PRFileView's sheets as one modifier — keeps the view's main chain
/// inside the type-checker's budget. Line comments, suggestions, and
/// thread replies compose in-page now (spec §5).
private struct PRFileSheets: ViewModifier {
    @Binding var fileCommentVisible: Bool
    @Binding var historyRequest: BlameHistoryRequest?
    let sessionID: String
    let path: String
    let history: () async throws -> HistoryPanelData

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $fileCommentVisible) {
                FileCommentComposer(sessionID: sessionID, path: path)
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
                HStack(spacing: 0) {
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
                        onLightboxRequest: { presentLightbox($0, proxy: proxy, state: state) },
                        proxy: proxy
                    )
                    .modifier(ContentWidthApplier(proxy: proxy))
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

// MARK: - Whole-file comments

/// A comment on a whole file — no line anchor. GitHub only accepts these
/// on the immediate-comment endpoint, so it can never join a pending review.
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
