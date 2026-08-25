import Foundation

/// Row-scoped bulk closes for the Open Files section (spec:
/// sidebar-section-affordances §8): the tab bar's Close Others /
/// Close to the Right family translated to a vertical list. New files
/// append at the BOTTOM, so Above is where stale documents accumulate
/// and Below holds only the most recent opens — both directions ship.
/// The preview slot always renders last, below every pinned row.
///
/// Pure planning, separated from AppState so the semantics are unit-
/// testable: AppState mutation in tests would read and write the real
/// defaults domain.
enum WorkingSetClose {
    /// The row the context menu was invoked on.
    enum Target: Equatable {
        case pinned(index: Int)
        case preview
    }

    enum Scope {
        case others
        case above
        case below
    }

    struct Plan: Equatable {
        /// Indices into the pinned-files array, ascending.
        var pinnedIndicesToClose: [Int] = []
        var dismissesPreview = false
        /// Drives the menu items' disabled state.
        var isNoOp: Bool { pinnedIndicesToClose.isEmpty && !dismissesPreview }
    }

    static func plan(_ scope: Scope, target: Target,
                     pinnedCount: Int, hasPreview: Bool) -> Plan {
        switch (target, scope) {
        case (.pinned(let index), .others):
            return Plan(pinnedIndicesToClose: Array(0..<pinnedCount).filter { $0 != index },
                        dismissesPreview: hasPreview)
        case (.pinned(let index), .above):
            return Plan(pinnedIndicesToClose: Array(0..<min(index, pinnedCount)))
        case (.pinned(let index), .below):
            guard index + 1 <= pinnedCount else { return Plan(dismissesPreview: hasPreview) }
            return Plan(pinnedIndicesToClose: Array((index + 1)..<pinnedCount),
                        dismissesPreview: hasPreview)
        case (.preview, .others), (.preview, .above):
            // Every pinned row sits above the preview slot; the preview
            // itself — the row invoked on — stays.
            return Plan(pinnedIndicesToClose: Array(0..<pinnedCount))
        case (.preview, .below):
            return Plan()
        }
    }
}
