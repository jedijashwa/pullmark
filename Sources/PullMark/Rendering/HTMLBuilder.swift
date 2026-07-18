import Foundation

/// Builds the small HTML documents loaded into the WKWebView. Heavy assets
/// (marked, highlight.js, mermaid, CSS) are referenced by relative path and
/// resolved against the bundled Resources directory via the page's baseURL,
/// so pages stay tiny and assets are parsed from disk once per load.
enum HTMLBuilder {
    struct RenderPayload: Encodable {
        var mode: String
        var markdown: String?
        var segments: [DiffSegmentPayload]?
        var patch: String?
        /// When true, app.js rewrites relative image/link URLs to the
        /// pullmark-local:// scheme served by LocalResourceSchemeHandler.
        var localResources: Bool?
        var outdatedThreads: [ThreadPayload]?
        /// Diff layout: "inline" (default) or "split" (side by side).
        var layout: String?
    }

    /// Base URL for relative asset references in generated pages.
    static let resourcesBaseURL: URL? = Bundle.module
        .url(forResource: "app", withExtension: "js", subdirectory: "Resources")?
        .deletingLastPathComponent()

    static func documentPage(markdown: String, title: String = "", localResources: Bool = false) -> String {
        page(payload: RenderPayload(mode: "document", markdown: markdown,
                                    localResources: localResources ? true : nil),
             title: title)
    }

    static func diffPage(segments: [DiffSegmentPayload],
                         outdatedThreads: [ThreadPayload] = [],
                         layout: String = "inline",
                         title: String = "") -> String {
        page(payload: RenderPayload(mode: "diff", segments: segments,
                                    outdatedThreads: outdatedThreads.isEmpty ? nil : outdatedThreads,
                                    layout: layout),
             title: title)
    }

    static func patchPage(patch: String, title: String = "") -> String {
        page(payload: RenderPayload(mode: "patch", patch: patch), title: title)
    }

    /// Encodes a value as a JSON literal safe to embed inside a <script> tag.
    /// JSONEncoder escapes "/" by default, so "</script>" cannot appear; the
    /// JS line separators U+2028/U+2029 are escaped on top of that.
    static func jsonLiteral<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func page(payload: RenderPayload, title: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <title>\(escapeHTML(title))</title>
        <link rel="stylesheet" href="vendor/github-markdown.css">
        <link rel="stylesheet" media="(prefers-color-scheme: light)" href="vendor/hljs-github.min.css">
        <link rel="stylesheet" media="(prefers-color-scheme: dark)" href="vendor/hljs-github-dark.min.css">
        <link rel="stylesheet" href="app.css">
        </head>
        <body>
        <article id="content" class="markdown-body"></article>
        <script>window.__PAYLOAD__ = \(jsonLiteral(payload));</script>
        <script src="vendor/marked.min.js"></script>
        <script src="vendor/marked-alert.min.js"></script>
        <script src="vendor/marked-footnote.min.js"></script>
        <script src="vendor/highlight.min.js"></script>
        <script src="vendor/mermaid.min.js"></script>
        <script src="app.js"></script>
        </body>
        </html>
        """
    }
}
