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
        /// False for diffs without a review target (local comparisons).
        var commentable: Bool?
        /// Remote (PR) documents: rewrite relative images and links to the
        /// pullmark-remote scheme (resolved against resourceDir).
        var remoteResources: Bool?
        /// Repo directory containing the rendered file ("" for repo root).
        var resourceDir: String?
        /// Reading theme ("github", "editorial", "terminal"). app.js mirrors
        /// it onto <html data-theme="..."> before rendering; app.css only
        /// styles the non-default themes, so "github" stays pixel-identical.
        var theme: String?
        /// Miniature non-interactive rendering for the Settings theme cards
        /// (scaled down via CSS zoom, selection and scrollbars disabled).
        var preview: Bool?
        /// Per-block blame annotations (document mode). When present the page
        /// renders block-by-block with an annotation strip under each block.
        var blame: [BlockBlamePayload]?
        /// One-line note shown when blame was requested but unavailable.
        var blameNote: String?
    }

    /// Options for rendering a file that lives in a GitHub repo.
    struct RemoteAssets {
        let resourceDir: String

        init(filePath: String) {
            self.resourceDir = (filePath as NSString).deletingLastPathComponent
        }
    }

    /// Base URL for relative asset references in generated pages.
    static let resourcesBaseURL: URL? = Bundle.module
        .url(forResource: "app", withExtension: "js", subdirectory: "Resources")?
        .deletingLastPathComponent()

    static func documentPage(markdown: String, title: String = "",
                             localResources: Bool = false,
                             remote: RemoteAssets? = nil,
                             theme: String = "github",
                             preview: Bool = false,
                             blame: [BlockBlamePayload]? = nil,
                             blameNote: String? = nil) -> String {
        page(payload: RenderPayload(mode: "document", markdown: markdown,
                                    localResources: localResources ? true : nil,
                                    remoteResources: remote != nil ? true : nil,
                                    resourceDir: remote?.resourceDir,
                                    theme: theme,
                                    preview: preview ? true : nil,
                                    blame: blame,
                                    blameNote: blameNote),
             title: title)
    }

    static func diffPage(segments: [DiffSegmentPayload],
                         outdatedThreads: [ThreadPayload] = [],
                         layout: String = "inline",
                         remote: RemoteAssets? = nil,
                         commentable: Bool = true,
                         title: String = "",
                         theme: String = "github",
                         preview: Bool = false) -> String {
        page(payload: RenderPayload(mode: "diff", segments: segments,
                                    outdatedThreads: outdatedThreads.isEmpty ? nil : outdatedThreads,
                                    layout: layout,
                                    commentable: commentable ? nil : false,
                                    remoteResources: remote != nil ? true : nil,
                                    resourceDir: remote?.resourceDir,
                                    theme: theme,
                                    preview: preview ? true : nil),
             title: title)
    }

    static func patchPage(patch: String, title: String = "",
                          theme: String = "github") -> String {
        page(payload: RenderPayload(mode: "patch", patch: patch, theme: theme),
             title: title)
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

    /// A double-quoted JS string literal with script-safe escaping.
    static func jsStringLiteral(_ s: String) -> String {
        var out = "\""
        for character in s.unicodeScalars {
            switch character {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "/": out += "\\/"
            case "\u{2028}": out += "\\u2028"
            case "\u{2029}": out += "\\u2029"
            default:
                if character.value < 0x20 {
                    out += String(format: "\\u%04x", character.value)
                } else {
                    out.unicodeScalars.append(character)
                }
            }
        }
        return out + "\""
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
