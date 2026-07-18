import Foundation
import QuickLookUI
import JavaScriptCore

/// Data-based Quick Look preview: WKWebView's content process is not allowed
/// inside the QL sandbox, so Markdown is rendered to static HTML with the
/// same marked.js pipeline running in JavaScriptCore (no DOM), and Quick Look
/// displays the HTML itself. Code blocks are pre-highlighted; Mermaid
/// diagrams degrade to plain code blocks in previews.
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        StaticRenderer.debugLog("providePreview: \(request.fileURL.lastPathComponent)")
        let markdown = try String(contentsOf: request.fileURL, encoding: .utf8)
        let html: String
        do {
            html = try StaticRenderer.shared.renderPage(
                markdown: markdown,
                title: request.fileURL.lastPathComponent
            )
            StaticRenderer.debugLog("rendered \(html.utf8.count) bytes")
        } catch {
            StaticRenderer.debugLog("render error: \(error)")
            throw error
        }
        let reply = QLPreviewReply(
            dataOfContentType: .html,
            contentSize: CGSize(width: 820, height: 940)
        ) { _ in
            Data(html.utf8)
        }
        reply.title = request.fileURL.lastPathComponent
        return reply
    }
}

final class StaticRenderer {
    static let shared = StaticRenderer()

    /// Debug-build diagnostics; lives in the sandbox tmp container.
    static func debugLog(_ message: String) {
        #if DEBUG
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pullmark-ql.log")
        let line = "\(Date()) \(message)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
        #endif
    }

    enum RenderError: LocalizedError {
        case resourcesMissing
        case javascriptFailed(String)
        var errorDescription: String? {
            switch self {
            case .resourcesMissing: return "Bundled rendering assets not found"
            case .javascriptFailed(let message): return "Markdown rendering failed: \(message)"
            }
        }
    }

    private let context = JSContext()!
    private var stylesheet = ""
    private var ready = false

    private init() {
        setUp()
    }

    private func setUp() {
        guard let bundleURL = Bundle.main.url(forResource: "PullMark_PullMark", withExtension: "bundle"),
              let resources = Bundle(url: bundleURL)?
                  .url(forResource: "app", withExtension: "css", subdirectory: "Resources")?
                  .deletingLastPathComponent()
        else { return }
        let vendor = resources.appendingPathComponent("vendor")

        func load(_ name: String) -> String? {
            try? String(contentsOf: vendor.appendingPathComponent(name), encoding: .utf8)
        }
        guard let marked = load("marked.min.js"),
              let alert = load("marked-alert.min.js"),
              let footnote = load("marked-footnote.min.js"),
              let hljs = load("highlight.min.js"),
              let markdownCSS = load("github-markdown.css"),
              let hljsLight = load("hljs-github.min.css"),
              let hljsDark = load("hljs-github-dark.min.css")
        else { return }

        stylesheet = """
        <style>\(markdownCSS)</style>
        <style media="(prefers-color-scheme: light)">\(hljsLight)</style>
        <style media="(prefers-color-scheme: dark)">\(hljsDark)</style>
        <style>
        body { margin: 0; background: #ffffff; }
        @media (prefers-color-scheme: dark) { body { background: #0d1117; } }
        .markdown-body { max-width: 860px; margin: 0 auto; padding: 24px 24px 48px; }
        </style>
        """

        for script in [marked, alert, footnote, hljs] {
            context.evaluateScript(script)
        }
        context.evaluateScript("""
        function __escapeHtml(s) {
          return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
        }
        marked.use(markedAlert());
        marked.use(markedFootnote());
        marked.use({ gfm: true });
        marked.use({
          renderer: {
            code: function (token) {
              var text = token.text || "";
              var lang = ((token.lang || "").trim().split(/\\s+/)[0] || "").toLowerCase();
              if (lang && lang !== "mermaid" && typeof hljs !== "undefined" && hljs.getLanguage(lang)) {
                try {
                  return '<pre><code class="hljs">' + hljs.highlight(text, { language: lang }).value + '</code></pre>';
                } catch (e) { /* fall through */ }
              }
              return '<pre><code>' + __escapeHtml(text) + '</code></pre>';
            }
          }
        });
        function __render(src) { return marked.parse(src); }
        """)
        ready = context.objectForKeyedSubscript("__render")?.isUndefined == false
    }

    func renderPage(markdown: String, title: String) throws -> String {
        guard ready else { throw RenderError.resourcesMissing }
        context.exception = nil
        let render = context.objectForKeyedSubscript("__render")
        guard let body = render?.call(withArguments: [markdown])?.toString(),
              context.exception == nil
        else {
            throw RenderError.javascriptFailed(context.exception?.toString() ?? "unknown")
        }
        let escapedTitle = title
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <title>\(escapedTitle)</title>
        \(stylesheet)
        </head>
        <body>
        <article class="markdown-body">
        \(body)
        </article>
        </body>
        </html>
        """
    }
}
