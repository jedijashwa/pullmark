import AppKit
import SwiftUI

/// Workaround for a SwiftUI crash on macOS 26: collapsing a sidebar row
/// whose expanded descendants were never scrolled into view — after rows
/// were INSERTED under one of them — asserts inside SwiftUI
/// (`ViewListTree.visitItem`, reached from `OutlineListCoordinator
/// .outlineView(_:child:ofItem:)`). NSOutlineView creates row entries
/// lazily and only loads the ones it displays; SwiftUI's diff inserts the
/// new rows into that half-loaded subtree; the collapse then walks every
/// expanded descendant (`_recursiveCollapseItemEntry`), loading the
/// untouched entries at last — and asks SwiftUI for children of a subtree
/// its NEW view list (parent already collapsed) can no longer resolve.
///
/// Reproduced deterministically: Expand All on a deep folder, add ONE
/// Markdown file to an offscreen expanded directory (the watcher rescans
/// and inserts a row), collapse the folder. Removals never triggered it;
/// any insertion — file, directory, or a split single-child chain — did.
/// A restored session is the everyday shape: folders come back expanded
/// without ever being displayed, the repository grows for days, and the
/// first collapse of the root crashes the app.
///
/// `item(atRow:)` forces every entry to load while the tree is still
/// consistent, so the collapse finds nothing left to resolve. Measured at
/// 0.2 ms for 1,300 rows; already-loaded entries cost nothing. Every
/// outline in every window is walked — only the sidebar is big, and the
/// caller has no handle on its own outline.
enum OutlineRowPreload {
    @MainActor
    static func loadAllRowEntries() {
        for window in NSApp.windows {
            guard let content = window.contentView else { continue }
            for outline in outlines(in: content) {
                for row in 0..<outline.numberOfRows {
                    _ = outline.item(atRow: row)
                }
            }
        }
    }

    private static func outlines(in view: NSView) -> [NSOutlineView] {
        if let outline = view as? NSOutlineView { return [outline] }
        return view.subviews.flatMap(outlines)
    }
}

extension Binding where Value == Bool {
    /// The expansion binding of a sidebar group or section, with the
    /// row-entry preload in front of every collapse (see OutlineRowPreload).
    /// Expansion needs nothing: only a collapse walks descendants.
    func preloadingOutlineRowsBeforeCollapse() -> Binding<Bool> {
        Binding(
            get: { wrappedValue },
            set: { expanded in
                if !expanded { OutlineRowPreload.loadAllRowEntries() }
                wrappedValue = expanded
            })
    }
}
