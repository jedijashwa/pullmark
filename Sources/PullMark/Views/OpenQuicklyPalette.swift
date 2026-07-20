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

    var body: some View {
        VStack(spacing: 0) {
            TextField("Open Quickly — files, headings, pull requests", text: $query)
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
        .onChange(of: query) { _ in selectedIndex = 0 }
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

    private var filtered: [QuickItem] {
        guard !query.isEmpty else { return Array(candidates.prefix(12)) }
        return candidates
            .compactMap { item in
                OpenQuickly.score(query, in: item.title + " " + item.subtitle)
                    .map { (item, $0) }
            }
            .sorted { $0.1 > $1.1 }
            .prefix(12)
            .map(\.0)
    }
}
