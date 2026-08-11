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
}
