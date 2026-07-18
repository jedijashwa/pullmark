import SwiftUI

struct LocalFileView: View {
    @EnvironmentObject private var state: AppState
    let file: LocalFile

    @State private var currentText = ""
    @State private var watcher: FileWatcher?
    @State private var outline: [OutlineItem] = []
    @State private var activeSection: String?
    @StateObject private var proxy = WebViewProxy()
    @AppStorage(DefaultsKeys.outlinePanel) private var outlineVisible = false
    @AppStorage(Theme.defaultsKey) private var themeRaw = Theme.github.rawValue

    // Git history / branch comparison
    struct CompareTarget: Equatable {
        let ref: String
        let label: String
    }
    @State private var inGitRepo = false
    @State private var commits: [LocalGit.Commit] = []
    @State private var branches: [String] = []
    @State private var remoteBranches: [String] = []
    @State private var compare: CompareTarget?
    @State private var compareText: String?

    // Blame annotations
    @AppStorage(DefaultsKeys.blame) private var blameVisible = false
    @State private var blamePayloads: [BlockBlamePayload]?
    @State private var blameNote: String?

    var body: some View {
        VStack(spacing: 0) {
            if let compare {
                HStack(spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath")
                    Text("Comparing with \(compare.label)")
                    Spacer()
                    Button("Done") { stopComparing() }
                }
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.blue.opacity(0.14))
            }
            if state.findBarVisible {
                FindBar(proxy: proxy)
            }
            HSplitView {
                MarkdownWebView(
                    html: html,
                    localResourceRoot: file.resourceRoot,
                    onOpenLocalFile: { url in state.add(url: url) },
                    onOutline: { outline = $0 },
                    onActiveSection: { activeSection = $0.isEmpty ? nil : $0 },
                    proxy: proxy
                )
                .layoutPriority(1)
                if outlineVisible {
                    OutlineSidebar(items: outline, proxy: proxy, activeID: activeSection)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .navigationTitle(file.url.lastPathComponent)
        .navigationSubtitle(file.url.deletingLastPathComponent().path)
        .toolbar {
            ToolbarItem {
                compareMenu
            }
            ToolbarItem {
                BlameToggle(visible: $blameVisible)
                    .disabled(!inGitRepo || compare != nil)
            }
            ToolbarItem {
                OutlineToggle(visible: $outlineVisible)
            }
            ToolbarItem {
                Button {
                    load()
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                .help("Reload from disk")
            }
        }
        .onAppear {
            load()
            loadGitInfo()
            watcher = FileWatcher(url: file.url) { load() }
        }
        .onDisappear {
            watcher = nil
        }
        .onChange(of: blameVisible) { _ in loadBlame() }
        .onChange(of: currentText) { _ in loadBlame() }
        .onChange(of: inGitRepo) { _ in loadBlame() }
    }

    @ViewBuilder
    private var compareMenu: some View {
        Menu {
            if !commits.isEmpty {
                Section("History") {
                    ForEach(commits) { commit in
                        Button("\(commit.shortSHA) · \(commit.date) · \(commit.subject)") {
                            startComparing(ref: commit.sha,
                                           label: "\(commit.shortSHA) (\(commit.date))")
                        }
                    }
                }
            }
            if !branches.isEmpty {
                Section("Branches") {
                    ForEach(branches, id: \.self) { branch in
                        Button(branch) { startComparing(ref: branch, label: branch) }
                    }
                }
            }
            if !remoteBranches.isEmpty {
                Section("Remote Branches") {
                    ForEach(remoteBranches, id: \.self) { branch in
                        Button(branch) { startComparing(ref: branch, label: branch) }
                    }
                }
            }
            if compare != nil {
                Divider()
                Button("Stop Comparing") { stopComparing() }
            }
        } label: {
            Label("Compare", systemImage: "clock.arrow.circlepath")
        }
        .disabled(!inGitRepo)
        .help(inGitRepo ? "Compare with a previous revision or branch"
                        : "Not inside a git repository")
    }

    private var html: String {
        let theme = Theme.current(from: themeRaw).rawValue
        if compare != nil, let compareText {
            let segments = DiffPageBuilder.segments(old: compareText, new: currentText)
            return HTMLBuilder.diffPage(segments: segments, commentable: false,
                                        title: file.url.lastPathComponent,
                                        theme: theme)
        }
        return HTMLBuilder.documentPage(markdown: currentText,
                                        title: file.url.lastPathComponent,
                                        localResources: true,
                                        theme: theme,
                                        blame: blameVisible ? blamePayloads : nil,
                                        blameNote: blameVisible ? blameNote : nil)
    }

    private func load() {
        do {
            currentText = try String(contentsOf: file.url, encoding: .utf8)
        } catch {
            currentText = "> [!CAUTION]\n> Could not read `\(file.url.path)`: \(error.localizedDescription)"
        }
    }

    private func loadGitInfo() {
        let url = file.url
        Task.detached(priority: .utility) {
            guard let root = LocalGit.repoRoot(for: url) else { return }
            let commits = LocalGit.history(of: url)
            let branches = LocalGit.branches(in: root, remote: false)
            let remotes = LocalGit.branches(in: root, remote: true)
            await MainActor.run {
                self.inGitRepo = true
                self.commits = commits
                self.branches = branches
                self.remoteBranches = remotes
            }
        }
    }

    private func loadBlame() {
        guard blameVisible, inGitRepo else { return }
        let url = file.url
        let text = currentText
        Task {
            let payloads = await BlameService.localPayloads(client: state.client,
                                                            fileURL: url, markdown: text)
            // The file may have been edited while blame was computed.
            guard text == currentText else { return }
            blamePayloads = payloads
            blameNote = payloads == nil
                ? "Blame unavailable — the file is not tracked by git." : nil
        }
    }

    private func startComparing(ref: String, label: String) {
        let url = file.url
        Task.detached(priority: .userInitiated) {
            let old = LocalGit.content(of: url, at: ref)
            await MainActor.run {
                guard let old else {
                    state.lastError = "\(url.lastPathComponent) does not exist at \(label)."
                    return
                }
                compareText = old
                compare = CompareTarget(ref: ref, label: label)
            }
        }
    }

    private func stopComparing() {
        compare = nil
        compareText = nil
    }
}
