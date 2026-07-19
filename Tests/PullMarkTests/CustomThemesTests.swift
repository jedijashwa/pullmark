import Testing
@testable import PullMark

@Suite struct CustomThemesTests {
    @Test func themeNamesKeepOnlyVisibleCSSFiles() {
        let names = CustomThemes.themeNames(fromFiles: [
            "Solar.CSS", "night.css", "readme.txt", ".hidden.css", "notes.md", ".css"
        ])
        #expect(names == ["night", "Solar"])
    }

    @Test func themeNamesAreSortedCaseInsensitively() {
        let names = CustomThemes.themeNames(fromFiles: ["zebra.css", "Alpha.css", "mango.css"])
        #expect(names == ["Alpha", "mango", "zebra"])
    }

    @Test func builtinRawValuesResolveToBuiltins() {
        #expect(ThemeSelection.resolve("terminal", availableCustom: []) ==
                ThemeSelection(theme: .terminal, customName: nil))
        #expect(ThemeSelection.resolve("github", availableCustom: ["Night"]) ==
                ThemeSelection(theme: .github, customName: nil))
    }

    @Test func nilAndUnknownValuesFallBackToGitHub() {
        #expect(ThemeSelection.resolve(nil, availableCustom: []).theme == .github)
        #expect(ThemeSelection.resolve("solarized", availableCustom: []).theme == .github)
    }

    @Test func customSchemeResolvesWhenFileExists() {
        let selection = ThemeSelection.resolve("custom:Night", availableCustom: ["Night", "Paper"])
        #expect(selection == ThemeSelection(theme: .github, customName: "Night"))
        #expect(selection.storageValue == "custom:Night")
    }

    @Test func missingCustomThemeFallsBackToGitHub() {
        let selection = ThemeSelection.resolve("custom:Gone", availableCustom: ["Night"])
        #expect(selection == ThemeSelection(theme: .github, customName: nil))
        #expect(selection.storageValue == "github")
    }

    @Test func customNameMatchingIsExact() {
        // "night" on disk does not satisfy a stored "custom:Night".
        let selection = ThemeSelection.resolve("custom:Night", availableCustom: ["night"])
        #expect(selection.customName == nil)
    }

    @Test func customCSSIsEmbeddedInline() {
        let page = HTMLBuilder.documentPage(markdown: "# Hi", theme: "github",
                                            customCSS: "body { background: teal; }")
        #expect(page.contains("<style id=\"pm-custom-theme\">body { background: teal; }</style>"))
    }

    @Test func customCSSCannotCloseTheStyleTag() {
        let page = HTMLBuilder.documentPage(
            markdown: "x", theme: "github",
            customCSS: "body{}</style><script>alert(1)</script>")
        #expect(!page.contains("</style><script>"))
        #expect(page.contains("<\\/style><script>alert(1)<\\/script>"))
    }

    @Test func absentCustomCSSAddsNoStyleTag() {
        let page = HTMLBuilder.documentPage(markdown: "x", theme: "editorial")
        #expect(!page.contains("pm-custom-theme"))
    }
}
