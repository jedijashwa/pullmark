import Foundation
import Testing
@testable import PullMark

@Suite struct ToolbarArrangementTests {
    private let separator = "com.apple.SwiftUI.splitViewSeparator-0"
    private let toggle = "com.apple.SwiftUI.navigationSplitView.toggleSidebar"
    private let flex = "NSToolbarFlexibleSpaceItem"

    @Test func cleanArrangementIsUntouched() {
        let clean = [flex, toggle, separator, "local-share", "local-edit", "open-pr"]
        #expect(ToolbarArrangement.repaired(clean) == clean)
    }

    @Test func itemBeforeSeparatorMovesJustAfterIt() {
        // The exact corruption from the dist trial: open-file dropped into
        // the sidebar section.
        let broken = ["open-file", flex, toggle, separator,
                      "local-share", "local-edit", "open-pr", "appearance"]
        #expect(ToolbarArrangement.repaired(broken)
            == [flex, toggle, separator, "open-file",
                "local-share", "local-edit", "open-pr", "appearance"])
    }

    @Test func itemBetweenToggleAndSeparatorMoves() {
        let broken = [flex, "open-file", toggle, separator, "local-share"]
        #expect(ToolbarArrangement.repaired(broken)
            == [flex, toggle, separator, "open-file", "local-share"])
    }

    @Test func multipleMisplacedItemsKeepRelativeOrder() {
        let broken = ["open-file", flex, "local-blame", toggle, separator, "local-share"]
        #expect(ToolbarArrangement.repaired(broken)
            == [flex, toggle, separator, "open-file", "local-blame", "local-share"])
    }

    @Test func systemItemsInSidebarSectionStayPut() {
        let clean = [flex, toggle, flex, separator, "local-share"]
        #expect(ToolbarArrangement.repaired(clean) == clean)
    }

    @Test func noSeparatorMeansNoChange() {
        let arrangement = ["open-file", "local-share", "local-edit"]
        #expect(ToolbarArrangement.repaired(arrangement) == arrangement)
    }

    @Test func emptyArrangement() {
        #expect(ToolbarArrangement.repaired([]) == [])
    }

    @Test func savedConfigurationsAreScrubbedInPlace() throws {
        let suiteName = "app.pullmark.tests.toolbar-arrangement"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let broken: [String: Any] = [
            "TB Display Mode": 2,
            ToolbarArrangement.itemsKey: ["open-file", flex, toggle, separator, "local-share"],
        ]
        let clean: [String: Any] = [
            ToolbarArrangement.itemsKey: [flex, toggle, separator, "local-share"],
        ]
        defaults.set(broken, forKey: ToolbarArrangement.configKeyPrefix + "main-local")
        defaults.set(clean, forKey: ToolbarArrangement.configKeyPrefix + "main-remote")
        defaults.set("unrelated", forKey: "pm.somethingElse")

        ToolbarArrangement.repairSavedConfigurations(in: defaults)

        let repaired = try #require(defaults.dictionary(
            forKey: ToolbarArrangement.configKeyPrefix + "main-local"))
        #expect(repaired[ToolbarArrangement.itemsKey] as? [String]
            == [flex, toggle, separator, "open-file", "local-share"])
        // Untouched keys survive alongside the repaired arrangement.
        #expect(repaired["TB Display Mode"] as? Int == 2)
        let untouched = try #require(defaults.dictionary(
            forKey: ToolbarArrangement.configKeyPrefix + "main-remote"))
        #expect(untouched[ToolbarArrangement.itemsKey] as? [String]
            == [flex, toggle, separator, "local-share"])
        #expect(defaults.string(forKey: "pm.somethingElse") == "unrelated")
    }
}
