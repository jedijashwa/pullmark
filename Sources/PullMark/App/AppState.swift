import AppKit
import SwiftUI

struct LocalFile: Identifiable, Equatable {
    let url: URL
    let displayName: String
    /// Directory that relative images/links in this document resolve against
    /// (the containing folder, or the opened folder root).
    let resourceRoot: URL
    var id: URL { url }
}

struct PRSession: Identifiable {
    let ref: PullRequestRef
    var details: PullRequestDetails
    var mergeBaseSHA: String
    var files: [PullRequestFile]
    var reviewComments: [ReviewComment] = []
    var threadMeta: [Int: ThreadMeta] = [:]
    /// The viewer's pending review on GitHub — the source of truth. Nil
    /// when none exists (or the viewer is unauthenticated).
    var pendingReview: PendingReviewState?
    /// Comments authored here that GitHub hasn't accepted yet (offline or
    /// API failure) — persisted to disk, retried on sync. Always updated
    /// together with `pendingReview` so the unified list below and its
    /// per-row upload state can never disagree.
    var queuedComments: [PendingComment] = []
    /// The unified pending set the UI shows: server-accepted first, then
    /// the local queue, in authorship order within each.
    var pendingComments: [PendingComment] {
        (pendingReview?.comments ?? []) + queuedComments
    }
    /// Repo Markdown files opened via links from PR content (not part of the diff).
    var browsedDocs: [String] = []
    /// Set when the PR's head moved on GitHub since it was loaded.
    var updateAvailable = false
    /// Review comments/threads failed to load — the diff must not
    /// silently masquerade as an uncommented PR.
    var commentsUnavailable = false

    var id: String { "\(ref.owner)/\(ref.repo)#\(ref.number)" }
    var markdownFiles: [PullRequestFile] { files.filter(\.isMarkdown) }
    var otherFileCount: Int { files.count - markdownFiles.count }
}

enum SidebarSelection: Hashable {
    case local(URL)
    case prOverview(String)
    case prFile(String, String)
    /// A repo document browsed from PR content: (session id, repo path).
    case prDoc(String, String)
}

struct MessageError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// The document-shaped content currently frontmost in the detail area (a
/// local file, a PR file's Result view, or a browsed repo doc). Registered
/// by the detail views so app-level menu commands (Export as PDF/HTML, Copy
/// as Markdown) can reach the live web view and the original markdown
/// source. Diff views and the PR overview never register — those commands
/// are document-only (v1).
struct ActiveDocument {
    /// Registration identity, so a disappearing view only unregisters itself.
    let id: String
    /// Suggested export file basename (source file name without extension).
    let exportBaseName: String
    /// The original markdown source backing the rendered page.
    let markdown: String
    /// Handle on the live web view rendering the document.
    let proxy: WebViewProxy
    /// Root for pullmark-local image resolution (local files only).
    var localRoot: URL?
    /// Context for pullmark-remote image resolution (PR content only).
    var remoteContext: RemoteResourceContext?
}

/// A recently opened file, folder, or pull request. Persisted (metadata only)
/// in UserDefaults.
struct RecentItem: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        case file
        case folder
        case pr
    }

    var kind: Kind
    var path: String?
    var owner: String?
    var repo: String?
    var number: Int?
    var title: String
    var prStatus: PRStatus?
    var lastOpened: Date

    var id: String {
        switch kind {
        case .file: return "file:" + (path ?? "")
        case .folder: return "folder:" + (path ?? "")
        case .pr: return "pr:\(owner ?? "")/\(repo ?? "")#\(number ?? 0)"
        }
    }

    var ref: PullRequestRef? {
        guard kind == .pr, let owner, let repo, let number else { return nil }
        return PullRequestRef(owner: owner, repo: repo, number: number)
    }
}

/// Menu commands that act on state owned by a detail view rather than by
/// AppState — the view performs them when they arrive.
enum DocumentCommand: Equatable {
    case reload
    case toggleEditMode
    case findNext
    case findPrevious
    case showRenderedDiff
    case showSourceDiff
    case showResult
    case flipDiffLayout
    /// Opens the review popover on the active PR surface (spec §3).
    case reviewChanges
}

struct DocumentCommandRequest: Equatable {
    let id = UUID()
    let command: DocumentCommand
}

@MainActor
final class AppState: ObservableObject {
    @Published var localFiles: [LocalFile] = []
    @Published var prSessions: [PRSession] = []
    @Published var selection: SidebarSelection?
    @Published var showAddPR = false
    @Published var lastError: String?
    /// The native media inspector (click an image/diagram/formula).
    @Published var lightbox: LightboxContent?
    /// Informational, non-error messages ("no Markdown files here") — shown
    /// as a plain notice, never behind the "Something went wrong" title.
    @Published var lastNotice: String?
    /// Transient "Show Markdown Source" (⌥⌘U): flips the active document
    /// view to the raw text. Deliberately not persisted — reading stays the
    /// default on every launch.
    @Published var sourceViewVisible = false
    /// Show Resolved Conversations (Result-view thread markers, spec §1).
    /// Transient and default-off — resolved threads leave the reading
    /// surface on every launch; the in-page control and the View menu item
    /// mirror each other through this flag.
    @Published var resolvedConversationsVisible = false
    /// ⌘K Open Quickly palette.
    @Published var openQuicklyVisible = false
    /// Presents the commit sheet for a repo root (File → Commit Changes…).
    @Published var commitRequest: CommitRequest?
    /// Bumped after an in-app commit lands. Views holding git-derived state
    /// (compare menus, blame, titlebar branch) reload on change — a commit
    /// alters history without touching the file, so file watchers miss it.
    @Published var gitStateTick = 0
    @Published var findBarVisible = false
    /// The authenticated GitHub login, published for synchronous use by
    /// payload building (author-gating the ⋯ menu, tinting reaction
    /// chips). Set whenever identity resolution succeeds; nil gates all
    /// viewer-relative affordances off.
    @Published private(set) var viewerLogin: String?
    @Published var recents: [RecentItem] = []
    @Published var searchPaletteVisible = false
    /// Query handed from the search palette to the detail view it opened;
    /// consumed once (the view drives find-in-page with it after its page
    /// loads, so the term is highlighted and scrolled into view).
    @Published var pendingSearchQuery: String?
    /// See ActiveDocument; nil while a diff, the PR overview, or the empty
    /// placeholder is frontmost (export/copy menu items disable themselves).
    @Published var activeDocument: ActiveDocument?
    /// A menu command aimed at whichever detail view is on screen. Menus
    /// live at app level but these act on per-view state, so the command
    /// is posted here and the view that owns the state performs it.
    /// Carries an id so repeating the same command still fires.
    @Published var documentCommand: DocumentCommandRequest?

    /// Posts a command to the detail view and lets it clear the slot.
    func send(_ command: DocumentCommand) {
        documentCommand = DocumentCommandRequest(command: command)
    }

    /// Consumes the pending command if it is one this view handles.
    func take(_ command: DocumentCommand) -> Bool {
        guard documentCommand?.command == command else { return false }
        documentCommand = nil
        return true
    }

    let client = GitHubClient.shared

    /// One per window (like AppState itself): connects the window-level
    /// review toolbar button to whichever PR surface presents the review
    /// popover, so the popover's arrow can point at the actual button.
    let reviewAnchor = ReviewAnchorTracker()

    private static let recentsKey = DefaultsKeys.recents
    private static let recentsLimit = 12

    private var updateTimer: Timer?

    /// The key window's AppState: external opens (Finder, CLI, dock drops)
    /// land in the frontmost window now that each window owns its state.
    /// ContentView updates this as windows gain key status.
    static weak var keyInstance: AppState?

    /// Cross-window dedup: opens can arrive through both the scene's
    /// onOpenURL and the app delegate's router path, and with per-window
    /// states those may target different windows. First path in wins;
    /// the duplicate within the window is swallowed.
    private static var recentOpens: [URL: Date] = [:]
    static func gateOpen(_ url: URL) -> Bool {
        let now = Date()
        recentOpens = recentOpens.filter { now.timeIntervalSince($0.value) < 2 }
        guard recentOpens[url] == nil else { return false }
        recentOpens[url] = now
        return true
    }

    /// Router delivery with a retry buffer: keyInstance is weak and goes
    /// nil between a key window closing and the next one keying — an open
    /// landing in that gap would otherwise be silently dropped.
    static func deliverExternalOpens(_ urls: [URL], retries: Int = 20) {
        if let instance = keyInstance {
            for url in urls where gateOpen(url) { instance.add(url: url) }
        } else if retries > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                deliverExternalOpens(urls, retries: retries - 1)
            }
        }
    }

    init() {
        if Self.keyInstance == nil { Self.keyInstance = self }
        OpenURLRouter.shared.onOpen { urls in
            Task { @MainActor in AppState.deliverExternalOpens(urls) }
        }
        // Command-line arguments, in case this state is created before the
        // app delegate finished launching (or vice versa).
        Task { @MainActor [weak self] in
            for url in LaunchArguments.consumeFileURLs() { self?.add(url: url) }
        }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.checkForPRUpdates()
                await self?.refreshInboxIfDue()
            }
        }
        // Demo launches (PM_DEMO=1) fabricate their session below and show
        // nothing real — no recents, no inbox, no restore.
        if !DemoMode.active {
            loadRecents()
            loadInboxCounts()
        }
        Task { @MainActor [weak self] in
            // Brief grace so launch-time opens (CLI, Finder) land first —
            // restore skips itself when anything is already open.
            try? await Task.sleep(nanoseconds: 300_000_000)
            if DemoMode.active {
                self?.installDemoSessionIfNeeded()
            } else {
                self?.restoreSessionIfWanted()
                await self?.refreshInboxIfDue()
            }
        }
    }

    // MARK: - Demo mode (PM_DEMO=1)

    /// Fabricates the curated demo session directly — the same shape
    /// `addPR` builds from live responses, but entirely offline (see
    /// DemoSession for the content and DemoMode for the persistence
    /// seam). First window only, and only while it is still empty,
    /// mirroring the session-restore rules.
    private func installDemoSessionIfNeeded() {
        guard Self.keyInstance === self, localFiles.isEmpty, prSessions.isEmpty
        else { return }
        localFiles = DemoSession.installLocalDocs()
        let session = DemoSession.makeSession()
        viewerLogin = DemoSession.viewerLogin
        adoptionKnown.insert(session.id)
        prSessions = [session]
        selection = .prOverview(session.id)
    }

    // MARK: - Review-request inbox

    @Published var inbox: [GitHubClient.InboxPR] = []
    /// Markdown-file counts per inbox id, cached per update stamp.
    /// Markdown-file counts keyed by PR id. A count from a previous
    /// updatedAt keeps serving as a placeholder while the refresh
    /// re-counts — invalidating on every activity bump made the whole
    /// inbox flash unfiltered for a beat. Persisted so launches don't
    /// flash either.
    @Published var inboxMDCounts: [String: Int] = [:]
    /// id → the updatedAt the count was computed for.
    private var inboxCountStamps: [String: String] = [:]
    private var lastInboxRefresh: Date?

    var inboxEnabled: Bool {
        UserDefaults.pullmark.object(forKey: DefaultsKeys.inboxEnabled) as? Bool ?? true
    }

    /// Search-API rate limits are tight (30/min): refresh at most every
    /// five minutes, quietly — an inbox should never produce error alerts.
    func refreshInboxIfDue() async {
        // Only the key window polls — N windows sharing one rate limit
        // would multiply identical searches for identical results.
        // Demo mode never polls: the fixture is the whole world.
        guard !DemoMode.active, inboxEnabled, Self.keyInstance === self else { return }
        if let last = lastInboxRefresh, Date().timeIntervalSince(last) < 300 { return }
        lastInboxRefresh = Date()
        guard let items = try? await client.reviewRequests() else { return }
        // Counts FIRST, list after, published together: the visible list
        // must never show an item its filter hasn't judged yet — that
        // was the flash of unfiltered requests on every refresh. Counts
        // from an older updatedAt serve as placeholders (top 15 counted;
        // the long tail shows uncounted by design).
        let liveIDs = Set(items.map(\.id))
        var counts = inboxMDCounts.filter { liveIDs.contains($0.key) }
        var stamps = inboxCountStamps.filter { liveIDs.contains($0.key) }
        for item in items.prefix(15) where stamps[item.id] != item.updatedAt {
            if let count = try? await client.markdownFileCount(item.ref) {
                counts[item.id] = count
                stamps[item.id] = item.updatedAt
            }
        }
        inboxMDCounts = counts
        inboxCountStamps = stamps
        inbox = items
        persistInboxCounts()
    }

    func inboxMDCount(_ item: GitHubClient.InboxPR) -> Int? {
        inboxMDCounts[item.id]
    }

    private func persistInboxCounts() {
        UserDefaults.pullmark.set(inboxMDCounts, forKey: DefaultsKeys.inboxMDCounts)
        UserDefaults.pullmark.set(inboxCountStamps, forKey: DefaultsKeys.inboxCountStamps)
    }

    func loadInboxCounts() {
        let defaults = UserDefaults.pullmark
        if let counts = defaults.dictionary(forKey: DefaultsKeys.inboxMDCounts) as? [String: Int] {
            inboxMDCounts = counts
        }
        if let stamps = defaults.dictionary(forKey: DefaultsKeys.inboxCountStamps) as? [String: String] {
            inboxCountStamps = stamps
        }
    }

    func inboxIsUnread(_ item: GitHubClient.InboxPR) -> Bool {
        let seen = UserDefaults.pullmark.dictionary(forKey: DefaultsKeys.inboxSeen) as? [String: String]
        return seen?[item.id] != item.updatedAt
    }

    func openInboxItem(_ item: GitHubClient.InboxPR) {
        var seen = UserDefaults.pullmark.dictionary(forKey: DefaultsKeys.inboxSeen) as? [String: String] ?? [:]
        seen[item.id] = item.updatedAt
        // Bounded, but never pruned against the current (single-page) inbox
        // — that resurrected read state for anything briefly absent.
        if seen.count > 200 {
            let live = Set(inbox.map(\.id))
            for key in seen.keys where !live.contains(key) {
                seen[key] = nil
                if seen.count <= 200 { break }
            }
        }
        UserDefaults.pullmark.set(seen, forKey: DefaultsKeys.inboxSeen)
        objectWillChange.send()
        Task {
            do {
                try await addPR("\(item.ref.owner)/\(item.ref.repo)#\(item.ref.number)")
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    // MARK: - Session restore

    /// Files and PRs reopen where you left off (Settings-controlled,
    /// default on). Snapshots are written at quit and when the key window
    /// closes; restore is skipped when the app was launched to open
    /// something specific.
    /// PRs from the previous snapshot that haven't (re)opened yet — kept in
    /// every new snapshot so an offline launch can't erase them.
    private var pendingRestorePRs: Set<String> = []

    func snapshotSession() {
        let openPRs = prSessions.map { "\($0.ref.owner)/\($0.ref.repo)#\($0.ref.number)" }
        let snapshot: [String: [String]] = [
            "files": localFiles.map(\.url.path),
            "prs": Array(Set(openPRs).union(pendingRestorePRs)),
        ]
        UserDefaults.pullmark.set(snapshot, forKey: DefaultsKeys.sessionSnapshot)
    }

    private func restoreSessionIfWanted() {
        // Only the first window restores — ⌘N must open EMPTY windows,
        // not clones of the last session.
        guard Self.keyInstance === self,
              UserDefaults.pullmark.object(forKey: DefaultsKeys.restoreSession) as? Bool ?? true,
              localFiles.isEmpty, prSessions.isEmpty,
              let snapshot = UserDefaults.pullmark.dictionary(forKey: DefaultsKeys.sessionSnapshot)
                  as? [String: [String]]
        else { return }
        for path in snapshot["files"] ?? [] where FileManager.default.fileExists(atPath: path) {
            add(url: URL(fileURLWithPath: path))
        }
        selection = nil
        pendingRestorePRs = Set(snapshot["prs"] ?? [])
        for pr in pendingRestorePRs {
            Task { [weak self] in
                do {
                    try await self?.addPR(pr)
                    self?.pendingRestorePRs.remove(pr)
                } catch {
                    // Kept pending: the next snapshot still lists it, so a
                    // failed (offline) restore never erases the PR.
                }
            }
        }
    }

    deinit {
        updateTimer?.invalidate()
    }

    // MARK: - Active document

    func registerActiveDocument(_ document: ActiveDocument) {
        activeDocument = document
    }

    /// Views unregister by id on disappear; the guard keeps a stale
    /// onDisappear (fired after the next view already registered) from
    /// clobbering the new registration.
    func unregisterActiveDocument(id: String) {
        if activeDocument?.id == id { activeDocument = nil }
    }

    // MARK: - Local files

    func openFileOrFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Open Markdown files or a folder containing them"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { add(url: url) }
    }

    func add(url: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return }
        if isDirectory.boolValue {
            addFolder(url)
            noteRecent(RecentItem(kind: .folder, path: url.path,
                                  title: url.lastPathComponent, lastOpened: Date()))
        } else {
            addFile(url, displayName: url.lastPathComponent,
                    resourceRoot: url.deletingLastPathComponent())
            noteRecent(RecentItem(kind: .file, path: url.path,
                                  title: url.lastPathComponent, lastOpened: Date()))
            // The system's recents too, so the Dock icon's right-click
            // menu and Apple → Recent Items know about PullMark documents
            // — the in-app Recents section alone is invisible from the
            // Finder side. Files only: a folder in Recent Items would
            // reopen in Finder, not here.
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        }
    }

    func localFile(for url: URL) -> LocalFile? {
        localFiles.first { $0.url == url }
    }

    func removeLocalFile(_ file: LocalFile) {
        localFiles.removeAll { $0.url == file.url }
        if selection == .local(file.url) { selection = nil }
    }

    private func addFolder(_ root: URL) {
        // Enumeration walks the whole tree — off the main thread so a huge
        // folder can't freeze the UI; results land back on the main actor.
        Task.detached(priority: .userInitiated) { [weak self] in
            let scan = Self.scanForMarkdown(in: root)
            guard let self else { return }
            await MainActor.run {
                for (url, relative) in scan.files {
                    self.addFile(url, displayName: relative, resourceRoot: root)
                }
                if scan.files.isEmpty {
                    self.lastNotice = "No Markdown files found in \(root.lastPathComponent)."
                } else if scan.truncated {
                    self.lastNotice = "Showing the first \(Self.folderFileLimit) Markdown files in "
                        + "\(root.lastPathComponent) — open a subfolder to see the rest."
                }
            }
        }
    }

    nonisolated private static let folderFileLimit = 500

    nonisolated private static func scanForMarkdown(in root: URL) -> (files: [(URL, String)], truncated: Bool) {
        let skippedDirectories: Set<String> = ["node_modules", "vendor", ".build", "dist"]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return ([], false) }

        var files: [(URL, String)] = []
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                if skippedDirectories.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard MarkdownFileType.matches(url.pathExtension) else { continue }
            let relative = url.path.hasPrefix(root.path + "/")
                ? String(url.path.dropFirst(root.path.count + 1))
                : url.lastPathComponent
            files.append((url, relative))
            if files.count >= folderFileLimit { return (files, true) }
        }
        return (files, false)
    }

    private func addFile(_ url: URL, displayName: String, resourceRoot: URL) {
        if !localFiles.contains(where: { $0.url == url }) {
            localFiles.append(LocalFile(url: url, displayName: displayName, resourceRoot: resourceRoot))
        }
        selection = .local(url)
    }

    // MARK: - Pull requests

    /// Head-revision Markdown text already fetched for PR files and browsed
    /// repo docs, keyed by (session id, repo path). Memory only — populated
    /// as detail views load content, so the search palette can search PR
    /// documents without triggering network fetches.
    struct PRContentKey: Hashable {
        let sessionID: String
        let path: String
    }
    private var prContentCache: [PRContentKey: String] = [:]

    func cachePRContent(sessionID: String, path: String, text: String) {
        prContentCache[PRContentKey(sessionID: sessionID, path: path)] = text
    }

    func cachedPRContent(sessionID: String, path: String) -> String? {
        prContentCache[PRContentKey(sessionID: sessionID, path: path)]
    }

    private func dropPRContentCache(sessionID: String) {
        prContentCache = prContentCache.filter { $0.key.sessionID != sessionID }
    }

    func session(_ id: String) -> PRSession? {
        prSessions.first { $0.id == id }
    }

    func addPR(_ input: String) async throws {
        guard let ref = PullRequestRef.parse(input) else {
            throw MessageError(message: "Could not parse a pull request from “\(input)”. "
                + "Expected something like https://github.com/owner/repo/pull/123 or owner/repo#123.")
        }
        if let existing = prSessions.first(where: { $0.ref == ref }) {
            selection = .prOverview(existing.id)
            return
        }
        let details: PullRequestDetails
        do {
            details = try await client.pullRequest(ref)
        } catch {
            if let apiError = error as? GitHubClient.APIError, apiError.status == 404 {
                updateRecentPRStatus(ref: ref, status: .deleted)
            }
            throw error
        }
        let files = try await client.files(ref)
        var mergeBase = details.base.sha
        do {
            mergeBase = try await client.mergeBaseSHA(ref, base: details.base.sha, head: details.head.sha)
        } catch {
            // Fall back to the base tip; only matters when the base branch moved.
        }
        var session = PRSession(ref: ref, details: details, mergeBaseSHA: mergeBase, files: files)
        do {
            session.reviewComments = try await client.reviewComments(ref)
            session.threadMeta = try await client.reviewThreadMeta(ref)
        } catch {
            // A blip must not render as "no comments on this PR".
            session.commentsUnavailable = true
        }
        session.queuedComments = PendingReviewStore.loadQueue(ref: ref, headSHA: details.head.sha)
        // Concurrent opens of the same PR both pass the check at the top of
        // this function during the awaits above — re-check at the append
        // and adopt the winner, or the session (and its pending-comment
        // syncing) exists twice.
        if let existing = prSessions.first(where: { $0.ref == ref }) {
            selection = .prOverview(existing.id)
            return
        }
        prSessions.append(session)
        selection = .prOverview(session.id)
        noteRecent(RecentItem(kind: .pr, owner: ref.owner, repo: ref.repo, number: ref.number,
                              title: details.title, prStatus: PRStatus(details: details),
                              lastOpened: Date()))
        // A pending review saved from here or started on github.com must be
        // visible from the first render; a fetch failure shows the same
        // banner as missing comments — never a silently clean review state.
        let sessionID = session.id
        if await !adoptPendingReview(sessionID: sessionID),
           let index = prSessions.firstIndex(where: { $0.id == sessionID }) {
            prSessions[index].commentsUnavailable = true
        }
        await syncPendingComments(sessionID: sessionID)
    }

    func openRemoteDoc(sessionID: String, path: String) {
        guard let index = prSessions.firstIndex(where: { $0.id == sessionID }) else { return }
        if !prSessions[index].browsedDocs.contains(path) {
            prSessions[index].browsedDocs.append(path)
        }
        selection = .prDoc(sessionID, path)
    }

    /// Detects head movement on open PRs; sets a flag rather than reloading
    /// so an in-progress review is never yanked out from under the user.
    func checkForPRUpdates() async {
        // The demo PR has no upstream to move.
        guard !DemoMode.active else { return }
        for session in prSessions where !session.updateAvailable {
            guard let details = try? await client.pullRequest(session.ref) else { continue }
            updateRecentPRStatus(ref: session.ref, status: PRStatus(details: details))
            if details.head.sha != session.details.head.sha,
               let index = prSessions.firstIndex(where: { $0.id == session.id }) {
                prSessions[index].updateAvailable = true
            }
        }
        // A pending review started elsewhere (github.com) appears without
        // a relaunch: adoption rides the same 60s poll. Cheap — one
        // reviews GET per open session, GraphQL only when one exists —
        // and a poll failure stays silent; the next poll retries.
        for session in prSessions {
            await adoptPendingReview(sessionID: session.id)
        }
    }

    func refreshPR(sessionID: String) async {
        guard let session = prSessions.first(where: { $0.id == sessionID }) else { return }
        let ref = session.ref
        do {
            let details = try await client.pullRequest(ref)
            let files = try await client.files(ref)
            let mergeBase = (try? await client.mergeBaseSHA(ref, base: details.base.sha, head: details.head.sha))
                ?? details.base.sha
            var comments: [ReviewComment] = []
            var meta: [Int: ThreadMeta] = [:]
            var commentsUnavailable = false
            do {
                comments = try await client.reviewComments(ref)
                meta = try await client.reviewThreadMeta(ref)
            } catch {
                commentsUnavailable = true
            }
            guard let index = prSessions.firstIndex(where: { $0.id == sessionID }) else { return }
            let headMoved = details.head.sha != prSessions[index].details.head.sha
            prSessions[index].details = details
            prSessions[index].files = files
            prSessions[index].mergeBaseSHA = mergeBase
            if !commentsUnavailable {
                prSessions[index].reviewComments = comments
                prSessions[index].threadMeta = meta
            }
            prSessions[index].commentsUnavailable = commentsUnavailable
            prSessions[index].updateAvailable = false
            if headMoved {
                // Queued anchors are per-head; the old head's queue stays on
                // disk under its own key rather than mis-anchoring here.
                prSessions[index].queuedComments = PendingReviewStore.loadQueue(
                    ref: ref, headSHA: details.head.sha)
            }
            // Cached document text may predate the new head; views refill it.
            dropPRContentCache(sessionID: sessionID)
            updateRecentPRStatus(ref: ref, status: PRStatus(details: details))
            if await !adoptPendingReview(sessionID: sessionID),
               let current = prSessions.firstIndex(where: { $0.id == sessionID }) {
                prSessions[current].commentsUnavailable = true
            }
            await syncPendingComments(sessionID: sessionID)
        } catch {
            lastError = "Could not refresh \(session.id): \(error.localizedDescription)"
        }
    }

    // MARK: - Recents

    func openRecent(_ item: RecentItem) {
        switch item.kind {
        case .file, .folder:
            guard let path = item.path else { return }
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                lastError = "\(item.title) no longer exists at \(path)."
                removeRecent(id: item.id)
                return
            }
            add(url: url)
        case .pr:
            guard let ref = item.ref else { return }
            Task {
                do {
                    try await addPR("\(ref.owner)/\(ref.repo)#\(ref.number)")
                } catch {
                    lastError = error.localizedDescription
                }
            }
        }
    }

    func removeRecent(id: String) {
        recents.removeAll { $0.id == id }
        saveRecents()
    }

    func clearRecents() {
        recents.removeAll()
        saveRecents()
    }

    private func noteRecent(_ item: RecentItem) {
        recents.removeAll { $0.id == item.id }
        recents.insert(item, at: 0)
        let overflow = recents.filter { $0.kind == item.kind }.dropFirst(Self.recentsLimit)
        for stale in overflow { recents.removeAll { $0.id == stale.id } }
        saveRecents()
    }

    private func updateRecentPRStatus(ref: PullRequestRef, status: PRStatus) {
        guard let index = recents.firstIndex(where: { $0.ref == ref }) else { return }
        if recents[index].prStatus != status {
            recents[index].prStatus = status
            saveRecents()
        }
    }

    private func loadRecents() {
        guard let data = UserDefaults.pullmark.data(forKey: Self.recentsKey),
              let decoded = try? JSONDecoder().decode([RecentItem].self, from: data)
        else { return }
        recents = decoded
    }

    private func saveRecents() {
        if let data = try? JSONEncoder().encode(recents) {
            UserDefaults.pullmark.set(data, forKey: Self.recentsKey)
        }
    }

    /// Refreshes existing review comments and thread state, e.g. after
    /// posting, replying, or resolving.
    func reloadComments(sessionID: String) async {
        guard let index = prSessions.firstIndex(where: { $0.id == sessionID }) else { return }
        let ref = prSessions[index].ref
        guard let comments = try? await client.reviewComments(ref) else { return }
        let meta = (try? await client.reviewThreadMeta(ref)) ?? [:]
        if let current = prSessions.firstIndex(where: { $0.id == sessionID }) {
            prSessions[current].reviewComments = comments
            prSessions[current].threadMeta = meta
        }
    }

    /// Folds a confirmed reaction write into the loaded model without a
    /// refetch: the REST rollup count and the viewer's reaction state move
    /// together, and the session is published once — the comment list and
    /// the meta its chips derive from can never disagree mid-update.
    func applyReaction(sessionID: String, commentID: Int, content: String, reacted: Bool) {
        guard let index = prSessions.firstIndex(where: { $0.id == sessionID }) else { return }
        var session = prSessions[index]
        guard let commentIndex = session.reviewComments.firstIndex(where: { $0.id == commentID })
        else { return }
        let rootID = CommentReactions.metaRoot(of: commentID, in: session.threadMeta)
        let viewerReacted = rootID.flatMap {
            session.threadMeta[$0]?.comments[commentID]?.viewerReacted
        } ?? []
        let updated = CommentReactions.applied(
            rollup: session.reviewComments[commentIndex].reactions ?? ReactionRollup(),
            viewerReacted: viewerReacted, content: content, reacted: reacted)
        session.reviewComments[commentIndex].reactions = updated.rollup
        if let rootID {
            session.threadMeta[rootID]?.comments[commentID]?.viewerReacted = updated.viewerReacted
        }
        prSessions[index] = session
    }

    func removePR(_ id: String) {
        prSessions.removeAll { $0.id == id }
        dropPRContentCache(sessionID: id)
        adoptionKnown.remove(id)
        pendingSyncGate.forget(id)
        switch selection {
        case .prOverview(let s):
            if s == id { selection = nil }
        case .prFile(let s, _):
            if s == id { selection = nil }
        default:
            break
        }
    }

    // MARK: - Pending review (GitHub is the source of truth — spec §4)

    /// One upload loop per PR (two quick adds can't race each other into
    /// duplicate comments); adds during a pass trigger another, and submit
    /// waits for in-flight runs — see PendingSyncGate.
    private let pendingSyncGate = PendingSyncGate()

    /// Sessions whose latest pending-review adoption succeeded. The create
    /// path of a sync may only run for a session in this set: when
    /// adoption state is unknown (identity resolution or the fetch failed
    /// with a token present), a pending review the app cannot see may
    /// exist server-side, and creating would 422 against it forever.
    private var adoptionKnown: Set<String> = []

    /// Queues a review comment and immediately syncs it into the viewer's
    /// pending review on GitHub, so the pending count is true by
    /// construction. On failure it stays queued (and on disk) for retry.
    func addPendingComment(sessionID: String, _ comment: PendingComment) {
        guard let index = prSessions.firstIndex(where: { $0.id == sessionID }) else { return }
        prSessions[index].queuedComments.append(comment)
        persistQueue(sessionID: sessionID)
        pendingSyncGate.noteChange(sessionID)
        Task { await syncPendingComments(sessionID: sessionID) }
    }

    /// Discards one pending comment — locally when it never reached GitHub,
    /// server-side (then re-adopted) when it did.
    func removePendingComment(sessionID: String, id: String) {
        guard let index = prSessions.firstIndex(where: { $0.id == sessionID }) else { return }
        if prSessions[index].queuedComments.contains(where: { $0.id == id }) {
            prSessions[index].queuedComments.removeAll { $0.id == id }
            persistQueue(sessionID: sessionID)
            return
        }
        guard let comment = prSessions[index].pendingReview?.comments
            .first(where: { $0.id == id }) else { return }
        guard let serverID = comment.serverID else {
            // Landed by the atomic create, id not echoed back yet (see
            // stateAfterCreate) — a server-side delete needs the id.
            lastError = "This comment is still syncing with GitHub — try discarding it again in a moment."
            return
        }
        let ref = prSessions[index].ref
        Task {
            do {
                try await client.deleteReviewComment(ref, commentID: serverID)
                await adoptPendingReview(sessionID: sessionID)
            } catch {
                lastError = "Could not discard the pending comment: \(error.localizedDescription)"
            }
        }
    }

    /// Fetches the viewer's pending review (if any) and reconciles the
    /// local queue against its comments — publishing both together so the
    /// unified list and its per-row upload state never disagree. Returns
    /// false when adoption state could not be established (callers decide
    /// how loudly to surface).
    @discardableResult
    func adoptPendingReview(sessionID: String) async -> Bool {
        // Demo mode: the fabricated pending review IS the truth — there is
        // no server to reconcile against, and adoption must never clear it.
        guard !DemoMode.active else { return true }
        guard let session = prSessions.first(where: { $0.id == sessionID }) else { return true }
        let ref = session.ref
        // Unauthenticated: no pending review can exist and no sync can run
        // — a clean, known absence.
        guard await client.authToken() != nil else {
            adoptionKnown.insert(sessionID)
            return true
        }
        // A token is present, so a pending review may exist server-side.
        // A failed identity resolution means its existence is unknown —
        // that must read as "unavailable" (banner), never as a silently
        // clean "no pending review".
        guard let viewer = await client.viewerIdentity()?.login else {
            adoptionKnown.remove(sessionID)
            return false
        }
        viewerLogin = viewer
        do {
            let reviews = try await client.reviews(ref)
            var state: PendingReviewState?
            if let pending = PendingReviewSync.pendingReview(in: reviews, viewer: viewer) {
                let comments = try await client.pendingReviewComments(ref, reviewID: pending.id)
                state = PendingReviewState(reviewID: pending.id, nodeID: pending.nodeId,
                                           commitID: pending.commitId, summary: pending.body,
                                           comments: comments)
            }
            guard let index = prSessions.firstIndex(where: { $0.id == sessionID }) else { return true }
            // Reviews-list lag guard: a review this app just created can be
            // missing from the list for a beat (read-after-write). Comments
            // only the create response vouches for (no server id yet) must
            // not be dropped — and dropping the review would re-arm the
            // create path into a guaranteed 422. Keep the local truth; a
            // later adoption that sees the review reconciles ids normally.
            if state == nil,
               let local = prSessions[index].pendingReview,
               local.comments.contains(where: { $0.serverID == nil }) {
                adoptionKnown.insert(sessionID)
                return true
            }
            let reconciled = PendingReviewSync.reconcile(
                server: state?.comments ?? [],
                previousServer: prSessions[index].pendingReview?.comments ?? [],
                queue: prSessions[index].queuedComments)
            state?.comments = reconciled.server
            prSessions[index].pendingReview = state
            prSessions[index].queuedComments = reconciled.queue
            persistQueue(sessionID: sessionID)
            adoptionKnown.insert(sessionID)
            return true
        } catch {
            adoptionKnown.remove(sessionID)
            return false
        }
    }

    /// Drains the local queue into the server-side pending review. When a
    /// sync for this session is already in flight, waits for it to finish
    /// (comments added mid-flight get one more pass via the gate) instead
    /// of silently doing nothing.
    func syncPendingComments(sessionID: String) async {
        // Demo mode: nothing uploads — the queued comment deliberately
        // stays "Not synced" so both sync states stay visible.
        guard !DemoMode.active else { return }
        await pendingSyncGate.run(sessionID) { [weak self] in
            await self?.performPendingSyncPass(sessionID: sessionID)
        }
    }

    /// One drain pass: one atomic REST create when no pending review
    /// exists, GraphQL adds (FIFO) when one does — see GitHubClient's
    /// API-mix note. Failures keep the remainder queued and surface; a
    /// 422 from racing an externally created pending review is healed by
    /// re-adopting and retrying once.
    ///
    /// The create path runs at most once per pass. A successful create is
    /// its own proof: the response carries the review and every sent
    /// comment was accepted with it, so the sent comments move into the
    /// adopted state directly (PendingReviewSync.stateAfterCreate).
    /// Re-fetching instead would race GitHub's lagging reviews list — the
    /// fetch misses the just-created review, the loop re-enters the create
    /// path, and the second create 422s ("one pending review per PR")
    /// though the first one succeeded.
    private func performPendingSyncPass(sessionID: String) async {
        var attemptsLeft = 2
        var createdThisPass = false
        while attemptsLeft > 0 {
            attemptsLeft -= 1
            guard let queued = prSessions.first(where: { $0.id == sessionID })?.queuedComments,
                  !queued.isEmpty else { return }
            // Adoption unknown: an unseen pending review may exist — never
            // run the create path against it. Re-adopt; if still unknown,
            // keep the queue and show the same banner as missing comments.
            if !adoptionKnown.contains(sessionID) {
                guard await adoptPendingReview(sessionID: sessionID) else {
                    if let index = prSessions.firstIndex(where: { $0.id == sessionID }) {
                        prSessions[index].commentsUnavailable = true
                    }
                    return
                }
            }
            guard let session = prSessions.first(where: { $0.id == sessionID }),
                  !session.queuedComments.isEmpty else { return }
            do {
                if let pending = session.pendingReview {
                    for comment in session.queuedComments {
                        try await client.addPendingComment(reviewNodeID: pending.nodeID,
                                                           comment: comment)
                    }
                    // Adoption moves the uploaded comments from the queue to
                    // the server list in one publish; anything it kept queued
                    // was not accepted (or arrived mid-sync) — loop once more.
                    await adoptPendingReview(sessionID: sessionID)
                } else if !createdThisPass {
                    let sent = session.queuedComments
                    let created = try await client.createReview(
                        session.ref, commitID: session.details.head.sha,
                        body: nil, event: nil, comments: sent)
                    createdThisPass = true
                    if let created,
                       let index = prSessions.firstIndex(where: { $0.id == sessionID }) {
                        let outcome = PendingReviewSync.stateAfterCreate(
                            review: created, sent: sent,
                            queue: prSessions[index].queuedComments,
                            fallbackCommitID: session.details.head.sha)
                        // One synchronous publish: the adopted list and the
                        // queue its rows are filtered against move together.
                        prSessions[index].pendingReview = outcome.state
                        prSessions[index].queuedComments = outcome.queue
                        persistQueue(sessionID: sessionID)
                        adoptionKnown.insert(sessionID)
                    } else {
                        // Response shape drift: the review exists but wasn't
                        // decodable. Adopt to find it — quietly, and without
                        // ever re-entering the create path this pass.
                        await adoptPendingReview(sessionID: sessionID)
                    }
                } else {
                    // A create already ran this pass but no pending review
                    // is visible yet (reviews-list lag). Adopt-only, quiet:
                    // the comments are safe server-side or still queued for
                    // the next pass — a second create would 422.
                    await adoptPendingReview(sessionID: sessionID)
                    if prSessions.first(where: { $0.id == sessionID })?.pendingReview == nil {
                        return
                    }
                }
                guard let after = prSessions.first(where: { $0.id == sessionID }),
                      !after.queuedComments.isEmpty, attemptsLeft > 0 else { return }
            } catch {
                // The create may have lost to a review started elsewhere
                // (one pending review per user) — adopt it and retry as adds.
                await adoptPendingReview(sessionID: sessionID)
                if let after = prSessions.first(where: { $0.id == sessionID }),
                   after.pendingReview != nil, !after.queuedComments.isEmpty,
                   attemptsLeft > 0 { continue }
                let count = prSessions.first(where: { $0.id == sessionID })?
                    .queuedComments.count ?? 0
                if count > 0 {
                    lastError = "Could not upload \(count) pending comment\(count == 1 ? "" : "s") "
                        + "to GitHub — kept locally for retry. \(error.localizedDescription)"
                }
                return
            }
        }
    }

    /// Submits the review: the server-side pending review when one exists
    /// (after draining the queue — never silently dropping comments that
    /// failed to upload), otherwise a one-shot create-and-submit.
    func submitReview(sessionID: String, event: String, summary: String?) async throws {
        // Waits out any in-flight sync (the gate) then drains what's left
        // — mid-upload comments must never read as "could not be uploaded".
        await syncPendingComments(sessionID: sessionID)
        guard var session = prSessions.first(where: { $0.id == sessionID }) else {
            throw MessageError(message: "The PR session is no longer available.")
        }
        guard session.queuedComments.isEmpty else {
            let count = session.queuedComments.count
            throw MessageError(message: "\(count) comment\(count == 1 ? "" : "s") could not be "
                + "uploaded to GitHub, so the review was not submitted. Retry when you're back online.")
        }
        // Adoption unknown (e.g. identity resolution failed): a pending
        // review the app cannot see may exist, and the create path would
        // submit past it — establish the truth or refuse.
        if session.pendingReview == nil, !adoptionKnown.contains(sessionID) {
            guard await adoptPendingReview(sessionID: sessionID),
                  let refreshed = prSessions.first(where: { $0.id == sessionID }) else {
                throw MessageError(message: "Could not check GitHub for an existing pending review, "
                    + "so the review was not submitted. Check your connection and try again.")
            }
            session = refreshed
        }
        if let pending = session.pendingReview {
            // The events endpoint documents body as required for COMMENT and
            // REQUEST_CHANGES; an empty string satisfies it when the review
            // carries only comments.
            let body = summary ?? (event == "APPROVE" ? nil : "")
            try await client.submitReview(session.ref, reviewID: pending.reviewID,
                                          event: event, body: body)
        } else {
            try await client.createReview(session.ref, commitID: session.details.head.sha,
                                          body: summary, event: event, comments: [])
        }
        clearPendingState(sessionID: sessionID)
        await reloadComments(sessionID: sessionID)
    }

    /// Discards the pending review server-side (GitHub's "Abandon review")
    /// along with the local queue and persisted summary.
    func abandonPendingReview(sessionID: String) async {
        guard let session = prSessions.first(where: { $0.id == sessionID }) else { return }
        do {
            if let pending = session.pendingReview {
                try await client.deletePendingReview(session.ref, reviewID: pending.reviewID)
            }
            clearPendingState(sessionID: sessionID)
        } catch {
            lastError = "Could not abandon the review: \(error.localizedDescription)"
        }
    }

    private func clearPendingState(sessionID: String) {
        guard let index = prSessions.firstIndex(where: { $0.id == sessionID }) else { return }
        prSessions[index].pendingReview = nil
        prSessions[index].queuedComments = []
        persistQueue(sessionID: sessionID)
        PendingReviewStore.saveSummary(nil, ref: prSessions[index].ref)
    }

    private func persistQueue(sessionID: String) {
        guard let session = prSessions.first(where: { $0.id == sessionID }) else { return }
        PendingReviewStore.saveQueue(session.queuedComments, ref: session.ref,
                                     headSHA: session.details.head.sha)
    }
}

/// Delivers menu commands to whichever detail view owns the state they act
/// on. A plain `.onChange` inline in those views pushed SwiftUI's type
/// checker over its limit, so it lives here as a modifier.
struct DocumentCommandHandler: ViewModifier {
    @ObservedObject var state: AppState
    let handle: (DocumentCommandRequest?) -> Void

    func body(content: Content) -> some View {
        content.onChange(of: state.documentCommand) { handle($0) }
    }
}
