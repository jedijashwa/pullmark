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

/// Toolbar menu listing the document's headings; clicking scrolls to one.
struct OutlineMenu: View {
    let items: [OutlineItem]
    let proxy: WebViewProxy

    var body: some View {
        Menu {
            ForEach(items) { item in
                Button(String(repeating: "    ", count: max(0, item.level - 1)) + item.text) {
                    proxy.scrollToAnchor(item.id)
                }
            }
        } label: {
            Label("Outline", systemImage: "list.bullet.indent")
        }
        .disabled(items.isEmpty)
        .help("Jump to a section")
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
