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

    @Test func marginNotesIsAlphaLeveled() {
        #expect(AppLinks.alphaFeatures.contains("margin-notes"))
    }

    @Test func sanitizeHandlesMultipleLinksAndAdjacentText() {
        let md = "[a](pullmark://nope) mid [b](pullmark://settings) end [c](pullmark://also/nope)"
        #expect(AppLinks.sanitize(md) == "a mid [b](pullmark://settings) end c")
    }
}
