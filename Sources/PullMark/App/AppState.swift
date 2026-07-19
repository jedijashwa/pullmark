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
    var drafts: [DraftComment] = []
    /// Repo Markdown files opened via links from PR content (not part of the diff).
    var browsedDocs: [String] = []
    /// Set when the PR's head moved on GitHub since it was loaded.
    var updateAvailable = false

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

@MainActor
final class AppState: ObservableObject {
    @Published var localFiles: [LocalFile] = []
    @Published var prSessions: [PRSession] = []
    @Published var selection: SidebarSelection?
    @Published var showAddPR = false
    @Published var lastError: String?
    /// Informational, non-error messages ("no Markdown files here") — shown
    /// as a plain notice, never behind the "Something went wrong" title.
    @Published var lastNotice: String?
    /// Transient "Show Markdown Source" (⌥⌘U): flips the active document
    /// view to the raw text. Deliberately not persisted — reading stays the
    /// default on every launch.
    @Published var sourceViewVisible = false
    /// ⌘K Open Quickly palette.
    @Published var openQuicklyVisible = false
    /// Manual-save mode: unsaved block edits per file URL. The rendered
    /// view prefers this overlay over the on-disk text; File → Save (⌘S)
    /// writes it out and clears the entry.
    @Published var editedText: [URL: String] = [:]
    /// The on-disk text each overlay was based on — ⌘S compares against it
    /// to catch the file changing underneath (another editor, an agent).
    var editedBase: [URL: String] = [:]
    /// Presents the commit sheet for a repo root (File → Commit Changes…).
    @Published var commitRequest: CommitRequest?

    /// Writes the pending overlay for `url` to disk; the file watcher's
    /// re-read then converges the view. If the file changed on disk since
    /// the overlay was created, asks before overwriting the other writer's
    /// version. Errors surface in lastError.
    func saveEdits(for url: URL) {
        guard let text = editedText[url] else { return }
        if let base = editedBase[url],
           let diskNow = try? String(contentsOf: url, encoding: .utf8),
           diskNow != base {
            let alert = NSAlert()
            alert.messageText = "“\(url.lastPathComponent)” changed on disk"
            alert.informativeText = "The file was modified while you were editing "
                + "(another app or agent?). Saving will overwrite that version."
            alert.addButton(withTitle: "Overwrite")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        do {
            EditHistory.snapshot(url)
            try text.write(to: url, atomically: true, encoding: .utf8)
            editedText[url] = nil
            editedBase[url] = nil
        } catch {
            lastError = "Couldn't save \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }
    @Published var findBarVisible = false
    @Published var recents: [RecentItem] = []
    @Published var searchPaletteVisible = false
    /// Query handed from the search palette to the detail view it opened;
    /// consumed once (the view drives find-in-page with it after its page
    /// loads, so the term is highlighted and scrolled into view).
    @Published var pendingSearchQuery: String?
    /// See ActiveDocument; nil while a diff, the PR overview, or the empty
    /// placeholder is frontmost (export/copy menu items disable themselves).
    @Published var activeDocument: ActiveDocument?

    let client = GitHubClient.shared

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
        // Registering also flushes any open-file events that arrived before
        // any state existed (cold launch with a document). The handler
        // routes through keyInstance so re-registration by later windows
        // is harmless.
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
        loadRecents()
        Task { @MainActor [weak self] in
            // Brief grace so launch-time opens (CLI, Finder) land first —
            // restore skips itself when anything is already open.
            try? await Task.sleep(nanoseconds: 300_000_000)
            self?.restoreSessionIfWanted()
            await self?.refreshInboxIfDue()
        }
    }

    // MARK: - Review-request inbox

    @Published var inbox: [GitHubClient.InboxPR] = []
    /// Markdown-file counts per inbox id, cached per update stamp.
    @Published var inboxMDCounts: [String: Int] = [:]
    private var lastInboxRefresh: Date?

    var inboxEnabled: Bool {
        UserDefaults.standard.object(forKey: DefaultsKeys.inboxEnabled) as? Bool ?? true
    }

    /// Search-API rate limits are tight (30/min): refresh at most every
    /// five minutes, quietly — an inbox should never produce error alerts.
    func refreshInboxIfDue() async {
        // Only the key window polls — N windows sharing one rate limit
        // would multiply identical searches for identical results.
        guard inboxEnabled, Self.keyInstance === self else { return }
        if let last = lastInboxRefresh, Date().timeIntervalSince(last) < 300 { return }
        lastInboxRefresh = Date()
        guard let items = try? await client.reviewRequests() else { return }
        inbox = items
        // Badge counts: top 15 only, cache pruned to live entries.
        let liveKeys = Set(items.map { $0.id + "@" + $0.updatedAt })
        inboxMDCounts = inboxMDCounts.filter { liveKeys.contains($0.key) }
        for item in items.prefix(15) {
            let cacheKey = item.id + "@" + item.updatedAt
            if inboxMDCounts[cacheKey] == nil,
               let count = try? await client.markdownFileCount(item.ref) {
                inboxMDCounts[cacheKey] = count
            }
        }
    }

    func inboxMDCount(_ item: GitHubClient.InboxPR) -> Int? {
        inboxMDCounts[item.id + "@" + item.updatedAt]
    }

    func inboxIsUnread(_ item: GitHubClient.InboxPR) -> Bool {
        let seen = UserDefaults.standard.dictionary(forKey: DefaultsKeys.inboxSeen) as? [String: String]
        return seen?[item.id] != item.updatedAt
    }

    func openInboxItem(_ item: GitHubClient.InboxPR) {
        var seen = UserDefaults.standard.dictionary(forKey: DefaultsKeys.inboxSeen) as? [String: String] ?? [:]
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
        UserDefaults.standard.set(seen, forKey: DefaultsKeys.inboxSeen)
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
    /// default on). Snapshots are written on every sidebar change; restore
    /// is skipped when the app was launched to open something specific.
    /// PRs from the previous snapshot that haven't (re)opened yet — kept in
    /// every new snapshot so an offline launch can't erase them.
    private var pendingRestorePRs: Set<String> = []

    func snapshotSession() {
        let openPRs = prSessions.map { "\($0.ref.owner)/\($0.ref.repo)#\($0.ref.number)" }
        let snapshot: [String: [String]] = [
            "files": localFiles.map(\.url.path),
            "prs": Array(Set(openPRs).union(pendingRestorePRs)),
        ]
        UserDefaults.standard.set(snapshot, forKey: DefaultsKeys.sessionSnapshot)
    }

    private func restoreSessionIfWanted() {
        // Only the first window restores — ⌘N must open EMPTY windows,
        // not clones of the last session.
        guard Self.keyInstance === self,
              UserDefaults.standard.object(forKey: DefaultsKeys.restoreSession) as? Bool ?? true,
              localFiles.isEmpty, prSessions.isEmpty,
              let snapshot = UserDefaults.standard.dictionary(forKey: DefaultsKeys.sessionSnapshot)
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
        session.reviewComments = (try? await client.reviewComments(ref)) ?? []
        session.threadMeta = (try? await client.reviewThreadMeta(ref)) ?? [:]
        prSessions.append(session)
        selection = .prOverview(session.id)
        noteRecent(RecentItem(kind: .pr, owner: ref.owner, repo: ref.repo, number: ref.number,
                              title: details.title, prStatus: PRStatus(details: details),
                              lastOpened: Date()))
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
        for session in prSessions where !session.updateAvailable {
            guard let details = try? await client.pullRequest(session.ref) else { continue }
            updateRecentPRStatus(ref: session.ref, status: PRStatus(details: details))
            if details.head.sha != session.details.head.sha,
               let index = prSessions.firstIndex(where: { $0.id == session.id }) {
                prSessions[index].updateAvailable = true
            }
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
            let comments = (try? await client.reviewComments(ref)) ?? []
            guard let index = prSessions.firstIndex(where: { $0.id == sessionID }) else { return }
            prSessions[index].details = details
            prSessions[index].files = files
            prSessions[index].mergeBaseSHA = mergeBase
            prSessions[index].reviewComments = comments
            prSessions[index].threadMeta = (try? await client.reviewThreadMeta(ref)) ?? [:]
            prSessions[index].updateAvailable = false
            // Cached document text may predate the new head; views refill it.
            dropPRContentCache(sessionID: sessionID)
            updateRecentPRStatus(ref: ref, status: PRStatus(details: details))
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
        guard let data = UserDefaults.standard.data(forKey: Self.recentsKey),
              let decoded = try? JSONDecoder().decode([RecentItem].self, from: data)
        else { return }
        recents = decoded
    }

    private func saveRecents() {
        if let data = try? JSONEncoder().encode(recents) {
            UserDefaults.standard.set(data, forKey: Self.recentsKey)
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

    func removePR(_ id: String) {
        prSessions.removeAll { $0.id == id }
        dropPRContentCache(sessionID: id)
        switch selection {
        case .prOverview(let s):
            if s == id { selection = nil }
        case .prFile(let s, _):
            if s == id { selection = nil }
        default:
            break
        }
    }

    // MARK: - Review drafts

    func addDraft(sessionID: String, _ draft: DraftComment) {
        guard let index = prSessions.firstIndex(where: { $0.id == sessionID }) else { return }
        prSessions[index].drafts.append(draft)
    }

    func removeDraft(sessionID: String, draftID: UUID) {
        guard let index = prSessions.firstIndex(where: { $0.id == sessionID }) else { return }
        prSessions[index].drafts.removeAll { $0.id == draftID }
    }

    func clearDrafts(sessionID: String) {
        guard let index = prSessions.firstIndex(where: { $0.id == sessionID }) else { return }
        prSessions[index].drafts.removeAll()
    }
}
