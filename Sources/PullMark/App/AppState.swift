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
    @Published var findBarVisible = false
    @Published var recents: [RecentItem] = []

    let client = GitHubClient.shared

    private static let recentsKey = "pm.recents"
    private static let recentsLimit = 12

    private var openURLsObserver: NSObjectProtocol?
    private var updateTimer: Timer?

    init() {
        openURLsObserver = NotificationCenter.default.addObserver(
            forName: .pullMarkOpenURLs, object: nil, queue: .main
        ) { [weak self] note in
            guard let urls = note.object as? [URL] else { return }
            Task { @MainActor in
                for url in urls { self?.add(url: url) }
            }
        }
        // Command-line arguments, in case this state is created before the
        // app delegate finished launching (or vice versa).
        Task { @MainActor [weak self] in
            for url in LaunchArguments.consumeFileURLs() { self?.add(url: url) }
        }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkForPRUpdates() }
        }
        loadRecents()
    }

    deinit {
        updateTimer?.invalidate()
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
        let skippedDirectories: Set<String> = ["node_modules", "vendor", ".build", "dist"]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return }

        var added = 0
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                if skippedDirectories.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }
            let ext = url.pathExtension.lowercased()
            guard ["md", "markdown", "mdown", "mkd", "mdx"].contains(ext) else { continue }
            let relative = url.path.hasPrefix(root.path + "/")
                ? String(url.path.dropFirst(root.path.count + 1))
                : url.lastPathComponent
            addFile(url, displayName: relative, resourceRoot: root)
            added += 1
            if added >= 500 {
                lastError = "Stopped after 500 Markdown files in \(root.lastPathComponent)."
                break
            }
        }
        if added == 0 {
            lastError = "No Markdown files found in \(root.lastPathComponent)."
        }
    }

    private func addFile(_ url: URL, displayName: String, resourceRoot: URL) {
        if !localFiles.contains(where: { $0.url == url }) {
            localFiles.append(LocalFile(url: url, displayName: displayName, resourceRoot: resourceRoot))
        }
        selection = .local(url)
    }

    // MARK: - Pull requests

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

extension Notification.Name {
    static let pullMarkOpenURLs = Notification.Name("pullMarkOpenURLs")
}
