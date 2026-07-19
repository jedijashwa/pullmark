import Testing
import JavaScriptCore
@testable import PullMark

/// Exercises the shared marked extension pack (pm-extensions.js) through the
/// same JavaScriptCore path the Quick Look renderer uses: real marked + real
/// KaTeX, no DOM. This is where the math tokenizer's conservative edges are
/// pinned down (currency, code spans, fences).
@Suite struct RenderExtensionsTests {
    static let context: JSContext = {
        let context = JSContext()!
        let base = HTMLBuilder.resourcesBaseURL!
        for path in ["vendor/marked.min.js", "vendor/katex/katex.min.js", "pm-extensions.js"] {
            let source = try! String(contentsOf: base.appendingPathComponent(path), encoding: .utf8)
            context.evaluateScript(source)
        }
        context.evaluateScript("""
        marked.use({ extensions: pmExtensions.extensions() });
        marked.use({ gfm: true });
        """)
        return context
    }()

    private func render(_ markdown: String) -> String {
        let result = Self.context.evaluateScript(
            "marked.parse(\(HTMLBuilder.jsStringLiteral(markdown)))")
        #expect(Self.context.exception == nil)
        return result?.toString() ?? ""
    }

    // MARK: Math

    @Test func inlineMathRendersThroughKaTeX() {
        let html = render("Euler: $e^{i\\pi} + 1 = 0$ holds.")
        #expect(html.contains("class=\"katex\""))
        #expect(!html.contains("$e^"))
    }

    @Test func blockMathRendersDisplayStyle() {
        let html = render("Before.\n\n$$\n\\int_0^1 x\\,dx\n$$\n\nAfter.")
        #expect(html.contains("pm-math-block"))
        #expect(html.contains("katex-display"))
    }

    @Test func doubleDollarInsideParagraphIsDisplayMath() {
        let html = render("So $$x^2$$ inline.")
        #expect(html.contains("katex-display"))
    }

    @Test func currencyIsNotMath() {
        let html = render("It costs $5 today and $10 tomorrow.")
        #expect(!html.contains("katex"))
        #expect(html.contains("$5 today and $10 tomorrow."))
    }

    @Test func spaceAdjacentDollarsAreNotMath() {
        // Opening $ followed by a space / closing $ preceded by one.
        let html = render("a $ x $ b and c $x $ d and e $ x$ f")
        #expect(!html.contains("katex"))
    }

    @Test func closingDollarBeforeDigitIsNotMath() {
        // "$x$5" would render "x" as math and orphan the 5 — Pandoc's rule
        // says a closing $ may not sit directly before a digit.
        let html = render("weird $x$5 price")
        #expect(!html.contains("katex"))
    }

    @Test func codeSpanKeepsItsDollars() {
        let html = render("Use `$x$` in shell.")
        #expect(!html.contains("katex"))
        #expect(html.contains("<code>$x$</code>"))
    }

    @Test func currencyBeforeCodeSpanCannotPairIntoIt() {
        // The closing $ candidate lives inside a later code span; pairing
        // "$10 … `$" would swallow the span's opening backtick.
        let html = render("Pay $10 for `$PATH` tricks.")
        #expect(!html.contains("katex"))
        #expect(html.contains("<code>$PATH</code>"))
    }

    @Test func fencedCodeKeepsDollarLines() {
        let html = render("```\n$$ not math $$\n```")
        #expect(!html.contains("katex"))
        #expect(html.contains("$$ not math $$"))
    }

    @Test func multilineInlineDollarsDoNotPair() {
        let html = render("cost $5 one line\nand $6 next line")
        #expect(!html.contains("katex"))
    }

    @Test func invalidTeXFallsBackWithoutThrowing() {
        // throwOnError:false renders the error in-place; parse must not die.
        let html = render("bad $\\frobnicate{$ math")
        #expect(!html.isEmpty)
    }

    // MARK: Highlight / sub / sup

    @Test func highlightRendersMark() {
        let html = render("some ==highlighted **text**== here")
        #expect(html.contains("<mark>highlighted <strong>text</strong></mark>"))
    }

    @Test func equalityComparisonsAreNotHighlights() {
        let html = render("a == b == c")
        #expect(!html.contains("<mark>"))
    }

    @Test func subscriptRenders() {
        let html = render("Water is H~2~O.")
        #expect(html.contains("H<sub>2</sub>O"))
    }

    @Test func strikethroughSurvivesSubscriptExtension() {
        let html = render("~~gone~~ but ~sub~ too")
        #expect(html.contains("<del>gone</del>"))
        #expect(html.contains("<sub>sub</sub>"))
    }

    @Test func tildeWithSpacesIsNotSubscript() {
        let html = render("approx ~5 or so, maybe ~ 6 ~ even")
        #expect(!html.contains("<sub>"))
    }

    @Test func superscriptRenders() {
        let html = render("E = mc^2^ indeed")
        #expect(html.contains("mc<sup>2</sup>"))
    }

    @Test func caretWithSpacesIsNotSuperscript() {
        let html = render("2 ^ 3 ^ 4")
        #expect(!html.contains("<sup>"))
    }

    // MARK: [toc]

    @Test func tocParagraphRendersPlaceholder() {
        let html = render("# One\n\n[toc]\n\n## Two")
        #expect(html.contains("<nav class=\"pm-toc\" data-pm-toc=\"1\""))
    }

    @Test func tocIsCaseInsensitive() {
        let html = render("[TOC]")
        #expect(html.contains("data-pm-toc"))
    }

    @Test func tocInsideProseStaysLiteral() {
        let html = render("see [toc] for details")
        #expect(!html.contains("data-pm-toc"))
        #expect(html.contains("[toc]"))
    }

    @Test func tocWithTrailingProseLineStaysLiteral() {
        // Only a paragraph that is exactly [toc] becomes a TOC.
        let html = render("[toc]\nmore prose")
        #expect(!html.contains("data-pm-toc"))
    }

    // MARK: Slugs

    @Test func slugifyMatchesGitHubStyle() {
        let slugify = Self.context.objectForKeyedSubscript("pmExtensions")?
            .objectForKeyedSubscript("slugify")
        #expect(slugify?.call(withArguments: ["GFM Kitchen Sink"])?.toString() == "gfm-kitchen-sink")
        #expect(slugify?.call(withArguments: ["Héllo, Wörld!"])?.toString() == "héllo-wörld")
    }
}
