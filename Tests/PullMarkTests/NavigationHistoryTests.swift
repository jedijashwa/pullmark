import Testing
@testable import PullMark

struct NavigationHistoryTests {
    private func visit(_ history: inout NavigationHistory<Int>, _ n: Int) {
        history.visit(n, title: "doc \(n)", systemImage: "doc.text")
    }

    @Test func startsEmpty() {
        let history = NavigationHistory<Int>()
        #expect(history.current == nil)
        #expect(!history.canGoBack)
        #expect(!history.canGoForward)
        #expect(history.backEntries.isEmpty)
        #expect(history.forwardEntries.isEmpty)
    }

    @Test func travelOnEmptyGoesNowhere() {
        var history = NavigationHistory<Int>()
        #expect(history.goBack() == nil)
        #expect(history.goForward() == nil)
        #expect(history.current == nil)
    }

    @Test func visitsBuildTheTrail() {
        var history = NavigationHistory<Int>()
        visit(&history, 1)
        #expect(history.current?.destination == 1)
        #expect(!history.canGoBack)
        visit(&history, 2)
        visit(&history, 3)
        #expect(history.current?.destination == 3)
        #expect(history.canGoBack)
        #expect(!history.canGoForward)
        #expect(history.backEntries.map(\.destination) == [2, 1])
    }

    @Test func backAndForwardMoveTheCursor() {
        var history = NavigationHistory<Int>()
        visit(&history, 1)
        visit(&history, 2)
        visit(&history, 3)
        #expect(history.goBack()?.destination == 2)
        #expect(history.goBack()?.destination == 1)
        #expect(history.goBack() == nil)
        #expect(history.current?.destination == 1)
        #expect(history.canGoForward)
        #expect(history.goForward()?.destination == 2)
        #expect(history.forwardEntries.map(\.destination) == [3])
    }

    @Test func newVisitAfterBackTruncatesForward() {
        var history = NavigationHistory<Int>()
        visit(&history, 1)
        visit(&history, 2)
        visit(&history, 3)
        _ = history.goBack()
        _ = history.goBack()
        visit(&history, 9)
        #expect(history.current?.destination == 9)
        #expect(!history.canGoForward)
        #expect(history.backEntries.map(\.destination) == [1])
        #expect(history.entries.map(\.destination) == [1, 9])
    }

    @Test func revisitingCurrentRefreshesSnapshotWithoutNewEntry() {
        var history = NavigationHistory<Int>()
        visit(&history, 1)
        visit(&history, 2)
        _ = history.goBack()
        history.visit(1, title: "renamed", systemImage: "folder")
        #expect(history.entries.count == 2)
        #expect(history.current?.title == "renamed")
        // The forward trail survives a snapshot refresh — nothing was
        // navigated.
        #expect(history.canGoForward)
    }

    @Test func menuJumpTravelsSeveralSteps() {
        var history = NavigationHistory<Int>()
        for n in 1...5 { visit(&history, n) }
        #expect(history.travel(-3)?.destination == 2)
        #expect(history.backEntries.map(\.destination) == [1])
        #expect(history.forwardEntries.map(\.destination) == [3, 4, 5])
        #expect(history.travel(2)?.destination == 4)
        #expect(history.travel(5) == nil)
        #expect(history.current?.destination == 4)
        #expect(history.travel(0) == nil)
    }

    @Test func capDropsTheOldestAndKeepsTheCursorRight() {
        var history = NavigationHistory<Int>(cap: 3)
        for n in 1...5 { visit(&history, n) }
        #expect(history.entries.map(\.destination) == [3, 4, 5])
        #expect(history.current?.destination == 5)
        #expect(history.goBack()?.destination == 4)
        #expect(history.goBack()?.destination == 3)
        #expect(history.goBack() == nil)
    }

    @Test func snapshotsCarryTitleAndSymbol() {
        var history = NavigationHistory<Int>()
        history.visit(7, title: "README.md", systemImage: "doc.text")
        #expect(history.current == NavigationHistory<Int>.Entry(
            destination: 7, title: "README.md", systemImage: "doc.text"))
    }
}
