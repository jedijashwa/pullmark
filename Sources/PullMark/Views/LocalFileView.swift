import SwiftUI

struct LocalFileView: View {
    @EnvironmentObject private var state: AppState
    let file: LocalFile
    @State private var html = ""
    @State private var watcher: FileWatcher?

    var body: some View {
        MarkdownWebView(
            html: html,
            localResourceRoot: file.resourceRoot,
            onOpenLocalFile: { url in state.add(url: url) }
        )
        .background(Color(nsColor: .textBackgroundColor))
        .navigationTitle(file.url.lastPathComponent)
        .navigationSubtitle(file.url.deletingLastPathComponent().path)
        .toolbar {
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
            watcher = FileWatcher(url: file.url) { load() }
        }
        .onDisappear {
            watcher = nil
        }
    }

    private func load() {
        let markdown: String
        do {
            markdown = try String(contentsOf: file.url, encoding: .utf8)
        } catch {
            markdown = "> [!CAUTION]\n> Could not read `\(file.url.path)`: \(error.localizedDescription)"
        }
        html = HTMLBuilder.documentPage(markdown: markdown,
                                        title: file.url.lastPathComponent,
                                        localResources: true)
    }
}
