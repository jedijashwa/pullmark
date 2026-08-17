import Foundation
import Testing
@testable import PullMark

@Suite struct FolderScanRulesTests {
    private let root = "/Users/dev/big-repo"

    private func relevant(_ paths: [String], showHidden: Bool = false) -> Bool {
        FolderScanRules.rescanRelevant(changedPaths: paths,
                                       resolvedRootPath: root,
                                       showHidden: showHidden)
    }

    @Test func gitChurnNeverRescans() {
        // The bug: git's own writes retriggered full monorepo walks.
        #expect(!relevant(["/Users/dev/big-repo/.git",
                           "/Users/dev/big-repo/.git/objects/ab",
                           "/Users/dev/big-repo/.git/index/"]))
    }

    @Test func skippedStoresNeverRescan() {
        #expect(!relevant(["/Users/dev/big-repo/node_modules/left-pad",
                           "/Users/dev/big-repo/docs/vendor/lib",
                           "/Users/dev/big-repo/.build/debug"]))
    }

    @Test func realChangesRescan() {
        // One visible path in the batch is enough.
        #expect(relevant(["/Users/dev/big-repo/.git/objects/ab",
                          "/Users/dev/big-repo/docs"]))
        #expect(relevant(["/Users/dev/big-repo/docs/guides"]))
        #expect(relevant(["/Users/dev/big-repo"]))          // the root itself
        #expect(relevant(["/Users/dev/big-repo/docs/"]))    // trailing slash
    }

    @Test func hiddenDirectoriesFollowTheSetting() {
        // Scan skips hidden subtrees while the setting is off — so must
        // the watcher; flipping it on makes the same events matter.
        #expect(!relevant(["/Users/dev/big-repo/.github/workflows"]))
        #expect(relevant(["/Users/dev/big-repo/.github/workflows"], showHidden: true))
        // .git and friends stay skipped even with hidden files shown.
        #expect(!relevant(["/Users/dev/big-repo/.git/objects"], showHidden: true))
    }

    @Test func unsureMeansRescan() {
        // Outside the root, or an empty batch: never guess "skip".
        #expect(relevant(["/somewhere/else/entirely"]))
        #expect(relevant([]))
    }
}
