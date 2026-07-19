import Foundation
import Testing
@testable import PullMark

@Suite struct DefaultMarkdownAppTests {
    private let pullmark = URL(fileURLWithPath: "/Applications/PullMark.app")
    private let other = URL(fileURLWithPath: "/System/Applications/TextEdit.app")

    @Test func neverOffersWhenNotClaimed() {
        #expect(!DefaultMarkdownApp.shouldOffer(claimed: false,
                                                currentHandlerURL: other,
                                                bundleURL: pullmark,
                                                isAppBundle: true))
        #expect(!DefaultMarkdownApp.shouldOffer(claimed: false,
                                                currentHandlerURL: nil,
                                                bundleURL: pullmark,
                                                isAppBundle: true))
    }

    @Test func neverOffersOutsideAppBundle() {
        // `swift run` — a dev binary must not grab the binding.
        let devBinary = URL(fileURLWithPath: "/Users/dev/pullmark/.build/debug/PullMark")
        #expect(!DefaultMarkdownApp.shouldOffer(claimed: true,
                                                currentHandlerURL: other,
                                                bundleURL: devBinary,
                                                isAppBundle: false))
    }

    @Test func offersWhenClaimedAndHandlerMovedElsewhere() {
        #expect(DefaultMarkdownApp.shouldOffer(claimed: true,
                                               currentHandlerURL: other,
                                               bundleURL: pullmark,
                                               isAppBundle: true))
    }

    @Test func offersWhenClaimedAndNoHandlerAtAll() {
        #expect(DefaultMarkdownApp.shouldOffer(claimed: true,
                                               currentHandlerURL: nil,
                                               bundleURL: pullmark,
                                               isAppBundle: true))
    }

    @Test func quietWhileStillTheDefault() {
        #expect(!DefaultMarkdownApp.shouldOffer(claimed: true,
                                                currentHandlerURL: pullmark,
                                                bundleURL: pullmark,
                                                isAppBundle: true))
    }

    @Test func pathComparisonIgnoresTrailingSlashAndDotSegments() {
        let slashed = URL(fileURLWithPath: "/Applications/PullMark.app/")
        let dotted = URL(fileURLWithPath: "/Applications/./PullMark.app")
        #expect(!DefaultMarkdownApp.shouldOffer(claimed: true,
                                                currentHandlerURL: slashed,
                                                bundleURL: pullmark,
                                                isAppBundle: true))
        #expect(!DefaultMarkdownApp.shouldOffer(claimed: true,
                                                currentHandlerURL: dotted,
                                                bundleURL: pullmark,
                                                isAppBundle: true))
    }

    @Test func distCopyStealingTheBindingCountsAsLoss() {
        // A dev build at dist/ grabbing the handler must still raise the
        // banner for the installed copy.
        let dist = URL(fileURLWithPath: "/Users/dev/pullmark/dist/PullMark.app")
        #expect(DefaultMarkdownApp.shouldOffer(claimed: true,
                                               currentHandlerURL: dist,
                                               bundleURL: pullmark,
                                               isAppBundle: true))
    }

    @Test func markdownContentTypeExists() {
        #expect(DefaultMarkdownApp.contentType != nil)
        #expect(DefaultMarkdownApp.contentType?.identifier == "net.daringfireball.markdown")
    }
}
