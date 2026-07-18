import SwiftUI

struct LocalFileView: View {
    @EnvironmentObject private var state: AppState
    let file: LocalFile
    @State private var html = ""
    @State private var watcher: FileWatcher?
    @State private var outline: [OutlineItem] = []
    @StateObject private var proxy = WebViewProxy()
    @AppStorage("pm.outlinePanel") private var outlineVisible = false

    var body: some View {
        VStack(spacing: 0) {
            if state.findBarVisible {
                FindBar(proxy: proxy)
            }
            HSplitView {
                MarkdownWebView(
                    html: html,
                    localResourceRoot: file.resourceRoot,
                    onOpenLocalFile: { url in state.add(url: url) },
                    onOutline: { outline = $0 },
                    proxy: proxy
                )
                .layoutPriority(1)
                if outlineVisible {
                    OutlineSidebar(items: outline, proxy: proxy)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .navigationTitle(file.url.lastPathComponent)
        .navigationSubtitle(file.url.deletingLastPathComponent().path)
        .toolbar {
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
