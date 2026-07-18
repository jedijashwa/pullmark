import AppKit
import SwiftUI

struct LocalFile: Identifiable, Equatable {
    let url: URL
    let displayName: String
    var id: URL { url }
}

struct PRSession: Identifiable {
    let ref: PullRequestRef
    var details: PullRequestDetails
    var mergeBaseSHA: String
    var files: [PullRequestFile]
    var drafts: [DraftComment] = []

    var id: String { "\(ref.owner)/\(ref.repo)#\(ref.number)" }
    var markdownFiles: [PullRequestFile] { files.filter(\.isMarkdown) }
    var otherFileCount: Int { files.count - markdownFiles.count }
}

enum SidebarSelection: Hashable {
    case local(URL)
    case prOverview(String)
    case prFile(String, String)
}

struct MessageError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
final class AppState: ObservableObject {
    @Published var localFiles: [LocalFile] = []
    @Published var prSessions: [PRSession] = []
    @Published var selection: SidebarSelection?
    @Published var showAddPR = false
    @Published var lastError: String?

    let client = GitHubClient.shared

    private var openURLsObserver: NSObjectProtocol?

    init() {
        openURLsObserver = NotificationCenter.default.addObserver(
            forName: .pullMarkOpenURLs, object: nil, queue: .main
        ) { [weak self] note in
            guard let urls = note.object as? [URL] else { return }
            Task { @MainActor in
                for url in urls { self?.add(url: url) }
            }
        }
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
        } else {
            addFile(url, displayName: url.lastPathComponent)
        }
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
            addFile(url, displayName: relative)
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

    private func addFile(_ url: URL, displayName: String) {
        if !localFiles.contains(where: { $0.url == url }) {
            localFiles.append(LocalFile(url: url, displayName: displayName))
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
        let details = try await client.pullRequest(ref)
        let files = try await client.files(ref)
        var mergeBase = details.base.sha
        do {
            mergeBase = try await client.mergeBaseSHA(ref, base: details.base.sha, head: details.head.sha)
        } catch {
            // Fall back to the base tip; only matters when the base branch moved.
        }
        let session = PRSession(ref: ref, details: details, mergeBaseSHA: mergeBase, files: files)
        prSessions.append(session)
        selection = .prOverview(session.id)
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
