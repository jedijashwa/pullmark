import Foundation
import QuickLookUI
import JavaScriptCore

/// Data-based Quick Look preview: WKWebView's content process is not allowed
/// inside the QL sandbox, so Markdown is rendered to static HTML with the
/// same marked.js pipeline running in JavaScriptCore (no DOM), and Quick Look
/// displays the HTML itself. Code blocks are pre-highlighted; Mermaid
/// diagrams degrade to plain code blocks in previews.
///
/// Previews always use the GitHub theme: the QL sandbox cannot read the
/// app's UserDefaults (separate container), so the reading theme selected
/// in Settings ("pm.theme") intentionally does not apply here.
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
        /* YAML front matter metadata table (kept in sync with app.css). */
        .pm-frontmatter {
          border: 1px solid var(--borderColor-muted, rgba(128, 128, 128, 0.35));
          border-radius: 6px;
          background: var(--bgColor-muted, rgba(128, 128, 128, 0.06));
          margin: 0 0 16px;
        }
        .pm-frontmatter > summary {
          cursor: pointer;
          padding: 6px 12px;
          font-size: 12px;
          font-weight: 600;
          color: var(--fgColor-muted, #6e7781);
          user-select: none;
        }
        .pm-frontmatter[open] > summary {
          border-bottom: 1px solid var(--borderColor-muted, rgba(128, 128, 128, 0.35));
        }
        .markdown-body .pm-frontmatter-table {
          display: table;
          width: 100%;
          margin: 6px 0;
          font-size: 12px;
        }
        .markdown-body .pm-frontmatter-table tr { background: transparent; border: 0; }
        .markdown-body .pm-frontmatter-table th,
        .markdown-body .pm-frontmatter-table td {
          border: 0;
          padding: 2px 12px;
          text-align: left;
          vertical-align: top;
        }
        .markdown-body .pm-frontmatter-table th {
          color: var(--fgColor-muted, #6e7781);
          font-weight: 600;
          white-space: nowrap;
          width: 1%;
        }
        .markdown-body .pm-frontmatter-table pre {
          margin: 0;
          padding: 0;
          background: transparent;
          border-radius: 0;
          font-size: 12px;
          color: inherit;
        }
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
        // Leading YAML front matter renders as a metadata table (same
        // line-based detection as app.js — no YAML parser).
        function __frontMatter(src) {
          var lines = src.split("\\n");
          if (lines.length < 2 || lines[0].replace(/\\r$/, "") !== "---") { return null; }
          for (var i = 1; i < lines.length; i++) {
            if (lines[i].trim() === "---") {
              return { lines: lines.slice(1, i), rest: lines.slice(i + 1).join("\\n") };
            }
          }
          return null;
        }
        function __frontMatterHTML(lines) {
          var rows = lines.map(function (line) {
            if (!line.trim()) { return ""; }
            var m = /^([^\\s:#-][^:]*?)[ \\t]*:(?:[ \\t]+(.*))?$/.exec(line);
            if (m) {
              return "<tr><th>" + __escapeHtml(m[1]) + "</th><td>" +
                __escapeHtml((m[2] || "").trim()) + "</td></tr>";
            }
            return '<tr><td colspan="2"><pre>' + __escapeHtml(line) + "</pre></td></tr>";
          }).join("");
          return '<details class="pm-frontmatter"><summary>Front matter</summary>' +
            '<table class="pm-frontmatter-table"><tbody>' + rows + "</tbody></table></details>";
        }
        function __render(src) {
          var fm = __frontMatter(src);
          if (!fm) { return marked.parse(src); }
          return __frontMatterHTML(fm.lines) + marked.parse(fm.rest);
        }
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
        // Static previews run no JavaScript at all, so script-src is 'none';
        // hostile markdown can't execute here even without the policy, but
        // the CSP makes that a guarantee (#5). The bundled styles are inline
        // <style> blocks → 'unsafe-inline'.
        let csp = "default-src 'none'; script-src 'none'; "
            + "style-src 'unsafe-inline'; img-src file: data: https:; "
            + "connect-src 'none'; frame-src 'none'; object-src 'none'"
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(csp)">
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
