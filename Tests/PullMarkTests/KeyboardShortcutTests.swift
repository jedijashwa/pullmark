import Testing
import Foundation
@testable import PullMark

@Suite("Keyboard shortcuts")
struct KeyboardShortcutTests {

    @Test("Default bindings never collide")
    func defaultsAreUnique() {
        var seen: [KeyCombo: ShortcutAction] = [:]
        for action in ShortcutAction.allCases {
            guard let combo = action.defaultCombo else { continue }
            #expect(seen[combo] == nil,
                    "\(action) and \(String(describing: seen[combo])) share \(combo.display)")
            seen[combo] = action
        }
    }

    @Test("No default binding is reserved or unbindable")
    func defaultsAreLegal() {
        for action in ShortcutAction.allCases {
            guard let combo = action.defaultCombo else { continue }
            #expect(combo.isBindable, "\(action)")
            #expect(!combo.isReserved, "\(action)")
        }
    }

    @Test("Every action has a category the settings tab shows")
    func categoriesCoverAllActions() {
        for action in ShortcutAction.allCases {
            #expect(ShortcutAction.categories.contains(action.category), "\(action)")
        }
    }

    @Test("Display strings render modifiers in canonical order")
    func displayStrings() {
        #expect(KeyCombo(key: "e", command: true).display == "⌘E")
        #expect(KeyCombo(key: "g", command: true, shift: true).display == "⇧⌘G")
        #expect(KeyCombo(key: "k", command: true, control: true).display == "⌃⌘K")
        #expect(KeyCombo(key: "c", command: true, option: true).display == "⌥⌘C")
        #expect(KeyCombo(key: "escape").display == "⎋")
        #expect(KeyCombo(key: "f5").display == "F5")
        #expect(KeyCombo(key: "1", command: true).display == "⌘1")
    }

    @Test("Bindable and reserved rules")
    func bindableAndReserved() {
        #expect(!KeyCombo(key: "e").isBindable)                       // bare letter
        #expect(!KeyCombo(key: "e", shift: true).isBindable)          // shift alone
        #expect(!KeyCombo(key: "e", option: true).isBindable)         // option alone types chars
        #expect(KeyCombo(key: "e", command: true).isBindable)
        #expect(KeyCombo(key: "e", control: true).isBindable)
        #expect(KeyCombo(key: "f5").isBindable)                       // F-keys stand alone
        #expect(KeyCombo(key: "q", command: true).isReserved)         // ⌘Q quit
        #expect(KeyCombo(key: "w", command: true).isReserved)         // ⌘W close
        #expect(KeyCombo(key: "c", command: true).isReserved)         // ⌘C copy
        #expect(!KeyCombo(key: "c", command: true, option: true).isReserved) // ⌥⌘C ours
        #expect(!KeyCombo(key: "q", command: true, shift: true).isReserved)
    }

    @Test("Overrides: set, reset, remove, and round-trip through JSON")
    func overridesRoundTrip() {
        var overrides = ShortcutOverrides()
        #expect(overrides.combo(for: .editMode) == KeyCombo(key: "e", command: true))

        let f2 = KeyCombo(key: "f2")
        overrides.set(f2, for: .editMode)
        #expect(overrides.combo(for: .editMode) == f2)
        #expect(overrides.isCustomized(.editMode))

        overrides.set(nil, for: .findNext) // explicitly unbound
        #expect(overrides.combo(for: .findNext) == nil)

        let decoded = ShortcutOverrides.decoded(from: overrides.encoded())
        #expect(decoded == overrides)
        #expect(decoded.combo(for: .editMode) == f2)
        #expect(decoded.combo(for: .findNext) == nil, "removal must survive persistence")
        #expect(decoded.combo(for: .openFile) == KeyCombo(key: "o", command: true),
                "untouched actions keep their defaults")
    }

    @Test("Setting the default back clears the customization")
    func settingDefaultClears() {
        var overrides = ShortcutOverrides()
        overrides.set(KeyCombo(key: "f2"), for: .editMode)
        overrides.set(KeyCombo(key: "e", command: true), for: .editMode)
        #expect(!overrides.isCustomized(.editMode))
        #expect(overrides.isEmpty)
    }

    @Test("Conflict detection sees defaults and overrides")
    func conflicts() {
        var overrides = ShortcutOverrides()
        // ⌘K is Open Quickly's default.
        #expect(overrides.conflict(with: KeyCombo(key: "k", command: true),
                                   excluding: .editMode) == .openQuickly)
        // No conflict with yourself.
        #expect(overrides.conflict(with: KeyCombo(key: "k", command: true),
                                   excluding: .openQuickly) == nil)
        // Move Open Quickly elsewhere: ⌘K is free now.
        overrides.set(KeyCombo(key: "j", command: true), for: .openQuickly)
        #expect(overrides.conflict(with: KeyCombo(key: "k", command: true),
                                   excluding: .editMode) == nil)
        // …and its new home conflicts.
        #expect(overrides.conflict(with: KeyCombo(key: "j", command: true),
                                   excluding: .editMode) == .openQuickly)
    }

    @Test("Garbage persistence data falls back to defaults")
    func decodeGarbage() {
        let garbage = ShortcutOverrides.decoded(from: Data("not json".utf8))
        #expect(garbage.isEmpty)
        #expect(ShortcutOverrides.decoded(from: nil).isEmpty)
    }

    @Test("Encoding is deterministic")
    func deterministicEncoding() {
        var overrides = ShortcutOverrides()
        overrides.set(KeyCombo(key: "f2"), for: .editMode)
        overrides.set(nil, for: .findNext)
        let first = overrides.encoded()
        for _ in 0..<20 {
            #expect(overrides.encoded() == first)
        }
    }
}
