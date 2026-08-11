import Foundation

/// Repair for saved toolbar arrangements. The customize palette accepts a
/// drop in the toolbar's SIDEBAR section — left of the split-view tracking
/// separator, territory SwiftUI manages for the sidebar toggle. SwiftUI
/// doesn't police the drop: the separator and toggle rearrange around the
/// foreign item, the titlebar layout wedges, and the broken order is
/// SAVED, then carried into every surface identity visited that session.
/// Repairing the live NSToolbar doesn't stick — SwiftUI's own model wins
/// every fight — so the repair happens where SwiftUI reads: the saved
/// configuration, scrubbed at launch before any window exists (and
/// re-applied wholesale when a live drop is caught).
enum ToolbarArrangement {
    static let configKeyPrefix = "NSToolbar Configuration "
    static let itemsKey = "TB Item Identifiers"

    static func isSeparator(_ identifier: String) -> Bool {
        identifier.hasPrefix("com.apple.SwiftUI.splitViewSeparator")
    }

    /// System items are allowed anywhere; only the app's own items must
    /// stay right of the tracking separator.
    static func isSystemItem(_ identifier: String) -> Bool {
        identifier.hasPrefix("com.apple.SwiftUI.")
            || identifier.hasPrefix("NSToolbar")
    }

    /// Moves every app item found before the tracking separator to just
    /// after it, preserving their relative order. Arrangements without a
    /// separator (or already clean) come back unchanged.
    static func repaired(_ identifiers: [String]) -> [String] {
        guard let separator = identifiers.firstIndex(where: isSeparator) else {
            return identifiers
        }
        let misplaced = identifiers[..<separator].filter { !isSystemItem($0) }
        guard !misplaced.isEmpty else { return identifiers }
        var result: [String] = []
        for (index, identifier) in identifiers.enumerated() {
            if index < separator, !isSystemItem(identifier) { continue }
            result.append(identifier)
            if index == separator {
                result.append(contentsOf: misplaced)
            }
        }
        return result
    }

    /// Scrubs every saved toolbar configuration in the given defaults —
    /// called before any window exists, so SwiftUI only ever restores a
    /// clean arrangement.
    static func repairSavedConfigurations(in defaults: UserDefaults) {
        for (key, value) in defaults.dictionaryRepresentation() {
            guard key.hasPrefix(configKeyPrefix),
                  var config = value as? [String: Any],
                  let identifiers = config[itemsKey] as? [String] else { continue }
            let fixed = repaired(identifiers)
            guard fixed != identifiers else { continue }
            config[itemsKey] = fixed
            defaults.set(config, forKey: key)
        }
    }
}
