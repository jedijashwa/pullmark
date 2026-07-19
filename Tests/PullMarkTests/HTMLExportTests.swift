import Foundation
import Testing
@testable import PullMark

@Suite struct HTMLExportTests {

    // MARK: - Script stripping

    @Test func stripsSrcAndInlineScripts() {
        let html = """
        <head><script src="vendor/marked.min.js"></script></head>
        <body><p>keep</p>
        <script type="application/json" id="pm-payload">{"mode":"document"}</script>
        <script src="app.js"></script>
        </body>
        """
        let out = HTMLExport.strippingScripts(html)
        #expect(!out.contains("<script"))
        #expect(out.contains("<p>keep</p>"))
    }

    @Test func scriptStrippingSurvivesEscapedPayloadContent() {
        // jsonLiteral escapes "<" so a payload can never contain "</script>";
        // markdown text with escapes stays inert and is removed whole.
        let html = "<p>a</p><script id=\"pm-payload\">{\"markdown\":\"\\u003cscript, $x$\"}</script><p>b</p>"
        #expect(HTMLExport.strippingScripts(html) == "<p>a</p><p>b</p>")
    }

    // MARK: - CSP meta

    @Test func stripsOnlyTheCSPMeta() {
        let html = """
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'self'">
        <title>Doc</title>
        """
        let out = HTMLExport.strippingCSPMeta(html)
        #expect(!out.contains("Content-Security-Policy"))
        #expect(out.contains("<meta charset=\"utf-8\">"))
        #expect(out.contains("<title>Doc</title>"))
    }

    // MARK: - Stylesheet inlining

    @Test func inlinesStylesheetsPreservingMedia() {
        let html = """
        <link rel="stylesheet" href="vendor/github-markdown.css">
        <link rel="stylesheet" media="(prefers-color-scheme: dark)" href="vendor/hljs-github-dark.min.css">
        """
        let out = HTMLExport.inliningStylesheets(html) { href in
            switch href {
            case "vendor/github-markdown.css": return "body{color:red}"
            case "vendor/hljs-github-dark.min.css": return ".hljs{background:black}"
            default: return nil
            }
        }
        #expect(!out.contains("<link"))
        #expect(out.contains("<style>\nbody{color:red}\n</style>"))
        #expect(out.contains("<style media=\"(prefers-color-scheme: dark)\">\n.hljs{background:black}\n</style>"))
    }

    @Test func removesLinksWithoutCSS() {
        let html = "<link rel=\"stylesheet\" href=\"vendor/katex/katex.min.css\">\n<p>doc</p>"
        let out = HTMLExport.inliningStylesheets(html) { _ in nil }
        #expect(!out.contains("<link"))
        #expect(!out.contains("<style"))
        #expect(out.contains("<p>doc</p>"))
    }

    @Test func nonStylesheetLinksAreUntouched() {
        let html = "<link rel=\"icon\" href=\"favicon.ico\">"
        #expect(HTMLExport.inliningStylesheets(html) { _ in "x" } == html)
    }

    // MARK: - Image inlining

    @Test func inlinesAppSchemeImages() {
        let html = """
        <img src="pullmark-local:///img/a.png" alt="a">
        <img src="pullmark-remote:///docs/b.png">
        <img src="https://example.com/c.png">
        <img src="data:image/gif;base64,R0lGOD">
        """
        let bytes = Data([0x1, 0x2])
        var asked: [String] = []
        let out = HTMLExport.inliningImages(html) { src in
            asked.append(src)
            return src.hasPrefix("pullmark-local:") ? (bytes, "image/png") : nil
        }
        #expect(asked == ["pullmark-local:///img/a.png", "pullmark-remote:///docs/b.png"])
        #expect(out.contains("src=\"data:image/png;base64,\(bytes.base64EncodedString())\" alt=\"a\""))
        // Unresolvable app-scheme image keeps its URL (best effort).
        #expect(out.contains("src=\"pullmark-remote:///docs/b.png\""))
        // Ordinary web and data images are never touched.
        #expect(out.contains("src=\"https://example.com/c.png\""))
        #expect(out.contains("src=\"data:image/gif;base64,R0lGOD\""))
    }

    // MARK: - CSS asset inlining

    @Test func inlinesCSSURLReferences() {
        let css = """
        @font-face{src:url(fonts/KaTeX_Main-Regular.woff2) format('woff2'),url("fonts/KaTeX_Main-Regular.woff") format('woff');}
        .keep{background:url(missing.png)}
        """
        let woff2 = Data([0xAA])
        let out = HTMLExport.inliningCSSAssets(css) { ref in
            ref == "fonts/KaTeX_Main-Regular.woff2" ? (woff2, "font/woff2") : nil
        }
        #expect(out.contains("url(\"data:font/woff2;base64,\(woff2.base64EncodedString())\") format('woff2')"))
        // Unresolved references are left exactly as they were.
        #expect(out.contains("url(\"fonts/KaTeX_Main-Regular.woff\")"))
        #expect(out.contains("url(missing.png)"))
    }

    // MARK: - Attribute helper + pipeline

    @Test func attributeParsing() {
        let tag = "<link rel=\"stylesheet\" media=\"(prefers-color-scheme: light)\" href=\"app.css\">"
        #expect(HTMLExport.attribute("href", in: tag) == "app.css")
        #expect(HTMLExport.attribute("media", in: tag) == "(prefers-color-scheme: light)")
        #expect(HTMLExport.attribute("title", in: tag) == nil)
    }

    @Test func selfContainedPagePipeline() {
        let dom = """
        <html><head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'">
        <link rel="stylesheet" href="app.css">
        </head><body>
        <article><img src="pullmark-local:///a.png"></article>
        <script src="app.js"></script>
        </body></html>
        """
        let out = HTMLExport.selfContainedPage(
            dom: dom,
            css: { $0 == "app.css" ? "body{margin:0}" : nil },
            imageData: { _ in (Data([0x9]), "image/png") }
        )
        #expect(out.hasPrefix("<!DOCTYPE html>\n<html>"))
        #expect(!out.contains("<script"))
        #expect(!out.contains("Content-Security-Policy"))
        #expect(out.contains("<style>\nbody{margin:0}\n</style>"))
        #expect(out.contains("src=\"data:image/png;base64,\(Data([0x9]).base64EncodedString())\""))
    }

    @Test func doctypeNotDuplicated() {
        let dom = "<!DOCTYPE html>\n<html><body></body></html>"
        let out = HTMLExport.selfContainedPage(dom: dom, css: { _ in nil }, imageData: { _ in nil })
        #expect(out == dom)
    }
}
