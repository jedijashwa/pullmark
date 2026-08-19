import Foundation
import Testing
@testable import PullMark

@Suite struct AppLinksTests {
    @Test func supportedTargets() {
        #expect(AppLinks.isSupported(URL(string: "pullmark://settings/experimental")!))
        #expect(AppLinks.isSupported(URL(string: "pullmark://settings")!))
        #expect(!AppLinks.isSupported(URL(string: "pullmark://settings/margin-notes")!))
        #expect(!AppLinks.isSupported(URL(string: "pullmark://frobnicate")!))
        #expect(!AppLinks.isSupported(URL(string: "https://pullmark.app")!))
    }

    @Test func sanitizeKeepsSupportedLinks() {
        let md = "Turn it on in [Settings → Experimental](pullmark://settings/experimental)."
        #expect(AppLinks.sanitize(md) == md)
    }

    @Test func sanitizeDemotesUnknownTargetsToPlainText() {
        let md = "Now in [General](pullmark://settings/general/margin-notes), enjoy."
        #expect(AppLinks.sanitize(md) == "Now in General, enjoy.")
    }

    @Test func sanitizeLeavesWebLinksAlone() {
        let md = "See [the docs](https://pullmark.app/docs/) and [tab](pullmark://settings/keyboard)."
        #expect(AppLinks.sanitize(md) == md)
    }

    @Test func settingsTargetParsesTabAndFeature() {
        let plain = AppLinks.settingsTarget(URL(string: "pullmark://settings/experimental")!)
        #expect(plain?.tab == "experimental")
        #expect(plain?.anchor == nil)
        let deep = AppLinks.settingsTarget(
            URL(string: "pullmark://settings/experimental/margin-notes")!)
        #expect(deep?.tab == "experimental")
        #expect(deep?.anchor == "margin-notes")
        #expect(AppLinks.settingsTarget(URL(string: "pullmark://settings/nope")!) == nil)
        let row = AppLinks.settingsTarget(
            URL(string: "pullmark://settings/general/show-hidden-files")!)
        #expect(row?.tab == "general")
        #expect(row?.anchor == "show-hidden-files")
        #expect(AppLinks.settingsTarget(URL(string: "https://pullmark.app")!) == nil)
    }

    @Test func graduatedDiscussionLinkRemapsToGeneral() {
        // The 0.31.0 docs and release notes published the experimental
        // form — links are promises, so it lands on the toggle's new
        // home instead of a tab that no longer has the row.
        let old = AppLinks.settingsTarget(
            URL(string: "pullmark://settings/experimental/pr-discussion")!)
        #expect(old?.tab == "general")
        #expect(old?.anchor == "pr-discussion")
        let new = AppLinks.settingsTarget(
            URL(string: "pullmark://settings/general/pr-discussion")!)
        #expect(new?.tab == "general")
        #expect(new?.anchor == "pr-discussion")
    }

    @Test func marginNotesGraduatedOutOfAlpha() {
        // Graduated to beta in 0.35.0: no alpha-contract detour, and the
        // published deep link still lands on its Experimental-tab anchor
        // (the section stays on that tab, so no remap either).
        #expect(!AppLinks.alphaFeatures.contains("margin-notes"))
        let row = AppLinks.settingsTarget(
            URL(string: "pullmark://settings/experimental/margin-notes")!)
        #expect(row?.tab == "experimental")
        #expect(row?.anchor == "margin-notes")
    }

    @Test func compareTargetParsesFileAndRef() throws {
        let full = try #require(AppLinks.compareTarget(
            URL(string: "pullmark://compare?file=/Users/me/docs/plan.md&ref=main")!))
        #expect(full.file == URL(fileURLWithPath: "/Users/me/docs/plan.md"))
        #expect(full.request == .workingAgainstRef("main"))
        // ref is optional (and may arrive empty) — HEAD either way.
        let bare = try #require(AppLinks.compareTarget(
            URL(string: "pullmark://compare?file=/a/b.md")!))
        #expect(bare.request == .workingAgainstRef("HEAD"))
        let empty = try #require(AppLinks.compareTarget(
            URL(string: "pullmark://compare?file=/a/b.md&ref=")!))
        #expect(empty.request == .workingAgainstRef("HEAD"))
    }

    @Test func compareTargetParsesTwoRefRanges() throws {
        let range = try #require(AppLinks.compareTarget(
            URL(string: "pullmark://compare?file=/a/b.md&ref=v1.0..main")!))
        #expect(range.request == .refAgainstRef(old: "v1.0", new: "main"))
        // Three-dot ranges and empty sides are rejected, not guessed.
        #expect(AppLinks.compareTarget(
            URL(string: "pullmark://compare?file=/a/b.md&ref=v1.0...main")!) == nil)
        #expect(AppLinks.compareTarget(
            URL(string: "pullmark://compare?file=/a/b.md&ref=..main")!) == nil)
        #expect(AppLinks.compareTarget(
            URL(string: "pullmark://compare?file=/a/b.md&ref=main..")!) == nil)
        #expect(AppLinks.compareTarget(
            URL(string: "pullmark://compare?file=/a/b.md&ref=a..b..c")!) == nil)
    }

    @Test func compareTargetParsesBaselineFiles() throws {
        let with = try #require(AppLinks.compareTarget(
            URL(string: "pullmark://compare?file=/a/new.md&with=/b/old.md")!))
        #expect(with.request == .againstFile(URL(fileURLWithPath: "/b/old.md")))
        // A relative baseline is rejected (the CLI always absolutizes).
        #expect(AppLinks.compareTarget(
            URL(string: "pullmark://compare?file=/a/new.md&with=old.md")!) == nil)
    }

    @Test func compareTargetDecodesPercentEncodedPaths() throws {
        // The CLI byte-encodes UTF-8 and spaces; URLComponents decodes.
        let spaced = try #require(AppLinks.compareTarget(
            URL(string: "pullmark://compare?file=/Users/me/My%20Notes/r%C3%A9sum%C3%A9.md&ref=feature%2Fx")!))
        #expect(spaced.file == URL(fileURLWithPath: "/Users/me/My Notes/résumé.md"))
        #expect(spaced.request == .workingAgainstRef("feature/x"))
    }

    @Test func compareTargetRejectsMalformedLinks() {
        // No file, relative file, wrong host, wrong scheme.
        #expect(AppLinks.compareTarget(URL(string: "pullmark://compare?ref=main")!) == nil)
        #expect(AppLinks.compareTarget(URL(string: "pullmark://compare?file=docs/plan.md")!) == nil)
        #expect(AppLinks.compareTarget(URL(string: "pullmark://settings?file=/a.md")!) == nil)
        #expect(AppLinks.compareTarget(URL(string: "https://compare?file=/a.md")!) == nil)
    }

    @Test func compareIsARegisteredTarget() {
        // Release notes may link the feature; sanitize must keep it.
        #expect(AppLinks.isSupported(URL(string: "pullmark://compare")!))
    }

    @Test func sanitizeHandlesMultipleLinksAndAdjacentText() {
        let md = "[a](pullmark://nope) mid [b](pullmark://settings) end [c](pullmark://also/nope)"
        #expect(AppLinks.sanitize(md) == "a mid [b](pullmark://settings) end c")
    }
}
