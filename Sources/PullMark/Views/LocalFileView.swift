import SwiftUI

struct LocalFileView: View {
    let url: URL
    @State private var html = ""
    @State private var watcher: FileWatcher?

    var body: some View {
        MarkdownWebView(html: html)
            .background(Color(nsColor: .textBackgroundColor))
            .navigationTitle(url.lastPathComponent)
            .navigationSubtitle(url.deletingLastPathComponent().path)
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
                watcher = FileWatcher(url: url) { load() }
            }
            .onDisappear {
                watcher = nil
            }
    }

    private func load() {
        let markdown: String
        do {
            markdown = try String(contentsOf: url, encoding: .utf8)
        } catch {
            markdown = "> [!CAUTION]\n> Could not read `\(url.path)`: \(error.localizedDescription)"
        }
        html = HTMLBuilder.documentPage(markdown: markdown, title: url.lastPathComponent)
    }
}
