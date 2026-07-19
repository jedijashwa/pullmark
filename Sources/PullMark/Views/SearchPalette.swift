import SwiftUI

/// One searchable document known to the sidebar: local files are read from
/// disk at search time; PR documents search only text already fetched into
/// the in-memory cache (never the network).
private struct SearchSource {
    let id: String
    let title: String
    let subtitle: String
    let target: SidebarSelection
    /// In-memory text (PR documents); nil means read `url` from disk.
    let content: String?
    let url: URL?
}

/// A file with at least one match, ready for display.
struct FileSearchResult: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let target: SidebarSelection
    let matches: [SearchMatch]
}

/// Watches `AppState.pendingSearchQuery` and calls `consume` when it appears
/// while this view's sidebar target is the current selection (the palette
/// targeted a document that is already on screen, so no page reload — and no
/// `onPageLoaded` — will fire). Kept as a concrete modifier so the detail
/// views' already-long body chains stay type-checkable.
struct PendingSearchConsumer: ViewModifier {
    @EnvironmentObject private var state: AppState
    let target: SidebarSelection
    let consume: () -> Void

    func body(content: Content) -> some View {
        content.onChange(of: state.pendingSearchQuery) { (query: String?) in
            if query != nil, state.selection == target {
                consume()
            }
        }
    }
}

/// Command-palette-style search across everything in the sidebar (⇧⌘F):
/// local files (read from disk off the main thread) and PR documents whose
/// text is already in memory. Results are grouped by file; Enter or a click
/// opens the file and drives find-in-page so the term is highlighted.
struct SearchPalette: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var results: [FileSearchResult] = []
    @State private var searched = false
    @State private var expanded: Set<String> = []
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    private static let collapsedMatchLimit = 5

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.title3)
                TextField("Search all files", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit { openTopResult() }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            content
        }
        .frame(width: 620, height: 440)
        .onAppear {
            DispatchQueue.main.async { focused = true }
        }
        .onExitCommand { dismiss() }
        .onChange(of: query) { newValue in
            scheduleSearch(newValue)
        }
        .onDisappear { searchTask?.cancel() }
    }

    @ViewBuilder private var content: some View {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            hint("Type to search local files and loaded pull request documents.")
        } else if results.isEmpty {
            hint(searched ? "No matches for “\(query)”." : "Searching…")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(results) { result in
                        fileGroup(result)
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    private func hint(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private func fileGroup(_ result: FileSearchResult) -> some View {
        let isExpanded = expanded.contains(result.id)
        let shown = isExpanded ? result.matches
                               : Array(result.matches.prefix(Self.collapsedMatchLimit))
        let hidden = result.matches.count - shown.count

        VStack(alignment: .leading, spacing: 1) {
            Button {
                open(result)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: iconName(for: result.target))
                        .foregroundStyle(.secondary)
                    Text(result.title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.head)
                    Text(result.subtitle)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text("\(result.matches.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 2)

            ForEach(Array(shown.enumerated()), id: \.offset) { _, match in
                Button {
                    open(result)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(match.lineNumber)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .frame(width: 40, alignment: .trailing)
                        Text(snippet(for: match))
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.vertical, 2)
            }

            if hidden > 0 {
                Button("\(hidden) more…") {
                    expanded.insert(result.id)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(Color.accentColor)
                .padding(.leading, 64)
                .padding(.vertical, 2)
            }
        }
        .padding(.bottom, 4)
    }

    private func iconName(for target: SidebarSelection) -> String {
        switch target {
        case .local: return "doc.text"
        case .prFile, .prDoc, .prOverview: return "arrow.triangle.pull"
        }
    }

    /// The matched line with every occurrence bolded; a long prefix is
    /// trimmed so the first match stays visible in a single truncated line.
    private func snippet(for match: SearchMatch) -> AttributedString {
        let original = match.lineText
        // Work in character offsets so trimming the prefix stays simple.
        var offsets: [(Int, Int)] = match.ranges.map {
            (original.distance(from: original.startIndex, to: $0.lowerBound),
             original.distance(from: original.startIndex, to: $0.upperBound))
        }
        var line = original
        var prefix = ""
        if let first = offsets.first, first.0 > 40 {
            let removed = first.0 - 20
            line = String(original.dropFirst(removed))
            prefix = "…"
            offsets = offsets.map { ($0.0 - removed, $0.1 - removed) }
                .filter { $0.0 >= 0 }
        }
        var attributed = AttributedString(prefix)
        var cursor = 0
        let characters = Array(line)
        for (start, end) in offsets where start >= cursor && end <= characters.count {
            if cursor < start {
                attributed += AttributedString(String(characters[cursor..<start]))
            }
            var bold = AttributedString(String(characters[start..<end]))
            bold.font = .callout.bold()
            attributed += bold
            cursor = end
        }
        if cursor < characters.count {
            attributed += AttributedString(String(characters[cursor...]))
        }
        return attributed
    }

    // MARK: - Search

    private func scheduleSearch(_ newQuery: String) {
        searchTask?.cancel()
        searched = false
        let trimmed = newQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            return
        }
        let sources = collectSources()
        searchTask = Task {
            // Debounce keystrokes so search runs on pauses, not every letter.
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            let found = await Task.detached(priority: .userInitiated) { () -> [FileSearchResult] in
                var out: [FileSearchResult] = []
                for source in sources {
                    if Task.isCancelled { return out }
                    let text: String
                    if let content = source.content {
                        text = content
                    } else if let url = source.url,
                              let read = try? String(contentsOf: url, encoding: .utf8) {
                        text = read
                    } else {
                        continue
                    }
                    let matches = ContentSearch.matches(in: text, query: newQuery)
                    if !matches.isEmpty {
                        out.append(FileSearchResult(id: source.id, title: source.title,
                                                    subtitle: source.subtitle,
                                                    target: source.target, matches: matches))
                    }
                }
                return out
            }.value
            guard !Task.isCancelled, newQuery == query else { return }
            results = found
            searched = true
        }
    }

    /// Snapshot of everything searchable, taken on the main actor. PR entries
    /// exist only for documents whose text is already cached in memory —
    /// unfetched PR files are skipped silently (search never hits the
    /// network).
    private func collectSources() -> [SearchSource] {
        var sources: [SearchSource] = []
        for file in state.localFiles {
            sources.append(SearchSource(
                id: "local:" + file.url.path,
                title: file.displayName,
                subtitle: file.resourceRoot.path,
                target: .local(file.url),
                content: nil,
                url: file.url
            ))
        }
        for session in state.prSessions {
            for file in session.markdownFiles where file.status != "removed" {
                guard let text = state.cachedPRContent(sessionID: session.id,
                                                       path: file.filename) else { continue }
                sources.append(SearchSource(
                    id: "pr:\(session.id)|\(file.filename)",
                    title: file.filename,
                    subtitle: session.id,
                    target: .prFile(session.id, file.filename),
                    content: text,
                    url: nil
                ))
            }
            for path in session.browsedDocs {
                guard let text = state.cachedPRContent(sessionID: session.id,
                                                       path: path) else { continue }
                sources.append(SearchSource(
                    id: "prdoc:\(session.id)|\(path)",
                    title: path,
                    subtitle: session.id,
                    target: .prDoc(session.id, path),
                    content: text,
                    url: nil
                ))
            }
        }
        return sources
    }

    // MARK: - Opening results

    private func openTopResult() {
        guard let first = results.first else { return }
        open(first)
    }

    private func open(_ result: FileSearchResult) {
        state.pendingSearchQuery = query
        state.selection = result.target
        dismiss()
    }
}
