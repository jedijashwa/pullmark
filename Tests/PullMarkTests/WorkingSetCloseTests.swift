import Testing
@testable import PullMark

/// Row-scoped bulk closes in Open Files (spec:
/// sidebar-section-affordances §8). Files append at the bottom and the
/// preview slot renders last — Above never touches the preview, Others
/// and Below dismiss it.
struct WorkingSetCloseTests {
    @Test func othersKeepsOnlyTheClickedRow() {
        let plan = WorkingSetClose.plan(.others, target: .pinned(index: 2),
                                        pinnedCount: 5, hasPreview: false)
        #expect(plan.pinnedIndicesToClose == [0, 1, 3, 4])
        #expect(!plan.dismissesPreview)
        #expect(!plan.isNoOp)
    }

    @Test func othersDismissesThePreviewSlot() {
        let plan = WorkingSetClose.plan(.others, target: .pinned(index: 0),
                                        pinnedCount: 1, hasPreview: true)
        #expect(plan.pinnedIndicesToClose.isEmpty)
        #expect(plan.dismissesPreview)
        #expect(!plan.isNoOp)
    }

    @Test func aboveClosesEarlierRowsOnly() {
        let plan = WorkingSetClose.plan(.above, target: .pinned(index: 3),
                                        pinnedCount: 5, hasPreview: true)
        #expect(plan.pinnedIndicesToClose == [0, 1, 2])
        // The preview renders below every pinned row — Above spares it.
        #expect(!plan.dismissesPreview)
    }

    @Test func aboveOnTopRowIsANoOp() {
        let plan = WorkingSetClose.plan(.above, target: .pinned(index: 0),
                                        pinnedCount: 5, hasPreview: true)
        #expect(plan.isNoOp)
    }

    @Test func belowClosesLaterRowsAndThePreview() {
        let plan = WorkingSetClose.plan(.below, target: .pinned(index: 1),
                                        pinnedCount: 4, hasPreview: true)
        #expect(plan.pinnedIndicesToClose == [2, 3])
        #expect(plan.dismissesPreview)
    }

    @Test func belowOnBottomRowStillDismissesThePreview() {
        let plan = WorkingSetClose.plan(.below, target: .pinned(index: 3),
                                        pinnedCount: 4, hasPreview: true)
        #expect(plan.pinnedIndicesToClose.isEmpty)
        #expect(plan.dismissesPreview)
    }

    @Test func belowOnBottomRowWithoutPreviewIsANoOp() {
        let plan = WorkingSetClose.plan(.below, target: .pinned(index: 3),
                                        pinnedCount: 4, hasPreview: false)
        #expect(plan.isNoOp)
    }

    @Test func othersOnLoneRowWithoutPreviewIsANoOp() {
        let plan = WorkingSetClose.plan(.others, target: .pinned(index: 0),
                                        pinnedCount: 1, hasPreview: false)
        #expect(plan.isNoOp)
    }

    @Test func previewOthersClosesEveryPinnedRowAndKeepsThePreview() {
        let plan = WorkingSetClose.plan(.others, target: .preview,
                                        pinnedCount: 3, hasPreview: true)
        #expect(plan.pinnedIndicesToClose == [0, 1, 2])
        #expect(!plan.dismissesPreview)
    }

    @Test func previewAboveMatchesPreviewOthers() {
        let others = WorkingSetClose.plan(.others, target: .preview,
                                          pinnedCount: 3, hasPreview: true)
        let above = WorkingSetClose.plan(.above, target: .preview,
                                         pinnedCount: 3, hasPreview: true)
        #expect(others == above)
    }

    @Test func previewBelowIsAlwaysANoOp() {
        let plan = WorkingSetClose.plan(.below, target: .preview,
                                        pinnedCount: 3, hasPreview: true)
        #expect(plan.isNoOp)
    }
}
