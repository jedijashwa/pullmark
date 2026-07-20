import SwiftUI
import AppKit

/// App-wide source of truth for keyboard bindings. Menus, hidden shortcut
/// buttons, and the Keyboard settings tab all read from here, so recording
/// a new combo re-keys the whole app live.
@MainActor
final class ShortcutStore: ObservableObject {
    static let shared = ShortcutStore()

    @Published private(set) var overrides: ShortcutOverrides

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        overrides = ShortcutOverrides.decoded(
            from: defaults.data(forKey: DefaultsKeys.shortcutOverrides))
    }

    private let defaults: UserDefaults

    func combo(for action: ShortcutAction) -> KeyCombo? {
        overrides.combo(for: action)
    }

    func isCustomized(_ action: ShortcutAction) -> Bool {
        overrides.isCustomized(action)
    }

    /// " (⌘O)" for help strings — empty when the action is unbound, so
    /// tooltips never promise a shortcut the user removed.
    func hint(_ action: ShortcutAction) -> String {
        combo(for: action).map { " (\($0.display))" } ?? ""
    }

    var anyCustomized: Bool { !overrides.isEmpty }

    /// Records a combo (or nil to remove the binding). Returns a
    /// user-facing refusal when the combo is reserved or taken.
    @discardableResult
    func assign(_ combo: KeyCombo?, to action: ShortcutAction) -> String? {
        if let combo {
            guard combo.isBindable else {
                return "Shortcuts need ⌘ or ⌃ (function keys can stand alone)."
            }
            if combo.isReserved {
                return "\(combo.display) is reserved by macOS."
            }
            if let taken = overrides.conflict(with: combo, excluding: action) {
                return "\(combo.display) is already used by “\(taken.title)”."
            }
        }
        overrides.set(combo, for: action)
        persist()
        return nil
    }

    func reset(_ action: ShortcutAction) {
        overrides.reset(action)
        persist()
    }

    func resetAll() {
        overrides.resetAll()
        persist()
    }

    private func persist() {
        defaults.set(overrides.encoded(), forKey: DefaultsKeys.shortcutOverrides)
    }

    /// The SwiftUI shortcut for `.keyboardShortcut(_:)` — nil (no shortcut)
    /// when the action is unbound.
    func keyboardShortcut(for action: ShortcutAction) -> KeyboardShortcut? {
        guard let combo = combo(for: action),
              let key = Self.keyEquivalent(for: combo.key) else { return nil }
        var modifiers: EventModifiers = []
        if combo.command { modifiers.insert(.command) }
        if combo.shift { modifiers.insert(.shift) }
        if combo.option { modifiers.insert(.option) }
        if combo.control { modifiers.insert(.control) }
        return KeyboardShortcut(key, modifiers: modifiers)
    }

    private static func keyEquivalent(for key: String) -> KeyEquivalent? {
        switch key {
        case "escape": return .escape
        case "return": return .return
        case "tab": return .tab
        case "space": return .space
        case "delete": return .delete
        case "forwarddelete": return .deleteForward
        case "up": return .upArrow
        case "down": return .downArrow
        case "left": return .leftArrow
        case "right": return .rightArrow
        case "home": return .home
        case "end": return .end
        case "pageup": return .pageUp
        case "pagedown": return .pageDown
        default:
            // F-keys have no KeyEquivalent; map via their Unicode scalars.
            if key.hasPrefix("f"), let n = Int(key.dropFirst()), (1...12).contains(n),
               let scalar = Unicode.Scalar(0xF704 + n - 1) {
                return KeyEquivalent(Character(scalar))
            }
            guard key.count == 1, let char = key.first else { return nil }
            return KeyEquivalent(char)
        }
    }

    /// Maps a captured keyDown to a KeyCombo, or nil for events that make
    /// no sense as a binding (bare modifiers, dead keys).
    nonisolated static func combo(from event: NSEvent) -> KeyCombo? {
        let flags = event.modifierFlags
        var combo = KeyCombo(
            key: "",
            command: flags.contains(.command),
            shift: flags.contains(.shift),
            option: flags.contains(.option),
            control: flags.contains(.control))
        if let named = specialKeys[event.keyCode] {
            combo.key = named
            return combo
        }
        // charactersIgnoringModifiers still applies Shift for letters on
        // some layouts; lowercase to keep the canonical form.
        guard let chars = event.charactersIgnoringModifiers?.lowercased(),
              let first = chars.first,
              !first.isWhitespace, first.asciiValue.map({ $0 >= 32 }) ?? true
        else { return nil }
        combo.key = String(first)
        return combo
    }

    private nonisolated static let specialKeys: [UInt16: String] = [
        36: "return", 76: "return", 48: "tab", 49: "space", 51: "delete",
        53: "escape", 117: "forwarddelete", 115: "home", 119: "end",
        116: "pageup", 121: "pagedown",
        123: "left", 124: "right", 125: "down", 126: "up",
        122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6",
        98: "f7", 100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12",
    ]
}
