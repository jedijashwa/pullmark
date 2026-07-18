import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var state: AppState
    @AppStorage(Appearance.defaultsKey) private var appearanceRaw = Appearance.system.rawValue

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 270)
        } detail: {
            DetailView()
        }
        .frame(minWidth: 940, minHeight: 620)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    state.openFileOrFolder()
                } label: {
                    Label("Open File or Folder", systemImage: "folder")
                }
                .help("Open local Markdown files or a folder (⌘O)")

                Button {
                    state.showAddPR = true
                } label: {
                    Label("Open Pull Request", systemImage: "arrow.triangle.pull")
                }
                .help("Open a GitHub pull request (⇧⌘O)")

                Menu {
                    Picker("Appearance", selection: $appearanceRaw) {
                        ForEach(Appearance.allCases) { appearance in
                            Text(appearance.label).tag(appearance.rawValue)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Appearance", systemImage: "circle.lefthalf.filled")
                }
                .help("Switch between light, dark, and system appearance")
            }
        }
        .sheet(isPresented: $state.showAddPR) {
            AddPRSheet()
        }
        .alert("Something went wrong", isPresented: errorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(state.lastError ?? "")
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { state.lastError != nil },
            set: { if !$0 { state.lastError = nil } }
        )
    }
}

struct SidebarView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        List(selection: $state.selection) {
            Section("Local Files") {
                if state.localFiles.isEmpty {
                    Text("Open a file or folder to get started.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                ForEach(state.localFiles) { file in
                    Label(file.displayName, systemImage: "doc.text")
                        .tag(SidebarSelection.local(file.url))
                        .contextMenu {
                            Button("Remove from Sidebar") { state.removeLocalFile(file) }
                        }
                }
            }
            Section("Pull Requests") {
                if state.prSessions.isEmpty {
                    Text("Open a PR to review its Markdown changes.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                ForEach(state.prSessions) { session in
                    PRSidebarGroup(session: session)
                }
            }
        }
        .listStyle(.sidebar)
    }
}

private struct PRSidebarGroup: View {
    @EnvironmentObject private var state: AppState
    let session: PRSession
    @State private var expanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(session.markdownFiles) { file in
                Label {
                    Text(file.filename)
                        .lineLimit(1)
                        .truncationMode(.head)
                } icon: {
                    Image(systemName: icon(for: file.status))
                        .foregroundStyle(color(for: file.status))
                }
                .tag(SidebarSelection.prFile(session.id, file.filename))
            }
        } label: {
            // Interpolating the Int directly would go through LocalizedStringKey
            // and render with digit grouping ("#45,206").
            let title: String = "\(session.ref.repo) #\(session.ref.number)"
            Label(title, systemImage: "arrow.triangle.pull")
                .tag(SidebarSelection.prOverview(session.id))
                .contextMenu {
                    Button("Remove from Sidebar") { state.removePR(session.id) }
                }
        }
    }

    private func icon(for status: String) -> String {
        switch status {
        case "added": return "plus.circle"
        case "removed": return "minus.circle"
        case "renamed": return "arrow.right.circle"
        default: return "pencil.circle"
        }
    }

    private func color(for status: String) -> Color {
        switch status {
        case "added": return .green
        case "removed": return .red
        default: return .secondary
        }
    }
}

struct DetailView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        switch state.selection {
        case nil:
            placeholder
        case .local(let url):
            if let file = state.localFile(for: url) {
                LocalFileView(file: file)
                    .id(url)
            } else {
                placeholder
            }
        case .prOverview(let id):
            if state.session(id) != nil {
                PROverviewView(sessionID: id)
                    .id(id)
            } else {
                placeholder
            }
        case .prFile(let id, let path):
            if state.session(id) != nil {
                PRFileView(sessionID: id, path: path)
                    .id(id + "|" + path)
            } else {
                placeholder
            }
        }
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text("Open a Markdown file or a GitHub pull request")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
