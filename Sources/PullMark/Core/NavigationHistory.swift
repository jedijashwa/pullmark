import Foundation

/// A browser-style back/forward trail: one array plus a cursor (WebKit's
/// back-forward list shape), not two stacks. Generic over the destination
/// so Core stays free of app types and tests can run it over `Int`.
///
/// Entries are never removed except by the cap — dead destinations stay
/// in the trail and are re-judged at each landing (spec §4), so a file
/// restored to disk or a reopened session makes an old entry work again.
struct NavigationHistory<Destination: Equatable> {
    struct Entry: Equatable {
        let destination: Destination
        /// Display snapshot taken at visit time, so menus render without
        /// looking anything up (and keep naming entries whose resource
        /// has since disappeared).
        let title: String
        let systemImage: String
    }

    private(set) var entries: [Entry] = []
    /// -1 until the first visit; entries is non-empty iff this is ≥ 0.
    private(set) var currentIndex = -1
    let cap: Int

    init(cap: Int = 100) {
        self.cap = cap
    }

    var current: Entry? {
        entries.indices.contains(currentIndex) ? entries[currentIndex] : nil
    }

    var canGoBack: Bool { currentIndex > 0 }
    var canGoForward: Bool { currentIndex >= 0 && currentIndex < entries.count - 1 }

    /// The trail behind the cursor, nearest first — menu order.
    var backEntries: [Entry] {
        currentIndex > 0 ? entries[..<currentIndex].reversed() : []
    }

    /// The trail ahead of the cursor, nearest first — menu order.
    var forwardEntries: [Entry] {
        currentIndex >= 0 ? Array(entries[(currentIndex + 1)...]) : []
    }

    /// Organic navigation: truncate everything forward of the cursor,
    /// append, enforce the cap (oldest dropped). Re-visiting the current
    /// destination only refreshes its snapshot — no new entry.
    mutating func visit(_ destination: Destination, title: String, systemImage: String) {
        let entry = Entry(destination: destination, title: title, systemImage: systemImage)
        if let current, current.destination == destination {
            entries[currentIndex] = entry
            return
        }
        entries.removeSubrange((currentIndex + 1)...)
        entries.append(entry)
        currentIndex = entries.count - 1
        if entries.count > cap {
            let overflow = entries.count - cap
            entries.removeFirst(overflow)
            currentIndex -= overflow
        }
    }

    /// Move the cursor by `delta` (negative = back; menus jump several
    /// steps at once). Returns the new current entry, or nil — cursor
    /// unmoved — when the move runs off either end.
    mutating func travel(_ delta: Int) -> Entry? {
        let target = currentIndex + delta
        guard delta != 0, entries.indices.contains(target) else { return nil }
        currentIndex = target
        return entries[currentIndex]
    }

    mutating func goBack() -> Entry? { travel(-1) }
    mutating func goForward() -> Entry? { travel(1) }
}
