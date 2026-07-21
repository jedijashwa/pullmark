import SwiftUI

private struct QuickItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let action: () -> Void
}

/// ⌘K Open Quickly: one field that jumps anywhere — headings in the
/// current document, sidebar files, PR sessions and their files, recents.
/// Arrow keys move the selection while typing continues in the field
/// (single-line fields pass moveUp/moveDown up the responder chain).
struct OpenQuicklyPalette: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var focused: Bool
    /// Resolved once per query change, off the main thread — the path form
    /// stats the filesystem, and statting an unmounted network volume from
    /// a computed property would beachball the palette per keystroke.
    @State private var direct: ResolvedDirect?

    private struct ResolvedDirect {
        let destination: OpenQuickly.DirectDestination
        let isDirectory: Bool
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Open Quickly — files, headings, pull requests, or paths", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(14)
                .focused($focused)
                .onSubmit { open(at: selectedIndex) }
            Divider()
            if filtered.isEmpty {
                Text(query.isEmpty ? "Nothing open yet — open a file or pull request first."
                                   : "No matches.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { scroller in
                    List {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { index, item in
                            Button { open(at: index) } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: item.icon)
                                        .frame(width: 18)
                                        .foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(item.title).lineLimit(1)
                                        Text(item.subtitle)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(index == selectedIndex
                                ? Color.accentColor.opacity(0.18) : nil)
                            .id(index)
                        }
                    }
                    .listStyle(.plain)
                    .onChange(of: selectedIndex) { scroller.scrollTo($0) }
                }
            }
        }
        .frame(width: 620, height: 440)
        .onAppear { focused = true }
        .onExitCommand { dismiss() }
        .onChange(of: query) { current in
            selectedIndex = 0
            resolveDirect(for: current)
        }
        .onMoveCommand { direction in
            switch direction {
            case .down: selectedIndex = min(selectedIndex + 1, max(0, filtered.count - 1))
            case .up: selectedIndex = max(selectedIndex - 1, 0)
            default: break
            }
        }
    }

    private func open(at index: Int) {
        guard filtered.indices.contains(index) else { return }
        let item = filtered[index]
        dismiss()
        item.action()
    }

    /// Headings of the document on screen come first — "jump within what
    /// I'm reading" is the hot path — then files, PRs, and recents.
    private var candidates: [QuickItem] {
        var items: [QuickItem] = []
        if let document = state.activeDocument {
            for heading in OpenQuickly.headings(in: document.markdown) {
                items.append(QuickItem(
                    id: "h:" + heading.slug,
                    title: heading.title,
                    subtitle: "Heading · \(document.exportBaseName)",
                    icon: "number",
                    action: { document.proxy.scrollToAnchor(heading.slug) }))
            }
        }
        for file in state.localFiles {
            items.append(QuickItem(
                id: "f:" + file.url.path,
                title: file.displayName,
                subtitle: PathAbbreviator.abbreviate(file.url.deletingLastPathComponent().path),
                icon: "doc.text",
                action: { state.selection = .local(file.url) }))
        }
        for session in state.prSessions {
            let refTitle = "\(session.ref.repo) #\(session.ref.number)"
            items.append(QuickItem(
                id: "pr:" + session.id,
                title: refTitle,
                subtitle: "Pull request · \(session.details.title)",
                icon: "arrow.triangle.pull",
                action: { state.selection = .prOverview(session.id) }))
            for file in session.markdownFiles {
                items.append(QuickItem(
                    id: "prf:" + session.id + file.filename,
                    title: file.filename,
                    subtitle: refTitle,
                    icon: "doc.text",
                    action: { state.selection = .prFile(session.id, file.filename) }))
            }
        }
        for item in state.inbox {
            items.append(QuickItem(
                id: "in:" + item.id,
                title: item.title,
                subtitle: "Review requested · \(item.ref.owner)/\(item.ref.repo)#\(item.ref.number)",
                icon: "tray",
                action: { state.openInboxItem(item) }))
        }
        for recent in state.recents {
            items.append(QuickItem(
                id: "r:" + recent.id,
                title: recent.title,
                subtitle: "Recent",
                icon: "clock",
                action: { state.openRecent(recent) }))
        }
        return items
    }

    /// Resolves whether the query IS a destination (PR reference or existing
    /// absolute path). One stat per query, off the main thread; a stale
    /// result from a slow volume never overwrites a newer query's.
    private func resolveDirect(for current: String) {
        direct = nil
        Task.detached(priority: .userInitiated) {
            var resolved: ResolvedDirect?
            if let destination = OpenQuickly.directDestination(for: current) {
                switch destination {
                case .pullRequest:
                    resolved = ResolvedDirect(destination: destination, isDirectory: false)
                case .path(let path):
                    var isDirectory: ObjCBool = false
                    FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                    // Only offer what PullMark can actually show: Markdown
                    // files and folders. "/tmp/photo.png" stays a fuzzy query.
                    let url = URL(fileURLWithPath: path)
                    if isDirectory.boolValue || MarkdownFileType.matches(url.pathExtension) {
                        resolved = ResolvedDirect(destination: destination,
                                                  isDirectory: isDirectory.boolValue)
                    }
                }
            }
            let final = resolved
            await MainActor.run {
                guard query == current else { return }
                direct = final
            }
        }
    }

    /// A query that is itself a destination opens directly, listed above
    /// the fuzzy matches.
    private var directItems: [QuickItem] {
        guard let direct else { return [] }
        switch direct.destination {
        case .path(let path):
            let url = URL(fileURLWithPath: path)
            return [QuickItem(
                id: "direct:path:" + path,
                title: "Open " + url.lastPathComponent,
                subtitle: PathAbbreviator.abbreviate(path),
                icon: direct.isDirectory ? "folder" : "doc.text",
                action: { state.add(url: url) })]
        case .pullRequest(let ref):
            return [QuickItem(
                id: "direct:pr:\(ref.owner)/\(ref.repo)/\(ref.number)",
                title: "Open \(ref.owner)/\(ref.repo) #\(ref.number)",
                subtitle: "Pull request",
                icon: "arrow.triangle.pull",
                action: {
                    Task {
                        do {
                            try await state.addPR("\(ref.owner)/\(ref.repo)#\(ref.number)")
                        } catch {
                            state.lastError = "Couldn't open "
                                + "\(ref.owner)/\(ref.repo)#\(ref.number): "
                                + error.localizedDescription
                        }
                    }
                })]
        }
    }

    /// Candidate ids the direct row would duplicate — an already-open file,
    /// PR session, or inbox entry matching the destination.
    private var directDuplicateIDs: Set<String> {
        guard let direct else { return [] }
        switch direct.destination {
        case .path(let path):
            return ["f:" + path]
        case .pullRequest(let ref):
            var ids: Set<String> = ["in:\(ref.owner)/\(ref.repo)#\(ref.number)"]
            if let session = state.prSessions.first(where: { $0.ref == ref }) {
                ids.insert("pr:" + session.id)
            }
            return ids
        }
    }

    private var filtered: [QuickItem] {
        let direct = directItems
        guard !query.isEmpty else { return Array(candidates.prefix(12)) }
        let duplicates = directDuplicateIDs
        let matches = candidates
            .filter { !duplicates.contains($0.id) }
            .compactMap { item in
                OpenQuickly.score(query, in: item.title + " " + item.subtitle)
                    .map { (item, $0) }
            }
            .sorted { $0.1 > $1.1 }
            .prefix(direct.isEmpty ? 12 : 11)
            .map(\.0)
        return direct + matches
    }
}
