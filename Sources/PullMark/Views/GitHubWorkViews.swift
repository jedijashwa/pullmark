import AppKit
import SwiftUI

// The sidebar's GitHub work (spec: github-work): bucket and repository
// groups, their rows, the follow sheet, and the issue document view.

/// One bucket or followed-repository row (spec §7): unread dot, title
/// (semibold while unread), `owner/repo#number` plus the reason when it
/// isn't obvious, the Markdown-file badge for pull requests, and — in
/// the mixed layout — a type glyph. Click opens; arrow keys merely
/// select; the context menu offers Open, GitHub, and the unread
/// override.
struct WorkItemRow: View {
    @EnvironmentObject private var state: AppState
    @AppStorage(DefaultsKeys.zoom, store: UserDefaults.pullmark) private var zoom = 1.0
    let item: GitHubWork.Item
    /// The followed repository this row sits under, for its unread rule.
    var repoID: String? = nil
    /// Which reason the row's group already states (its bucket).
    var bucket: GitHubWork.Bucket? = nil
    var showsKind = false

    var body: some View {
        let fonts = ChromeFonts(zoom: zoom)
        let unread = state.isUnread(item, inRepo: repoID)
        HStack(spacing: 6) {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 6, height: 6)
                .opacity(unread ? 1 : 0)
            if showsKind {
                Image(systemName: item.kind == .pr ? "arrow.triangle.pull" : "smallcircle.filled.circle")
                    .font(fonts.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .lineLimit(1)
                    .font(fonts.row)
                    .fontWeight(unread ? .semibold : .regular)
                Text(subtitle)
                    .font(fonts.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if item.kind == .pr, let count = state.inboxMDCount(item), count > 0 {
                Label("\(count)", systemImage: "doc.text")
                    .font(fonts.caption)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
                    .help(count == 1 ? String(localized: "1 Markdown file") : String(localized: "\(count) Markdown files"))
            }
        }
        .contentShape(Rectangle())
        // Click opens; the gesture rides alongside List selection so the
        // row still highlights and arrow keys merely select.
        .simultaneousGesture(TapGesture().onEnded { state.openWorkItem(item) })
        .help(item.kind == .pr && state.inboxMDCount(item) == 0
            ? String(localized: "No Markdown files in this pull request") : item.title)
        .contextMenu {
            Button("Open") { state.openWorkItem(item) }
            Button("Reveal on GitHub") { NSWorkspace.shared.open(webURL) }
            Divider()
            Picker("Unread", selection: Binding(
                get: { state.workUnreadOverrides[item.id]?.rawValue ?? "" },
                set: { state.setWorkUnreadOverride(GitHubWork.ItemUnreadOverride(rawValue: $0), for: item.id) }
            )) {
                Text("Use Repository Setting").tag("")
                Text("Always").tag(GitHubWork.ItemUnreadOverride.always.rawValue)
                Text("Never").tag(GitHubWork.ItemUnreadOverride.never.rawValue)
            }
            .pickerStyle(.inline)
        }
    }

    private var webURL: URL {
        let kind = item.kind == .pr ? "pull" : "issues"
        return URL(string: "https://github.com/\(item.ref.owner)/\(item.ref.repo)/\(kind)/\(item.ref.number)")!
    }

    /// `owner/repo#number`, then the roles the group doesn't already
    /// state, then draft.
    private var subtitle: String {
        var parts = [item.id]
        let stated = bucket?.role
        let extra: [(GitHubWork.Role, String)] = [
            (.reviewRequested, String(localized: "review requested")),
            (.assigned, String(localized: "assigned")),
            (.created, String(localized: "yours")),
            (.participating, String(localized: "participating")),
        ]
        for (role, label) in extra where item.roles.contains(role) && role != stated {
            parts.append(label)
        }
        if item.draft { parts.append(String(localized: "draft")) }
        return parts.joined(separator: " · ")
    }
}

/// A collapsible group of rows with an unread count in its header and a
/// trailing Show more… while pages remain (spec §5). Empty groups render
/// nothing — the caller hides them.
struct WorkGroup: View {
    @EnvironmentObject private var state: AppState
    @AppStorage(DefaultsKeys.zoom, store: UserDefaults.pullmark) private var zoom = 1.0
    let title: String
    let systemImage: String
    let items: [GitHubWork.Item]
    /// The header's count when the group mixes kinds ("6 · 14"); nil
    /// shows the unread count alone.
    var mixedCount: String? = nil
    var repoID: String? = nil
    var bucket: GitHubWork.Bucket? = nil
    var showsKind = false
    var moreKey: String? = nil
    /// Right-click actions on the header (Unfollow, unread rule).
    var headerMenu: (() -> AnyView)? = nil
    @State private var expanded = true

    var body: some View {
        let fonts = ChromeFonts(zoom: zoom)
        DisclosureGroup(isExpanded: $expanded.preloadingOutlineRowsBeforeCollapse()) {
            ForEach(items) { item in
                WorkItemRow(item: item, repoID: repoID, bucket: bucket, showsKind: showsKind)
                    .tag(SidebarSelection.inboxItem(groupTag + item.id))
            }
            if let moreKey, state.work.moreAvailable.contains(moreKey) {
                Button {
                    state.loadMoreWork(bucket: bucket, repoID: repoID)
                } label: {
                    HStack(spacing: 6) {
                        Text("Show more…")
                            .font(fonts.caption)
                        if state.workLoadingGroups.contains(moreKey) {
                            ProgressView().controlSize(.mini)
                        }
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(state.workLoadingGroups.contains(moreKey))
            }
        } label: {
            let header = HStack(spacing: 6) {
                Label {
                    Text(title)
                        .font(fonts.row)
                        .lineLimit(1)
                } icon: {
                    Image(systemName: systemImage)
                        .foregroundStyle(.secondary)
                }
                let unread = state.unreadCount(items, inRepo: repoID)
                if let mixedCount {
                    Spacer(minLength: 2)
                    Text(mixedCount)
                        .font(fonts.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(String(localized: "\(items.count) items"))
                } else if unread > 0 {
                    Spacer(minLength: 2)
                    Text("\(unread)")
                        .font(fonts.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("\(unread) unread")
                }
            }
            if let headerMenu {
                header.contextMenu { headerMenu() }
            } else {
                header
            }
        }
    }

    /// Selection tags must be unique across the whole sidebar; the same
    /// item can sit in several groups.
    private var groupTag: String {
        (bucket.map { "b:" + $0.rawValue } ?? ("r:" + (repoID ?? ""))) + "|"
    }
}

/// A followed repository's queue (spec §3) — Unfollow and the unread
/// rule live on its header.
struct FollowedRepoGroup: View {
    @EnvironmentObject private var state: AppState
    let repo: GitHubWork.FollowedRepo
    /// nil mixes both kinds (the involvement layout).
    var kind: GitHubWork.Kind? = nil

    var body: some View {
        let items = state.work.items(inRepo: repo.id, kind: kind)
        let prs = items.filter { $0.kind == .pr }.count
        let issues = items.filter { $0.kind == .issue }.count
        // A repository with nothing of this kind open renders nothing in
        // the type layout; the mixed group always shows (Unfollow lives
        // on its header).
        if kind != nil, items.isEmpty {
            EmptyView()
        } else {
        WorkGroup(title: repo.id, systemImage: "book.closed", items: items,
                  mixedCount: kind == nil ? GitHubWork.countLabel(prs: prs, issues: issues) : nil,
                  repoID: repo.id, showsKind: kind == nil,
                  moreKey: GitHubWork.Snapshot.repoKey(repo.id),
                  headerMenu: {
            AnyView(Group {
                Picker("Unread", selection: Binding(
                    get: { repo.unread.rawValue },
                    set: { if let rule = GitHubWork.UnreadRule(rawValue: $0) { state.setRepoUnreadRule(rule, for: repo.id) } }
                )) {
                    Text("Everything").tag(GitHubWork.UnreadRule.everything.rawValue)
                    Text("Only Mine").tag(GitHubWork.UnreadRule.onlyMine.rawValue)
                    Text("None").tag(GitHubWork.UnreadRule.silent.rawValue)
                }
                .pickerStyle(.inline)
                Divider()
                Button("Reveal on GitHub") {
                    if let url = URL(string: "https://github.com/\(repo.owner)/\(repo.repo)") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("Unfollow") { state.unfollowRepo(id: repo.id) }
            })
        })
        }
    }
}

/// Follow Repository… (spec §3): type `owner/repo` or a github.com URL,
/// or pick a repository already open somewhere.
struct FollowRepoSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""

    private var parsed: GitHubWork.FollowedRepo? { GitHubWork.FollowedRepo.parse(input) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Follow Repository")
                .font(.headline)
            Text("Every open pull request and issue in the repository joins the sidebar, most recently updated first.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("owner/repository or github.com URL", text: $input)
                .textFieldStyle(.roundedBorder)
                .onSubmit { follow() }
            let known = state.knownRepositories
            if !known.isEmpty {
                Text("Already open")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(known) { repo in
                            Button {
                                input = repo.id
                            } label: {
                                Label(repo.id, systemImage: "book.closed")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 2)
                        }
                    }
                }
                .frame(maxHeight: 140)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Follow") { follow() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(parsed == nil)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func follow() {
        guard let repo = parsed else { return }
        state.followRepo(repo)
        dismiss()
    }
}

/// An opened issue's sidebar row (spec §8): one line, the issue glyph,
/// Remove and GitHub on its menu.
struct IssueSidebarRow: View {
    @EnvironmentObject private var state: AppState
    @AppStorage(DefaultsKeys.zoom, store: UserDefaults.pullmark) private var zoom = 1.0
    let session: IssueSession

    var body: some View {
        let fonts = ChromeFonts(zoom: zoom)
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(session.details.title)
                    .lineLimit(1)
                    .font(fonts.row)
                Text(session.id + (session.details.isClosed ? " · " + String(localized: "closed") : ""))
                    .font(fonts.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } icon: {
            Image(systemName: session.details.isClosed ? "checkmark.circle" : "smallcircle.filled.circle")
                .foregroundStyle(session.details.isClosed ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.green))
                .drawingGroup()
        }
        .tag(SidebarSelection.issue(session.id))
        .help(session.details.title)
        .contextMenu {
            Button("Remove from Sidebar") { state.removeIssue(session.id) }
            Button("Reveal on GitHub") { NSWorkspace.shared.open(session.details.htmlUrl) }
        }
    }
}

// MARK: - The issue document

/// The comment round trips an issue page needs — the conversation
/// subset of ThreadCardActions, against the issue session instead of
/// a PR session. Same endpoints (issue comments ARE the conversation),
/// same fold-locally-never-refetch rule.
@MainActor
struct IssueThreadActions {
    let state: AppState
    let sessionID: String
    let proxy: WebViewProxy
    let mutatePreservingScroll: (@escaping () -> Void) -> Void

    private static let draftPath = "//issue"

    private var session: IssueSession? { state.issueSession(sessionID) }

    func sendComment(body: String, draftKey: String) {
        guard let session else {
            restoreDraftAfterFailure(key: draftKey, text: body)
            state.lastError = String(localized: "Could not post the comment — the issue is no longer open in PullMark. Your text was kept as a draft.")
            return
        }
        Task {
            do {
                let posted = try await state.client.createIssueComment(session.ref, body: body)
                mutatePreservingScroll {
                    state.applyPostedIssueComment(sessionID: sessionID, comment: posted)
                }
            } catch {
                restoreDraftAfterFailure(key: draftKey, text: body)
                state.lastError = String(localized: "Could not post the comment: \(error.localizedDescription)")
            }
        }
    }

    func handleReaction(commentID: Int, content: String, reacted: Bool) {
        guard let session, let kind = ReactionKind(rawValue: content) else { return }
        guard let nodeID = session.commentMeta[commentID]?.nodeID else {
            proxy.revertReaction(commentID: commentID, content: content, attempted: reacted)
            state.lastError = String(localized: "Reaction state unavailable — try again in a moment.")
            return
        }
        state.serializeReactionWrite(commentID: commentID) {
            do {
                try await state.client.setReaction(subjectID: nodeID, content: kind, add: reacted)
                mutatePreservingScroll {
                    state.applyIssueReaction(sessionID: sessionID, commentID: commentID,
                                             content: content, reacted: reacted)
                }
            } catch {
                proxy.revertReaction(commentID: commentID, content: content, attempted: reacted)
                state.lastError = String(localized: "Could not update the reaction: \(error.localizedDescription)")
            }
        }
    }

    func handleEdit(commentID: Int, body: String, draftKey: String) {
        guard let session else { return }
        Task {
            do {
                _ = try await state.client.updateIssueComment(session.ref, commentID: commentID, body: body)
                mutatePreservingScroll {
                    state.applyIssueCommentEdit(sessionID: sessionID, commentID: commentID, body: body)
                }
            } catch {
                restoreDraftAfterFailure(key: draftKey, text: body)
                state.lastError = String(localized: "Could not save the edit: \(error.localizedDescription)")
            }
        }
    }

    func deleteComment(_ commentID: Int) {
        guard let session else { return }
        Task {
            do {
                try await state.client.deleteIssueComment(session.ref, commentID: commentID)
                mutatePreservingScroll {
                    state.applyIssueCommentDelete(sessionID: sessionID, commentID: commentID)
                }
            } catch {
                state.lastError = String(localized: "Could not delete the comment: \(error.localizedDescription)")
            }
        }
    }

    /// Click-away drafts persist under the issue's ref with a fixed
    /// "head" — issues have no commits to key by.
    func saveComposerDraft(key: String, text: String) {
        guard let session else { return }
        ComposerDraftStore.save(jsKey: key, text: text, ref: session.ref,
                                headSHA: "issue", path: Self.draftPath)
    }

    func loadComposerDrafts() -> [String: String] {
        guard let session else { return [:] }
        return ComposerDraftStore.load(ref: session.ref, headSHA: "issue", path: Self.draftPath)
    }

    func restoreDraftAfterFailure(key: String, text: String) {
        guard !key.isEmpty else { return }
        saveComposerDraft(key: key, text: text)
        proxy.setComposerDrafts([key: text])
    }
}

/// An issue as a document (spec §8): header (title, state, author,
/// labels, GitHub link), the rendered body, then the comment timeline
/// with a composer — the PR overview's conversation machinery with
/// nothing review-shaped around it.
struct IssueView: View {
    @EnvironmentObject private var state: AppState
    let sessionID: String

    @State private var findSeed: String?
    @State private var deleteCommentID: Int?
    @State private var conversationPage = ConversationPageState()
    @State private var pendingScrollFraction: Double?
    @StateObject private var proxy = WebViewProxy()
    @AppStorage(Theme.defaultsKey, store: UserDefaults.pullmark) private var themeRaw = Theme.standard.rawValue

    struct ConversationPageState: Equatable {
        var entries: [ConversationEntryPayload] = []
        var unavailable = false
    }

    private var actions: IssueThreadActions {
        IssueThreadActions(state: state, sessionID: sessionID, proxy: proxy,
                           mutatePreservingScroll: mutatePreservingScroll)
    }

    private func mutatePreservingScroll(_ mutate: @escaping () -> Void) {
        proxy.scrollFraction { fraction in
            pendingScrollFraction = fraction
            mutate()
        }
    }

    var body: some View {
        if let session = state.issueSession(sessionID) {
            VStack(alignment: .leading, spacing: 0) {
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
                        lineNumberEligible: false,
                        conversation: conversationPage.entries,
                        conversationUnavailable: conversationPage.unavailable,
                        conversationComposer: true,
                        conversationSubject: "issue"
                    ),
                    onComposerDraft: { key, text in actions.saveComposerDraft(key: key, text: text) },
                    onOpenGitHubLink: { link, url, inverted in
                        state.handleGitHubLink(link, url: url, inverted: inverted)
                    },
                    onConversationSubmit: { body, draftKey in
                        actions.sendComment(body: body, draftKey: draftKey)
                    },
                    onConversationReaction: { commentID, content, reacted, _ in
                        actions.handleReaction(commentID: commentID, content: content, reacted: reacted)
                    },
                    onConversationEdit: { commentID, body, draftKey in
                        actions.handleEdit(commentID: commentID, body: body, draftKey: draftKey)
                    },
                    onConversationDelete: { deleteCommentID = $0 },
                    onPageLoaded: {
                        if let fraction = pendingScrollFraction {
                            pendingScrollFraction = nil
                            proxy.restoreScrollFraction(fraction)
                        }
                        proxy.setComposerDrafts(actions.loadComposerDrafts())
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
            .onAppear {
                var surface = SurfaceToolbar(id: "issue:" + sessionID)
                surface.shareURL = session.details.htmlUrl
                state.registerSurfaceToolbar(surface)
                conversationPage = ConversationPageState(entries: entries(session),
                                                         unavailable: session.conversationUnavailable)
            }
            .onChange(of: ConversationPageState(entries: entries(session),
                                                unavailable: session.conversationUnavailable)) { fresh in
                guard fresh != conversationPage else { return }
                mutatePreservingScroll { conversationPage = fresh }
            }
            .modifier(DeleteCommentConfirmation(commentID: $deleteCommentID,
                                                onConfirm: { actions.deleteComment($0) }))
        } else {
            EmptyView()
        }
    }

    private func entries(_ session: IssueSession) -> [ConversationEntryPayload] {
        PRConversation.payload(comments: session.comments, reviews: [],
                               commentMeta: session.commentMeta,
                               viewer: state.viewerLogin)
    }

    private func header(_ session: IssueSession) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(session.details.title)
                .font(.title2.bold())
            HStack(spacing: 8) {
                let closed = session.details.isClosed
                Label(closed ? String(localized: "Closed") : String(localized: "Open"),
                      systemImage: closed ? "checkmark.circle" : "smallcircle.filled.circle")
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background((closed ? Color.purple : Color.green).opacity(0.18), in: Capsule())
                    .foregroundStyle(closed ? Color.purple : Color.green)
                if let login = session.details.user?.login {
                    Text("opened by \(login)")
                        .foregroundStyle(.secondary)
                }
                Link("View on GitHub", destination: session.details.htmlUrl)
            }
            .font(.callout)
            if let labels = session.details.labels, !labels.isEmpty {
                HStack(spacing: 6) {
                    ForEach(labels) { label in
                        Text(label.name)
                            .font(.caption)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(labelColor(label).opacity(0.18), in: Capsule())
                            .foregroundStyle(labelColor(label))
                    }
                }
            }
        }
    }

    private func labelColor(_ label: IssueDetails.Label) -> Color {
        guard let hex = label.color, hex.count == 6, let value = UInt32(hex, radix: 16) else {
            return .secondary
        }
        return Color(red: Double((value >> 16) & 0xFF) / 255,
                     green: Double((value >> 8) & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255)
    }
}
