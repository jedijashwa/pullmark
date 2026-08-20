import SwiftUI

// MARK: - PR overview

struct PROverviewView: View {
    @EnvironmentObject private var state: AppState
    let sessionID: String

    @State private var reviewPopoverVisible = false
    @State private var findSeed: String?
    @State private var deleteCommentID: Int?
    /// Conversation-card deletes confirm separately — they route to the
    /// issue-comment endpoint family, not /pulls/comments.
    @State private var deleteConversationID: Int?
    /// What the page's Conversation section renders. Snapshotted from
    /// the session and updated ONLY through mutatePreservingScroll: the
    /// quiet tick mutates the session directly, and rebuilding the page
    /// straight from it would yank the reader to the top whenever new
    /// conversation content lands (code-review catch).
    @State private var conversationPage = ConversationPageState()

    struct ConversationPageState: Equatable {
        var entries: [ConversationEntryPayload] = []
        var unavailable = false
    }
    @State private var pendingScrollFraction: Double?
    /// The signed-out cue's walkthrough (spec: github-connection).
    @State private var showGitHubSetup = false
    @StateObject private var proxy = WebViewProxy()
    @AppStorage(Theme.defaultsKey, store: UserDefaults.pullmark) private var themeRaw = Theme.standard.rawValue
    @AppStorage(DefaultsKeys.prDiscussionEnabled, store: UserDefaults.pullmark) private var prDiscussionEnabled = true
    /// Signed-out cue in the cockpit slot (spec: github-connection) —
    /// observed so connecting mid-session swaps the cue for the cockpit
    /// on the next tick without a reopen.
    @ObservedObject private var connection = GitHubClient.shared.connection

    /// Click-away drafts for discussion-list composers persist under a
    /// pseudo-path no repo file can have (repo paths never start with
    /// "/"); the keys themselves carry thread ids.
    private static let draftPath = "//overview"

    /// Shared thread-card round trips — the discussion list's cards are
    /// the same cards the file views render, wired to the same GitHub
    /// mutations (spec: pr-review-discussion).
    private var threadActions: ThreadCardActions {
        ThreadCardActions(state: state, sessionID: sessionID, proxy: proxy,
                          draftPath: Self.draftPath,
                          mutatePreservingScroll: mutatePreservingScroll)
    }

    /// Reader-in-place re-render: capture the scroll fraction before the
    /// mutation publishes, restore once the fresh page loads.
    private func mutatePreservingScroll(_ mutate: @escaping () -> Void) {
        proxy.scrollFraction { fraction in
            pendingScrollFraction = fraction
            mutate()
        }
    }

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
                Divider()
                let style = ThemeSelection.pageStyle(from: themeRaw)
                MarkdownWebView(
                    html: HTMLBuilder.documentPage(
                        markdown: session.details.body?.isEmpty == false
                            ? session.details.body!
                            : "_No description provided._",
                        title: session.details.title,
                        theme: style.theme,
                        customCSS: style.customCSS,
                        // A PR description isn't a file — a source-line
                        // coordinate in its margin would mean nothing.
                        lineNumberEligible: false,
                        conversation: conversationPage.entries,
                        conversationUnavailable: conversationPage.unavailable,
                        // The overview always offers the comment box,
                        // even on a silent PR.
                        conversationComposer: true
                    ),
                    onComposerDraft: { key, text in
                        threadActions.saveComposerDraft(key: key, text: text)
                    },
                    onOpenPRComment: { path, rootID in
                        state.pendingThreadReveal = .init(
                            sessionID: sessionID, path: path, rootID: rootID)
                        state.selection = .prFile(sessionID, path)
                    },
                    onOpenGitHubLink: { link, url, inverted in
                        state.handleGitHubLink(link, url: url, inverted: inverted)
                    },
                    onThreadReplySubmit: { rootID, body, draftKey in
                        threadActions.sendThreadReply(rootID: rootID, body: body,
                                                      draftKey: draftKey)
                    },
                    onThreadResolve: { rootID, resolved in
                        threadActions.setThreadResolved(rootID: rootID, resolved: resolved)
                    },
                    onReactionToggle: { commentID, content, reacted in
                        threadActions.handleReactionToggle(commentID: commentID,
                                                           content: content,
                                                           reacted: reacted)
                    },
                    onCommentEdit: { commentID, body, draftKey in
                        threadActions.handleCommentEdit(commentID: commentID, body: body,
                                                        draftKey: draftKey)
                    },
                    onCommentDelete: { deleteCommentID = $0 },
                    onConversationSubmit: { body, draftKey in
                        threadActions.sendConversationComment(body: body,
                                                              draftKey: draftKey)
                    },
                    onConversationReaction: { commentID, content, reacted, isReview in
                        threadActions.handleConversationReaction(
                            commentID: commentID, content: content,
                            reacted: reacted, isReview: isReview)
                    },
                    onConversationEdit: { commentID, body, draftKey in
                        threadActions.handleConversationEdit(commentID: commentID,
                                                             body: body, draftKey: draftKey)
                    },
                    onConversationDelete: { deleteConversationID = $0 },
                    onPageLoaded: {
                        // A model mutation re-rendered the page under the
                        // reader — put them back where they were.
                        if let fraction = pendingScrollFraction {
                            pendingScrollFraction = nil
                            proxy.restoreScrollFraction(fraction)
                        }
                        // Persisted click-away drafts survive reloads and
                        // relaunches, same as the file views.
                        proxy.setComposerDrafts(ComposerDraftStore.load(
                            ref: session.ref, headSHA: session.details.head.sha,
                            path: Self.draftPath))
                        // Restore find highlights if the page re-renders
                        // beneath an active find (same as the file views).
                        if state.findBarVisible, let query = proxy.activeFindQuery {
                            findSeed = query
                        }
                    },
                    onLightboxRequest: { presentLightbox($0, proxy: proxy, state: state) },
                    proxy: proxy
                )
                .modifier(PagePreferenceApplier(proxy: proxy))
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
            // The share item renders from this registration in the window
            // toolbar (AppToolbar); the review control is window-level too.
            .onAppear {
                var surface = SurfaceToolbar(id: "prOverview:" + sessionID)
                surface.shareURL = session.details.htmlUrl
                state.registerSurfaceToolbar(surface)
                conversationPage = ConversationPageState(
                    entries: conversationEntries(session),
                    unavailable: session.conversationUnavailable)
            }
            // Every later change — a quiet tick delivering new comments,
            // a fold-in from posting — reaches the page through the
            // scroll-preserving wrapper, never as a bare reload.
            .onChange(of: ConversationPageState(
                entries: conversationEntries(session),
                unavailable: session.conversationUnavailable)) { fresh in
                guard fresh != conversationPage else { return }
                mutatePreservingScroll { conversationPage = fresh }
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
            .modifier(DeleteCommentConfirmation(commentID: $deleteCommentID,
                                                onConfirm: { threadActions.deleteComment($0) }))
            .modifier(DeleteCommentConfirmation(commentID: $deleteConversationID,
                                                onConfirm: { threadActions.deleteConversationComment($0) }))
            // On the stable root, NOT the cue row: connecting from
            // inside the sheet removes the cue from the hierarchy, and
            // a sheet attached there would be torn down at the exact
            // moment it wants to show "Connected ✓"
            // (adversarial-review catch).
            .sheet(isPresented: $showGitHubSetup) { GitHubSetupSheet() }
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
            // Where the PR stands (spec: pr-cockpit) — absent until the
            // first cockpit fetch lands; absence is honest. Signed out,
            // the cockpit GraphQL can never land, so its empty slot
            // carries the one quiet cue instead (spec: github-connection;
            // demo reports the signed-in fiction, so never there).
            if let cockpit = session.cockpit {
                PRCockpitRow(cockpit: cockpit, prURL: session.details.htmlUrl)
            } else if connection.status == .notConnected {
                // .notConnected exactly — a connected user's cockpit
                // blip during a .checking pass must not flash a false
                // "signed out" (adversarial-review catch). Same label,
                // same outcome as everywhere else: Set Up… opens the
                // walkthrough directly (design-review catch).
                HStack(spacing: 6) {
                    Image(systemName: "person.crop.circle.badge.xmark")
                        .foregroundStyle(.secondary)
                    Text("Viewing signed out — commenting and reviewing are unavailable")
                        .foregroundStyle(.secondary)
                    Button("Set Up…") { showGitHubSetup = true }
                        .buttonStyle(.link)
                        .help("Walk through connecting PullMark to GitHub")
                }
                .font(.callout)
            }
            Text(filesSummary(session))
                .font(.callout)
                .foregroundStyle(.secondary)
            // Honesty about non-Markdown files: their threads have no
            // surface here, but they must not silently vanish (spec §2).
            // Unresolved only — the same rule as the sidebar badges.
            // With the review discussion list on, the list IS that
            // surface and this line retires.
            if !prDiscussionEnabled, hiddenCommentCount(session) > 0 {
                let count = hiddenCommentCount(session)
                Text(count == 1
                    ? "1 unresolved review comment on files not shown in PullMark"
                    : "\(count) unresolved review comments on files not shown in PullMark")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The conversation timeline payload (spec: pr-cockpit, revised) —
    /// issue comments and review verdicts chronological, each review
    /// carrying its inline threads nested beneath it. The graduated
    /// discussion toggle gates the threads; the composer lives in-page
    /// at the section's foot.
    private func conversationEntries(_ session: PRSession) -> [ConversationEntryPayload] {
        // Threads written before a rename carry the old path; join them
        // to the renamed file. Untrusted API data must not feed the
        // trapping initializer — first claim wins on a duplicate.
        let renames = Dictionary(session.files.compactMap { file in
            file.previousFilename.map { ($0, file.filename) }
        }, uniquingKeysWith: { first, _ in first })
        return PRConversation.payload(
            comments: session.issueComments,
            reviews: session.reviews,
            reviewComments: session.reviewComments,
            threadMeta: session.threadMeta,
            commentMeta: session.conversationMeta,
            reviewMeta: session.reviewMeta,
            reviewReactions: session.reviewReactions,
            viewer: state.viewerLogin,
            markdownPaths: Set(session.markdownFiles.map(\.filename)),
            renames: renames,
            includeThreads: prDiscussionEnabled)
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
            meta: session.threadMeta,
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
        if state.take(.commentOnFile) { fileCommentVisible = true }
    }
    @State private var reviewPopoverVisible = false
    /// Comment id awaiting the native delete confirmation (destructive
    /// actions never confirm with page chrome).
    @State private var deleteCommentID: Int?
    /// Reading position captured just before a model update re-renders the
    /// page (reaction fold-in, reply/edit/delete reload) — restored in
    /// handlePageLoaded so a chip click can't yank the reader to the top.
    /// Stamped with the view mode it was captured from: the next page to
    /// load may be a mode switch, whose scroll geometry is unrelated.
    private struct ScrollRestore {
        let fraction: Double
        let mode: Mode
        /// Expanded thread clusters at capture time — scroll position alone
        /// keeps the reader's place, not the card they had open.
        var openAnchors: [WebViewProxy.OpenThreadAnchor] = []
    }
    @State private var pendingScrollRestore: ScrollRestore?
    @AppStorage(DefaultsKeys.diffLayout, store: UserDefaults.pullmark) private var layoutRaw = DiffLayout.inline.rawValue
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
    @AppStorage(DefaultsKeys.outlinePanel, store: UserDefaults.pullmark) private var outlineVisible = false
    @AppStorage(Theme.defaultsKey, store: UserDefaults.pullmark) private var themeRaw = Theme.standard.rawValue
    @AppStorage(DefaultsKeys.blame, store: UserDefaults.pullmark) private var blameVisible = false
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
        updateSurfaceToolbar()
    }

    /// What the window-level toolbar (AppToolbar) shows for this surface.
    /// The mode picker round-trips through here; layout and blame presence
    /// follow the mode, so every mode change re-registers.
    private func updateSurfaceToolbar() {
        var surface = SurfaceToolbar(id: activeDocumentID)
        surface.modeOptions = Mode.allCases.map(\.rawValue)
        surface.mode = mode.rawValue
        surface.setMode = { raw in
            if let newMode = Mode(rawValue: raw) { mode = newMode }
        }
        surface.showsLayout = mode == .renderedDiff
        // A brand-new file renders inline regardless: split mode would show
        // an all-hatched old column against the untinted document.
        surface.layoutDisabledReason = file?.status == "added"
            ? "New files always render inline — there is no old side to compare"
            : nil
        surface.blameAvailable = mode == .result
        state.registerSurfaceToolbar(surface)
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
            .task(id: loadTaskID) { await load() }
            .onAppear { updateSurfaceToolbar() }
            .onDisappear {
                state.unregisterActiveDocument(id: activeDocumentID)
            }
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
            deleteCommentID: $deleteCommentID,
            onDeleteComment: { threadActions.deleteComment($0) },
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

    /// Shared thread-card round trips (ThreadCardActions) — this view
    /// contributes its mode-aware scroll preservation and drafts keyed
    /// to its own path.
    private var threadActions: ThreadCardActions {
        ThreadCardActions(state: state, sessionID: sessionID, proxy: proxy,
                          draftPath: path,
                          mutatePreservingScroll: mutatePreservingScroll)
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

    /// Comments still in the local queue (everything else in the unified
    /// pending list lives in the adopted review on GitHub) — drives the
    /// "Not synced" tag on anchored pending cards.
    private var queuedCommentIDs: Set<String> {
        Set((session?.queuedComments ?? []).map(\.id))
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
                                                    meta: session?.threadMeta ?? [:],
                                                    viewer: state.viewerLogin),
                                            pending: file.status == "removed" ? nil
                                                : ThreadVisibility.resultPending(
                                                    filePendingComments, path: path,
                                                    queuedIDs: queuedCommentIDs),
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
                                            patch: file.patch ?? "",
                                            viewer: state.viewerLogin,
                                            queuedIDs: queuedCommentIDs),
                patchLines: file.patch.map(PatchComposerLines.payloads(patch:)),
                reviewPending: reviewPending
            )
        case .renderedDiff:
            var segments = DiffPageBuilder.segments(old: baseText ?? "", new: headText ?? "")
            let threads = fileThreadGroups
            let viewer = state.viewerLogin
            let placed = ReviewThreads.place(threads, in: segments,
                                             meta: session?.threadMeta ?? [:],
                                             viewer: viewer)
            segments = PendingAnchors.place(filePendingComments, in: placed.segments,
                                            queuedIDs: queuedCommentIDs)
            func payload(_ thread: ReviewThread) -> ThreadPayload {
                let meta = session?.threadMeta[thread.root.id]
                return ThreadPayload(lineLabel: thread.lineLabel,
                                     comments: thread.comments.map {
                                         CommentPayload($0, meta: meta, viewer: viewer)
                                     },
                                     rootID: thread.root.id,
                                     resolved: meta?.isResolved)
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
                onComposerDraft: { key, text in
                    threadActions.saveComposerDraft(key: key, text: text)
                },
                remoteContext: remoteContext,
                onOpenRemoteFile: { repoPath in
                    state.openRemoteDoc(sessionID: sessionID, path: repoPath)
                },
                onOpenGitHubLink: { link, url, inverted in
                    state.handleGitHubLink(link, url: url, inverted: inverted)
                },
                onOutline: { outline = $0 },
                onActiveSection: { activeSection = $0.isEmpty ? nil : $0 },
                onThreadReplySubmit: { rootID, body, draftKey in
                    threadActions.sendThreadReply(rootID: rootID, body: body,
                                                  draftKey: draftKey)
                },
                onThreadResolve: { rootID, resolved in
                    threadActions.setThreadResolved(rootID: rootID, resolved: resolved)
                },
                onReactionToggle: { commentID, content, reacted in
                    threadActions.handleReactionToggle(commentID: commentID,
                                                       content: content, reacted: reacted)
                },
                onCommentEdit: { commentID, body, draftKey in
                    threadActions.handleCommentEdit(commentID: commentID, body: body,
                                                    draftKey: draftKey)
                },
                onCommentDelete: { deleteCommentID = $0 },
                onResolvedVisibility: { state.resolvedConversationsVisible = $0 },
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
        // The overview's View in File jump needs the mode that carries
        // thread cards; the reveal itself runs in handlePageLoaded once
        // the page (re)loads.
        .onAppear { consumeRevealModeSwitch() }
        .onChange(of: state.pendingThreadReveal) { _ in consumeRevealModeSwitch() }
    }

    private func consumeRevealModeSwitch() {
        guard let reveal = state.pendingThreadReveal,
              reveal.sessionID == sessionID, reveal.path == path else { return }
        if mode != .renderedDiff { mode = .renderedDiff }
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
        guard let session else {
            // The page already cleared its composer — never drop the text.
            threadActions.restoreDraftAfterFailure(key: submission.draftKey,
                                                   text: submission.body)
            state.lastError = String(localized: "Could not post the comment — the PR session is no longer available. Your text was kept as a draft.")
            return
        }
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
                threadActions.restoreDraftAfterFailure(key: submission.draftKey,
                                                       text: submission.body)
                state.lastError = String(localized: "Could not post the comment: \(error.localizedDescription)")
            }
        }
    }

    /// Re-renders the page from a model mutation with the reader kept in
    /// place: the scroll fraction is captured first and restored once the
    /// fresh page loads (see handlePageLoaded).
    private func mutatePreservingScroll(_ mutate: @escaping () -> Void) {
        let capturedMode = mode
        proxy.openThreadAnchors { anchors in
            proxy.scrollFraction { fraction in
                if fraction == nil && anchors.isEmpty {
                    pendingScrollRestore = nil
                } else {
                    pendingScrollRestore = ScrollRestore(fraction: fraction ?? 0,
                                                         mode: capturedMode,
                                                         openAnchors: anchors)
                }
                mutate()
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
        // A PR update can change the file's status (added → modified),
        // which drives the layout picker's disabled reason — re-register
        // like the other surfaces do on load-state changes.
        updateSurfaceToolbar()
    }

    private func handlePageLoaded() {
        // A model mutation re-rendered the page under the reader (reaction
        // fold-in, reply/edit/delete reload): put them back where they
        // were — but only in the mode the position was captured from. A
        // mode switch loading in between must keep its natural top.
        if let restore = pendingScrollRestore {
            pendingScrollRestore = nil
            if restore.mode == mode {
                // Cards first (they add height), then the scroll fraction.
                proxy.restoreOpenThreadAnchors(restore.openAnchors)
                proxy.restoreScrollFraction(restore.fraction)
            }
        }
        // The overview's View in File jump: this page carries the thread
        // cards (rendered diff), so land on the one asked for. A beat
        // after load so the page's own layout settles first.
        if let reveal = state.pendingThreadReveal,
           reveal.sessionID == sessionID, reveal.path == path,
           mode == .renderedDiff {
            state.pendingThreadReveal = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                proxy.revealThread(rootID: reveal.rootID)
            }
        }
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
    @Binding var deleteCommentID: Int?
    let onDeleteComment: (Int) -> Void
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
            .modifier(DeleteCommentConfirmation(commentID: $deleteCommentID,
                                                onConfirm: onDeleteComment))
    }
}

/// Toolbar navigation for a PR file: back to the overview, previous/next
/// Markdown file, and a jump menu — the sidebar stays optional. Extracted
/// from PRFileView's toolbar to keep the type-checker solvent.
struct PRFileNavigation: View {
    @EnvironmentObject private var state: AppState
    let sessionID: String
    let path: String
    let session: PRSession

    var body: some View {
        Button {
            state.selection = .prOverview(sessionID)
        } label: {
            // Icon-only: the toolbar also holds the mode picker, layout,
            // and comment buttons — a titled button overflows the whole
            // strip at the minimum window width. The PR glyph, not a
            // chevron: this is UP to the overview, and chevron.backward
            // now belongs exclusively to global Back
            // (spec: back-forward-navigation §8).
            Label("PR Overview", systemImage: "arrow.triangle.pull")
                .labelStyle(.iconOnly)
        }
        .help("The pull request overview (\(session.ref.repo) #\(session.ref.number))")
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
        guard let index else {
            let count = session.markdownFiles.count
            return count == 1 ? String(localized: "1 file")
                              : String(localized: "\(count) files")
        }
        return String(localized: "\(index + 1) of \(session.markdownFiles.count)")
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
    @AppStorage(DefaultsKeys.outlinePanel, store: UserDefaults.pullmark) private var outlineVisible = false
    @AppStorage(Theme.defaultsKey, store: UserDefaults.pullmark) private var themeRaw = Theme.standard.rawValue
    @AppStorage(DefaultsKeys.blame, store: UserDefaults.pullmark) private var blameVisible = false
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
    /// HTTP status behind `error`, when the failure was an APIError —
    /// gates the setup affordance to auth-shaped failures only (a URL
    /// typo while signed out must not pitch GitHub setup).
    @State private var errorStatus: Int?
    @State private var showSetup = false
    @ObservedObject private var connection = GitHubClient.shared.connection

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Open Pull Request")
                .font(.headline)
            TextField("https://github.com/owner/repo/pull/123 or owner/repo#123", text: $input)
                .textFieldStyle(.roundedBorder)
                .frame(width: 420)
                .onSubmit { add() }
            HStack(spacing: 4) {
                Text("Works with private repos using your existing gh or git credentials.")
                Button("Connection status…") {
                    dismiss()
                    SettingsOpener.open(tab: "general", anchor: "github")
                }
                .buttonStyle(.link)
                .font(.caption)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: 420, alignment: .leading)
                // Auth-shaped failures only: 401 always, 404 while
                // signed out (private-without-auth reads as 404) —
                // offer the fix at the moment of the wall.
                if let status = errorStatus,
                   GitHubAuthRules.isAuthShaped(
                       status: status,
                       signedOut: connection.status == .notConnected) {
                    Button("Set Up GitHub Access…") { showSetup = true }
                }
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
        .sheet(isPresented: $showSetup) { GitHubSetupSheet() }
    }

    private func add() {
        busy = true
        error = nil
        errorStatus = nil
        Task {
            do {
                try await state.addPR(input)
                dismiss()
            } catch {
                self.error = error.localizedDescription
                self.errorStatus = (error as? GitHubClient.APIError)?.status
            }
            busy = false
        }
    }
}
