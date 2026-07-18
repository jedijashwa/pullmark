import Testing
@testable import PullMark

@Suite struct HTMLBuilderTests {
    @Test func scriptCloseTagCannotEscapePayload() {
        let page = HTMLBuilder.documentPage(markdown: "hello </script><script>alert(1)</script>")
        #expect(!page.contains("</script><script>alert"))
        #expect(page.contains("<\\/script>"))
    }

    @Test func documentPayloadIsEmbedded() {
        let page = HTMLBuilder.documentPage(markdown: "# Hi", title: "T")
        #expect(page.contains("window.__PAYLOAD__"))
        #expect(page.contains("\"mode\":\"document\""))
        #expect(page.contains("# Hi"))
        #expect(page.contains("<title>T</title>"))
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

    @Test func themeSelectionFallsBackToGitHub() {
        #expect(Theme.current(from: nil) == .github)
        #expect(Theme.current(from: "nonsense") == .github)
        #expect(Theme.current(from: "editorial") == .editorial)
        #expect(Theme.current(from: "terminal") == .terminal)
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
