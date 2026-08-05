import Testing
@testable import PullMark

/// GitHub slug parity — the awkward-heading fixture from the remote-docs
/// design: anchors written for GitHub must land in PullMark and vice
/// versa. Expected values verified against github.com rendering.
@Suite struct HeadingSlugTests {
    private func slug(_ s: String) -> String { OpenQuickly.headingSlug(s) }

    @Test func plain() {
        #expect(slug("The Process") == "the-process")
    }

    @Test func apostrophes() {
        #expect(slug("What's in a name") == "whats-in-a-name")
        #expect(slug("Don't do this") == "dont-do-this")
    }

    @Test func emDashesAndColons() {
        #expect(slug("Setup — the hard part") == "setup--the-hard-part")
        #expect(slug("Step one: install") == "step-one-install")
    }

    @Test func numberedHeadings() {
        #expect(slug("2.1 Configuration") == "21-configuration")
    }

    @Test func underscoresSurvive() {
        // github-slugger keeps _ — code-identifier headings depend on it.
        #expect(slug("The load_remote function") == "the-load_remote-function")
        #expect(slug("snake_case_everywhere") == "snake_case_everywhere")
    }

    @Test func backticksAndSlashes() {
        #expect(slug("Using a/b testing") == "using-ab-testing")
    }

    @Test func unicodeLettersKept() {
        #expect(slug("Café menü") == "café-menü")
    }
}
