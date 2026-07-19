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
        if !StaticRenderer.wantsRenderedPreviews() {
            html = StaticRenderer.sourcePage(markdown: markdown,
                                             title: request.fileURL.lastPathComponent)
        } else {
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
              let katex = load("katex/katex.min.js"),
              let katexCSS = load("katex/katex.min.css"),
              let extensions = try? String(
                  contentsOf: resources.appendingPathComponent("pm-extensions.js"),
                  encoding: .utf8),
              let markdownCSS = load("github-markdown.css"),
              let hljsLight = load("hljs-github.min.css"),
              let hljsDark = load("hljs-github-dark.min.css")
        else { return }

        // KaTeX's CSS is inlined; its url(fonts/...) references cannot
        // resolve in a data-based preview (no base URL, font-src 'none'), so
        // math falls back to the stacks' system serif fonts — structurally
        // correct, just less pretty than in the app.
        stylesheet = """
        <style>\(markdownCSS)</style>
        <style media="(prefers-color-scheme: light)">\(hljsLight)</style>
        <style media="(prefers-color-scheme: dark)">\(hljsDark)</style>
        <style>\(katexCSS)</style>
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
        /* Math, ==highlight== and [toc] (kept in sync with app.css). */
        .pm-math-block { overflow-x: auto; overflow-y: hidden; margin: 16px 0; }
        .pm-math-block .katex-display { margin: 0; }
        .markdown-body mark {
          background: rgba(255, 212, 0, 0.42);
          color: inherit;
          border-radius: 2px;
          padding: 0 1px;
        }
        @media (prefers-color-scheme: dark) {
          .markdown-body mark { background: rgba(187, 128, 9, 0.45); }
        }
        nav.pm-toc { margin: 0 0 16px; }
        .markdown-body .pm-toc-list { list-style: none; padding-left: 0; margin: 0; }
        .markdown-body .pm-toc-item { margin: 3px 0; }
        .pm-toc-level-2 { padding-left: 16px; }
        .pm-toc-level-3 { padding-left: 32px; }
        .pm-toc-level-4 { padding-left: 48px; }
        .pm-toc-level-5 { padding-left: 64px; }
        .pm-toc-level-6 { padding-left: 80px; }
        </style>
        """

        // app.css carries the reading-theme packs (:root[data-theme="…"]);
        // appended last so a chosen theme's rules win over the inline
        // defaults above. It references no external assets.
        if let appCSS = try? String(contentsOf: resources.appendingPathComponent("app.css"),
                                    encoding: .utf8) {
            stylesheet += "<style>\(appCSS)</style>"
        }

        for script in [marked, alert, footnote, hljs, katex, extensions] {
            context.evaluateScript(script)
        }
        context.evaluateScript("""
        function __escapeHtml(s) {
          return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
        }
        // Parse through a real Marked instance — the UMD namespace's
        // methods are read-only getters, so fixWalkTokens couldn't patch
        // walkTokens on it.
        marked = new marked.Marked();
        // boundStarts keeps lexing linear in document size (see
        // pm-extensions.js) — same registration app.js uses.
        marked.use(pmExtensions.boundStarts(markedAlert()));
        marked.use(pmExtensions.boundStarts(markedFootnote()));
        // Math/[toc]/highlight/sub/sup — the same extension pack app.js
        // uses; KaTeX's renderToString needs no DOM, so math renders here.
        marked.use({ extensions: pmExtensions.extensions() });
        marked.use({ gfm: true });
        // Linear walkTokens (marked's own is quadratic in token count —
        // see pm-extensions.js). Must come after every marked.use.
        pmExtensions.fixWalkTokens(marked);
        // The browser pipeline slugs headings in the DOM; here ids come from
        // a renderer override so [toc] links have anchors to land on.
        var __slugUsed = {};
        marked.use({
          renderer: {
            heading: function (token) {
              var slug = pmExtensions.slugify(token.text) || "section";
              var unique = slug;
              var n = 1;
              while (__slugUsed[unique]) { unique = slug + "-" + n; n += 1; }
              __slugUsed[unique] = true;
              __headings.push({
                level: token.depth,
                id: unique,
                html: this.parser.parseInline(token.tokens)
              });
              return "<h" + token.depth + ' id="' + unique + '">' +
                this.parser.parseInline(token.tokens) + "</h" + token.depth + ">\\n";
            }
          }
        });
        var __headings = [];
        // Builds the [toc] list from the headings collected during parse
        // (h1-h4, matching the app's outline). Labels reuse the rendered
        // inline HTML with tags stripped so nested anchors can't occur.
        function __tocHTML() {
          var items = __headings.filter(function (h) { return h.level <= 4; });
          if (!items.length) { return '<p class="pm-toc-empty">No headings</p>'; }
          var min = items.reduce(function (m, h) { return Math.min(m, h.level); }, 6);
          return '<ul class="pm-toc-list">' + items.map(function (h) {
            var label = h.html.replace(/<[^>]*>/g, "");
            return '<li class="pm-toc-item pm-toc-level-' + (h.level - min + 1) +
              '"><a href="#' + h.id + '">' + label + "</a></li>";
          }).join("") + "</ul>";
        }
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
          __slugUsed = {};
          __headings = [];
          var fm = __frontMatter(src);
          var body = marked.parse(fm ? fm.rest : src);
          // Fill the [toc] placeholders the pmToc extension emitted; the
          // whole document has been parsed by now, so __headings is complete.
          if (body.indexOf(pmExtensions.TOC_PLACEHOLDER) !== -1) {
            var open = pmExtensions.TOC_PLACEHOLDER.replace("></nav>", ">");
            var filled = open + __tocHTML() + "</nav>";
            body = body.split(pmExtensions.TOC_PLACEHOLDER).join(filled);
          }
          return fm ? __frontMatterHTML(fm.lines) + body : body;
        }
        """)
        ready = context.objectForKeyedSubscript("__render")?.isUndefined == false
    }

    /// Settings → "Quick Look previews: Rendered / Raw Source", mirrored
    /// into the shared suite like the theme. Absent means rendered.
    static func wantsRenderedPreviews() -> Bool {
        UserDefaults(suiteName: "35F47G5Y6D.app.pullmark")?
            .object(forKey: "pm.qlRendered") as? Bool ?? true
    }

    /// Raw-source preview: escaped monospace text, following the system
    /// light/dark appearance. Same no-scripts CSP as rendered previews.
    static func sourcePage(markdown: String, title: String) -> String {
        func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        let csp = "default-src 'none'; script-src 'none'; "
            + "style-src 'unsafe-inline'; img-src 'none'; "
            + "connect-src 'none'; frame-src 'none'; object-src 'none'"
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(csp)">
        <title>\(escape(title))</title>
        <style>
        :root { color-scheme: light dark; }
        body {
          margin: 0;
          background: #ffffff;
          color: #1f2328;
        }
        pre {
          margin: 0;
          padding: 20px 24px;
          font: 12.5px/1.65 ui-monospace, "SF Mono", SFMono-Regular, Menlo, Consolas, monospace;
          white-space: pre;
          overflow-x: auto;
        }
        @media (prefers-color-scheme: dark) {
          body { background: #0d1117; color: #e6edf3; }
        }
        </style>
        </head>
        <body>
        <pre>\(escape(markdown))</pre>
        </body>
        </html>
        """
    }

    /// The app mirrors its reading-theme choice into the shared app-group
    /// suite (see SharedTheme in the app target) because a sandboxed appex
    /// cannot read another bundle's defaults. Built-in themes apply
    /// directly; custom .css themes live in the app's container where this
    /// appex can't reach, so they fall back to their GitHub base; no stored
    /// value means the app-default Editorial.
    static func sharedTheme() -> String {
        let raw = UserDefaults(suiteName: "35F47G5Y6D.app.pullmark")?
            .string(forKey: "pm.theme")
        switch raw {
        case "github", "editorial", "terminal": return raw!
        case .some(let value) where value.hasPrefix("custom:"): return "github"
        default: return "editorial"
        }
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
        <html data-theme="\(Self.sharedTheme())">
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
