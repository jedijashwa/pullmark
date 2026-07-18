import SwiftUI

/// Find-in-page bar shown above a MarkdownWebView (⌘F).
struct FindBar: View {
    @EnvironmentObject private var state: AppState
    let proxy: WebViewProxy

    @State private var query = ""
    @State private var current = 0
    @State private var total = 0
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Find in page", text: $query)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { step("next") }
                .onChange(of: query) { newValue in
                    proxy.find("set", query: newValue) { c, t in
                        current = c; total = t
                    }
                }
            if !query.isEmpty {
                Text("\(current)/\(total)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Button { step("prev") } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless)
                .disabled(total == 0)
            Button { step("next") } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless)
                .disabled(total == 0)
            Button("Done") { close() }
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
        .onAppear { focused = true }
        .onExitCommand { close() }
    }

    private func step(_ action: String) {
        proxy.find(action) { c, t in current = c; total = t }
    }

    private func close() {
        proxy.find("clear") { _, _ in }
        state.findBarVisible = false
    }
}

/// Trailing navigator-style panel listing the document's headings.
struct OutlineSidebar: View {
    let items: [OutlineItem]
    let proxy: WebViewProxy
    var activeID: String? = nil

    var body: some View {
        List {
            Section("Outline") {
                if items.isEmpty {
                    Text("No headings")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(items) { item in
                    Button {
                        proxy.scrollToAnchor(item.id)
                    } label: {
                        Text(item.text)
                            .font(font(for: item.level))
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, CGFloat(max(0, item.level - 1)) * 14)
                    .padding(.vertical, 2)
                    .padding(.horizontal, 4)
                    .background(
                        item.id == activeID ? Color.accentColor.opacity(0.16) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 5)
                    )
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 170, idealWidth: 230, maxWidth: 340)
    }

    private func font(for level: Int) -> Font {
        switch level {
        case 1: return .callout.weight(.semibold)
        case 2: return .callout
        default: return .footnote
        }
    }
}

/// Toolbar toggle for the outline panel.
struct OutlineToggle: View {
    @Binding var visible: Bool

    var body: some View {
        Button {
            visible.toggle()
        } label: {
            Label("Outline", systemImage: "sidebar.right")
        }
        .help("Show or hide the document outline")
    }
}

/// Banner shown when a newer PullMark release is available on GitHub.
struct AppUpdateBanner: View {
    @EnvironmentObject private var updates: UpdateChecker

    var body: some View {
        if let version = updates.availableVersion {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                Text("PullMark \(version) is available.")
                Button("What's New") { updates.showReleaseNotes = true }
                Button("Copy brew Command") { updates.copyBrewCommand() }
                    .help("Copies “brew upgrade --cask pullmark” to the clipboard")
                Spacer()
                Button {
                    updates.dismissAvailableUpdate()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Dismiss — this version won't be suggested again")
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.blue.opacity(0.15))
        }
    }
}

/// Sheet rendering release-notes Markdown with the app's own renderer.
struct ReleaseNotesSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let markdown: String

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            MarkdownWebView(html: HTMLBuilder.documentPage(markdown: markdown, title: title))
                .background(Color(nsColor: .textBackgroundColor))
        }
        .frame(width: 640, height: 520)
    }
}

/// Banner shown when the PR's head moved on GitHub since it was loaded.
struct PRUpdateBanner: View {
    @EnvironmentObject private var state: AppState
    let sessionID: String
    @State private var refreshing = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
            Text("This pull request was updated on GitHub.")
            Button("Refresh") {
                refreshing = true
                Task {
                    await state.refreshPR(sessionID: sessionID)
                    refreshing = false
                }
            }
            .disabled(refreshing)
            if refreshing {
                ProgressView().controlSize(.small)
            }
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.orange.opacity(0.18))
    }
}
