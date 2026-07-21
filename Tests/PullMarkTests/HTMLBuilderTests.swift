import Testing
import Foundation
@testable import PullMark

@Suite struct HTMLBuilderTests {
    @Test func bundledRenderingAssetsResolve() {
        // Regression: resolving assets through the SwiftPM-generated
        // Bundle.module accessor made a packaged app read them from the
        // build machine's .build directory — present only there, so every
        // other machine fatalErrored on the first render. The explicit
        // candidate walk must find the bundle in this (test) environment
        // without touching Bundle.module at all.
        let base = HTMLBuilder.resourcesBaseURL
        #expect(base != nil)
        if let base {
            #expect(FileManager.default.fileExists(atPath: base.appendingPathComponent("app.js").path))
            #expect(FileManager.default.fileExists(atPath: base.appendingPathComponent("vendor").path))
        }
    }

    @Test func scriptCloseTagCannotEscapePayload() {
        let page = HTMLBuilder.documentPage(markdown: "hello </script><script>alert(1)</script>")
        #expect(!page.contains("</script><script>alert"))
        #expect(page.contains("\\u003c\\/script>"))
    }

    @Test func angleBracketsCannotEnterScriptEscapedStates() {
        // "<!--<script>" would flip the HTML parser into the double-escaped
        // script state and swallow the real </script>; no "<" from content
        // may survive in the embedded JSON literal.
        let literal = HTMLBuilder.jsonLiteral(["markdown": "x <!--<script> y"])
        #expect(!literal.contains("<"))
        #expect(literal.contains("\\u003c!--\\u003cscript>"))
    }

    @Test func documentPayloadIsEmbeddedWithoutExecuting() {
        let page = HTMLBuilder.documentPage(markdown: "# Hi", title: "T")
        // Non-executing JSON payload tag, not an executing script (#5).
        #expect(page.contains("<script type=\"application/json\" id=\"pm-payload\">"))
        #expect(!page.contains("window.__PAYLOAD__"))
        #expect(page.contains("\"mode\":\"document\""))
        #expect(page.contains("# Hi"))
        #expect(page.contains("<title>T</title>"))
    }

    @Test func sourcePageCarriesRawMarkdownAsSourceMode() {
        let page = HTMLBuilder.sourcePage(markdown: "# Raw **stuff**", title: "S",
                                          theme: "editorial")
        #expect(page.contains("\"mode\":\"source\""))
        #expect(page.contains("# Raw **stuff**"))
        #expect(page.contains("data-theme=\"editorial\"")
            || page.contains("\"theme\":\"editorial\""))
        // Same non-executing payload embedding as every other page.
        #expect(page.contains("<script type=\"application/json\" id=\"pm-payload\">"))
    }

    @Test func pageGenerationIsDeterministic() {
        // The web view reloads when the page string changes; body recomputes
        // fire on unrelated state (scroll-spy, timers). Nondeterministic
        // JSON key order made identical inputs produce different bytes —
        // the reader was yanked to the top mid-scroll.
        let reference = HTMLBuilder.documentPage(markdown: "# Doc\n\nBody",
                                                 title: "T", localResources: true,
                                                 theme: "editorial", editable: true)
        for _ in 0..<50 {
            let again = HTMLBuilder.documentPage(markdown: "# Doc\n\nBody",
                                                 title: "T", localResources: true,
                                                 theme: "editorial", editable: true)
            #expect(again == reference)
        }
    }

    @Test func pagesCarryTheContentSecurityPolicy() {
        for page in [HTMLBuilder.documentPage(markdown: "x"),
                     HTMLBuilder.diffPage(segments: []),
                     HTMLBuilder.patchPage(patch: "@@")] {
            #expect(page.contains(
                "<meta http-equiv=\"Content-Security-Policy\" content=\"\(HTMLBuilder.contentSecurityPolicy)\">"))
        }
        // Only bundled scripts may execute; inline script and handlers die.
        #expect(HTMLBuilder.contentSecurityPolicy.contains("script-src 'self'"))
        #expect(HTMLBuilder.contentSecurityPolicy.contains("default-src 'none'"))
        // mermaid injects inline <style> into its SVGs.
        #expect(HTMLBuilder.contentSecurityPolicy.contains("style-src 'self' 'unsafe-inline'"))
        // Local files, data URIs, avatars, and the app's resource schemes.
        #expect(HTMLBuilder.contentSecurityPolicy.contains(
            "img-src file: data: https: pullmark-local: pullmark-remote:"))
    }

    @Test func titleIsHTMLEscaped() {
        let page = HTMLBuilder.documentPage(markdown: "", title: "<b>&x")
        #expect(page.contains("<title>&lt;b&gt;&amp;x</title>"))
    }

    @Test func diffPageEmbedsSegments() {
        let segment = DiffSegmentPayload(kind: "added", text: "new", oldText: nil,
                                         lineStart: 4, lineEnd: 6, side: "RIGHT")
        let page = HTMLBuilder.diffPage(segments: [segment])
        #expect(page.contains("\"mode\":\"diff\""))
        #expect(page.contains("\"lineStart\":4"))
        #expect(page.contains("\"side\":\"RIGHT\""))
    }

    @Test func lineSeparatorsAreEscaped() {
        let literal = HTMLBuilder.jsonLiteral(["text": "a\u{2028}b\u{2029}c"])
        #expect(!literal.contains("\u{2028}"))
        #expect(!literal.contains("\u{2029}"))
        #expect(literal.contains("\\u2028"))
    }

    @Test func defaultThemeIsGitHub() {
        for page in [HTMLBuilder.documentPage(markdown: "x"),
                     HTMLBuilder.diffPage(segments: []),
                     HTMLBuilder.patchPage(patch: "@@")] {
            #expect(page.contains("\"theme\":\"github\""))
        }
    }

    @Test func themeThreadsThroughPageBuilders() {
        #expect(HTMLBuilder.documentPage(markdown: "x", theme: "editorial")
            .contains("\"theme\":\"editorial\""))
        #expect(HTMLBuilder.diffPage(segments: [], theme: "terminal")
            .contains("\"theme\":\"terminal\""))
        #expect(HTMLBuilder.patchPage(patch: "@@", theme: "editorial")
            .contains("\"theme\":\"editorial\""))
    }

    @Test func payloadCarriesThemeAndPreview() {
        let payload = HTMLBuilder.RenderPayload(mode: "document", markdown: "x",
                                                theme: "terminal", preview: true)
        let json = HTMLBuilder.jsonLiteral(payload)
        #expect(json.contains("\"theme\":\"terminal\""))
        #expect(json.contains("\"preview\":true"))
    }

    @Test func previewFlagOmittedByDefault() {
        let page = HTMLBuilder.documentPage(markdown: "x")
        #expect(!page.contains("\"preview\""))
        let preview = HTMLBuilder.diffPage(segments: [], preview: true)
        #expect(preview.contains("\"preview\":true"))
    }

    @Test func themeSelectionFallsBackToEditorial() {
        // Editorial is the app's signature default; GitHub remains selectable.
        #expect(Theme.current(from: nil) == .editorial)
        #expect(Theme.current(from: "nonsense") == .editorial)
        #expect(Theme.current(from: "editorial") == .editorial)
        #expect(Theme.current(from: "terminal") == .terminal)
    }

    @Test func blamePageKeepsMarkdownAndEmbedsRuns() {
        // The whole document renders normally in blame mode (footnotes and
        // reference links must keep working); the runs ride alongside.
        let blame = [BlameRunPayload(lineStart: 1, lineEnd: 3,
                                     sha: String(repeating: "a", count: 40),
                                     shortSHA: "aaaaaaa", author: "Ada")]
        let page = HTMLBuilder.documentPage(markdown: "# Hi", blame: blame)
        #expect(page.contains("\"blame\":"))
        #expect(page.contains("\"markdown\":\"# Hi\""))
        #expect(page.contains("\"lineStart\":1"))
        #expect(page.contains("\"shortSHA\":\"aaaaaaa\""))
    }

    @Test func referencesBundledAssets() {
        let page = HTMLBuilder.documentPage(markdown: "x")
        for asset in ["vendor/marked.min.js", "vendor/mermaid.min.js", "vendor/highlight.min.js",
                      "vendor/github-markdown.css", "app.js", "app.css"] {
            #expect(page.contains(asset), "missing \(asset)")
        }
        #expect(HTMLBuilder.resourcesBaseURL != nil, "bundled resources should resolve")
    }
}
