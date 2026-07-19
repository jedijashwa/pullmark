import Foundation

/// Long documents reopen where you left off: scroll fractions persisted per
/// document key, bounded so the store can't grow without limit. Positions
/// near the top aren't stored — reopening at the beginning IS the default.
@MainActor
enum ReadingPositions {
    private static let limit = 200

    static func save(_ fraction: Double, for key: String) {
        var all = UserDefaults.standard.dictionary(forKey: DefaultsKeys.readingPositions)
            as? [String: Double] ?? [:]
        if fraction < 0.02 || fraction > 0.98 {
            // Top or bottom: nothing worth restoring.
            all[key] = nil
        } else {
            all[key] = fraction
        }
        if all.count > limit {
            // Bounded, not LRU — dropping arbitrary overflow entries is
            // fine for a nicety like this.
            for dropKey in all.keys.prefix(all.count - limit) { all[dropKey] = nil }
        }
        UserDefaults.standard.set(all, forKey: DefaultsKeys.readingPositions)
    }

    static func fraction(for key: String) -> Double? {
        (UserDefaults.standard.dictionary(forKey: DefaultsKeys.readingPositions)
            as? [String: Double])?[key]
    }
}
