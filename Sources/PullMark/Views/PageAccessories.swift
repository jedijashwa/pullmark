import SwiftUI

/// Find-in-page bar shown above a MarkdownWebView (⌘F).
struct FindBar: View {
    @EnvironmentObject private var state: AppState
    let proxy: WebViewProxy
    /// Optional query handed in by the all-files search palette; consumed
    /// once (set to nil after it seeds the field, which runs the find).
    var seed: Binding<String?>? = nil

    @State private var query = ""
    @State private var current = 0
    @State private var total = 0
    @FocusState private var focused: Bool
    @ObservedObject private var shortcuts = ShortcutStore.shared

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
            // The keys live on Edit → Find Next/Previous; these are the
            // pointer affordance for the same actions.
            Button { step("prev") } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless)
                .disabled(total == 0)
                .help("Previous match" + shortcuts.hint(.findPrevious))
            Button { step("next") } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless)
                .disabled(total == 0)
                .help("Next match" + shortcuts.hint(.findNext))
            Button("Done") { close() }
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
        .onAppear {
            consumeSeed()
            // Direct assignment in onAppear loses the race against the
            // WKWebView grabbing first responder; defer one runloop turn.
            DispatchQueue.main.async { focused = true }
        }
        .onChange(of: seed?.wrappedValue) { _ in consumeSeed() }
        .onChange(of: state.documentCommand) { request in
            guard request != nil else { return }
            if state.take(.findNext) { step("next") }
            if state.take(.findPrevious) { step("prev") }
        }
        .onExitCommand { close() }
    }

    private func consumeSeed() {
        guard let value = seed?.wrappedValue, !value.isEmpty else { return }
        seed?.wrappedValue = nil
        if query != value {
            // Assigning `query` triggers onChange, which runs the find.
            query = value
        } else {
            // Same query re-seeded after a page reload: onChange won't
            // fire, so run the find directly to restore the highlights.
            proxy.find("set", query: value) { c, t in
                current = c; total = t
            }
        }
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

/// Unobtrusive word count / reading time pill overlaid on document views
/// (bottom-trailing, opposite the in-page link-status pill). Document mode
/// only — diff pages never post stats.
struct DocumentStatsPill: View {
    let stats: DocumentStats

    var body: some View {
        Text("\(stats.words.formatted()) words · \(stats.minutes) min")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(.regularMaterial, in: Capsule())
            .overlay(
                Capsule().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
            .padding(10)
            .allowsHitTesting(false)
            .accessibilityLabel("\(stats.words) words, about \(stats.minutes) minute read")
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

/// Toolbar toggle for per-block blame annotations on rendered documents.
struct BlameToggle: View {
    @Binding var visible: Bool

    var body: some View {
        Toggle(isOn: $visible) {
            Label("Blame", systemImage: "person.crop.circle.badge.clock")
        }
        .help("Show who last changed each block (git blame)")
    }
}

/// Banner shown when a newer PullMark release is available on GitHub.
struct AppUpdateBanner: View {
    @EnvironmentObject private var updates: UpdateChecker

    var body: some View {
        if let version = updates.availableVersion {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                switch updates.updateRun {
                case .updating(let phase):
                    Text(phase)
                    ProgressView().controlSize(.small)
                case .failed(let message):
                    Text("Update failed: \(message)")
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if case .brew = updates.updateMethod {
                        Text(BrewUpdate.command)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                        Button("Copy") { updates.copyBrewCommand() }
                            .help("Copies “\(BrewUpdate.command)” to the clipboard")
                    } else {
                        Button("Open Release Page") { updates.openReleasePage() }
                            .help("Opens the release page on GitHub to update manually")
                    }
                case .idle:
                    Text("PullMark \(version) is available.")
                    Button("What's New") { updates.showReleaseNotes = true }
                    primaryButton
                }
                Spacer()
                Button {
                    updates.dismissAvailableUpdate()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .disabled(updates.isUpdating)
                .help("Dismiss — this version won't be suggested again")
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.blue.opacity(0.15))
            .onAppear { updates.detectUpdateMethodIfNeeded() }
        }
    }

    /// "Update Now" for brew-managed installs (runs brew) and for other real
    /// .app installs (verified in-place self-update); disabled while the
    /// install method is still being probed. "Download" for dev builds.
    @ViewBuilder private var primaryButton: some View {
        switch updates.updateMethod {
        case .brew, nil:
            Button("Update Now") { updates.updateNow() }
                .buttonStyle(.borderedProminent)
                .disabled(updates.updateMethod == nil)
                .help("Runs “\(BrewUpdate.command)” and relaunches PullMark")
        case .selfUpdate:
            Button("Update Now") { updates.updateNow() }
                .buttonStyle(.borderedProminent)
                .help("Downloads the update, verifies its signature, and installs it in place")
        case .download:
            Button("Download") { updates.updateNow() }
                .buttonStyle(.borderedProminent)
                .help("Opens the release page on GitHub")
        }
    }
}

/// Banner shown when the user had made PullMark the default Markdown app and
/// Launch Services lost the binding (typically after a brew upgrade replaced
/// the bundle on disk). Dismissing clears the claim so it never nags.
struct DefaultAppBanner: View {
    @EnvironmentObject private var defaultApp: DefaultAppManager

    var body: some View {
        if defaultApp.showLossBanner {
            HStack(spacing: 10) {
                Image(systemName: "doc.badge.arrow.up")
                Text("PullMark is no longer your default Markdown app.")
                Button("Make Default Again") { defaultApp.makeDefault() }
                    .disabled(defaultApp.claiming)
                if defaultApp.claiming {
                    ProgressView().controlSize(.small)
                }
                if let error = defaultApp.lastError {
                    Text(error)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer()
                Button {
                    defaultApp.dismissLossBanner()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Dismiss — PullMark won't ask again unless you make it the default")
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
    @AppStorage(Theme.defaultsKey) private var themeRaw = Theme.standard.rawValue
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
            MarkdownWebView(html: {
                let style = ThemeSelection.pageStyle(from: themeRaw)
                return HTMLBuilder.documentPage(
                    markdown: markdown, title: title,
                    theme: style.theme, customCSS: style.customCSS
                )
            }())
                .background(ThemePaper.color(for: themeRaw))
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
