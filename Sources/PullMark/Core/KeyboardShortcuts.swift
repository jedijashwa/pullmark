import Foundation

/// A concrete key combination: one key plus modifier flags. `key` is either
/// a single lowercase character ("e", "1", ",") or a named special key
/// ("escape", "return", "up", "f5", …). Pure and Codable so the registry,
/// persistence, and conflict logic stay unit-testable without AppKit.
struct KeyCombo: Codable, Equatable, Hashable {
    var key: String
    var command = false
    var shift = false
    var option = false
    var control = false

    /// Named special keys this app understands, in canonical storage form.
    static let namedKeys: Set<String> = [
        "escape", "return", "tab", "space", "delete", "forwarddelete",
        "up", "down", "left", "right", "home", "end", "pageup", "pagedown",
        "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12",
    ]

    private static let keyGlyphs: [String: String] = [
        "escape": "⎋", "return": "↩", "tab": "⇥", "space": "Space",
        "delete": "⌫", "forwarddelete": "⌦",
        "up": "↑", "down": "↓", "left": "←", "right": "→",
        "home": "↖", "end": "↘", "pageup": "⇞", "pagedown": "⇟",
    ]

    private static let spokenKeys: [String: String] = [
        "escape": "Escape", "return": "Return", "tab": "Tab", "space": "Space",
        "delete": "Delete", "forwarddelete": "Forward Delete",
        "up": "Up Arrow", "down": "Down Arrow", "left": "Left Arrow",
        "right": "Right Arrow", "home": "Home", "end": "End",
        "pageup": "Page Up", "pagedown": "Page Down",
    ]

    var isFunctionKey: Bool { key.hasPrefix("f") && Int(key.dropFirst()) != nil }

    /// Menu-bar style rendering: modifier symbols in canonical order, then
    /// the key ("⌃⌥⇧⌘E", "⇧⌘G", "F5").
    var display: String {
        var out = ""
        if control { out += "⌃" }
        if option { out += "⌥" }
        if shift { out += "⇧" }
        if command { out += "⌘" }
        if let glyph = Self.keyGlyphs[key] {
            out += glyph
        } else {
            out += key.uppercased()
        }
        return out
    }

    /// VoiceOver reads glyph strings unreliably — "Shift Command O".
    var spoken: String {
        var parts: [String] = []
        if control { parts.append("Control") }
        if option { parts.append("Option") }
        if shift { parts.append("Shift") }
        if command { parts.append("Command") }
        parts.append(Self.spokenKeys[key] ?? (isFunctionKey ? key.uppercased() : key.uppercased()))
        return parts.joined(separator: " ")
    }

    /// A combo a menu item or button can actually own. Bare characters
    /// would type into text fields, so character keys need ⌘ or ⌃;
    /// function keys stand alone.
    var isBindable: Bool { command || control || isFunctionKey }

    /// What already owns this combo — a standard app command, something
    /// the system swallows before the app ever sees it, or one of the
    /// fixed sheet keys. nil when the combo is free to take.
    var reservedFor: String? {
        // Swallowed above the app: binding these produces a row that looks
        // right and a key that never fires.
        if command, !option, !control, !shift {
            switch key {
            case "space": return "Spotlight"
            case "tab": return "the app switcher"
            case "`": return "cycling windows"
            default: break
            }
        }
        if control, !command, !option, ["up", "down", "left", "right"].contains(key) {
            return "Mission Control"
        }
        // Fixed keys the app's own sheets and palettes own (Esc to
        // dismiss, ⌘↩ to commit) — they can't be rebound, so nothing
        // else may claim them either.
        if !command, !option, !control, !shift, key == "escape" {
            return "dismissing sheets"
        }
        if command, !option, !control, !shift, key == "return" {
            return "confirming sheets"
        }
        if command, shift, !option, !control {
            let shifted = ["z": "Redo", "/": "the Help menu"]
            return shifted[key]
        }
        guard command, !option, !control, !shift else { return nil }
        let reserved = [
            "q": "Quit", "w": "Close Window", "h": "Hide", "m": "Minimize",
            ",": "Settings", "c": "Copy", "v": "Paste", "x": "Cut",
            "a": "Select All", "z": "Undo", "n": "New Window", "t": "New Tab",
        ]
        return reserved[key]
    }

    var isReserved: Bool { reservedFor != nil }
}

/// Every user-facing keyboard action in the app. Raw values are the
/// persistence keys — never change one once shipped.
enum ShortcutAction: String, CaseIterable, Codable {
    case openFile, openPullRequest, openQuickly, commitChanges, revertLastEdit
    case revealInFinder, copyPath, refreshFolder, clearRecents
    case pageSetup, printDocument, exportPDF, exportHTML
    case editMode, copyAsMarkdown
    case findInPage, findNext, findPrevious, searchAllFiles
    case toggleOutline, toggleSource, reloadDocument
    case zoomIn, zoomOut, actualSize
    case prRenderedDiff, prSourceDiff, prResult, prFlipLayout
    case reviewChanges, showResolvedConversations
    case addMarginNote, addFileMarginNote, toggleMarginNotes

    var title: String {
        switch self {
        case .openFile: return "Open…"
        case .openPullRequest: return "Open Pull Request…"
        case .openQuickly: return "Open Quickly…"
        case .commitChanges: return "Commit Changes…"
        case .revertLastEdit: return "Revert Last Edit"
        case .revealInFinder: return "Reveal in Finder"
        case .copyPath: return "Copy Path"
        case .refreshFolder: return "Refresh Folder"
        case .clearRecents: return "Clear Recents"
        case .pageSetup: return "Page Setup…"
        case .printDocument: return "Print…"
        case .exportPDF: return "Export as PDF…"
        case .exportHTML: return "Export as HTML…"
        case .editMode: return "Edit Mode"
        case .copyAsMarkdown: return "Copy as Markdown"
        case .findInPage: return "Find in Page"
        case .findNext: return "Find Next"
        case .findPrevious: return "Find Previous"
        case .searchAllFiles: return "Search All Files…"
        case .toggleOutline: return "Show/Hide Outline"
        case .toggleSource: return "Show/Hide Markdown Source"
        case .reloadDocument: return "Reload Document"
        case .zoomIn: return "Zoom In"
        case .zoomOut: return "Zoom Out"
        case .actualSize: return "Actual Size"
        case .prRenderedDiff: return "Rendered Diff"
        case .prSourceDiff: return "Source Diff"
        case .prResult: return "Result"
        case .prFlipLayout: return "Flip Diff Layout"
        case .reviewChanges: return "Review Changes…"
        // The menu item's title flips Show/Hide with state; the settings
        // row names the toggle itself.
        case .showResolvedConversations: return "Show/Hide Resolved Conversations"
        case .addMarginNote: return "Add Margin Note"
        case .addFileMarginNote: return "File Margin Note…"
        case .toggleMarginNotes: return "Show/Hide Margin Notes"
        }
    }

    /// Mirrors the menu the action lives in, so the settings list and the
    /// menu bar agree about where a command belongs.
    var category: String {
        switch self {
        case .openFile, .openPullRequest, .openQuickly, .commitChanges,
             .revertLastEdit, .revealInFinder, .copyPath, .refreshFolder,
             .clearRecents, .pageSetup, .printDocument, .exportPDF, .exportHTML:
            return "File"
        case .editMode, .copyAsMarkdown, .addMarginNote, .addFileMarginNote,
             .findInPage, .findNext, .findPrevious, .searchAllFiles:
            return "Edit"
        case .toggleOutline, .toggleSource, .reloadDocument,
             .zoomIn, .zoomOut, .actualSize, .toggleMarginNotes:
            return "View"
        case .prRenderedDiff, .prSourceDiff, .prResult, .prFlipLayout, .reviewChanges,
             .showResolvedConversations:
            return "Pull Requests"
        }
    }

    /// Categories in the order the Keyboard settings tab shows them.
    static let categories = ["File", "Edit", "View", "Pull Requests"]

    /// Where the action applies. Every action has a menu item that greys
    /// out when it doesn't apply; this says so in the settings list too,
    /// where there is no menu to look at.
    var scopeNote: String? {
        switch self {
        case .toggleOutline, .reloadDocument, .editMode:
            return "In a local document"
        case .revealInFinder, .copyPath:
            return "With a local file or folder selected"
        case .refreshFolder:
            return "With a folder selected"
        case .findNext, .findPrevious:
            return "While the find bar is open"
        case .prRenderedDiff, .prSourceDiff, .prResult, .prFlipLayout:
            return "In a pull request file"
        case .reviewChanges:
            return "In a pull request"
        case .showResolvedConversations:
            return "In a pull request file's Result view"
        case .addMarginNote, .addFileMarginNote:
            return "In a local document"
        default:
            return nil
        }
    }

    /// The shipped binding; nil means the action has no shortcut until the
    /// user records one (it still appears in menus and settings).
    var defaultCombo: KeyCombo? {
        switch self {
        case .openFile: return KeyCombo(key: "o", command: true)
        case .openPullRequest: return KeyCombo(key: "o", command: true, shift: true)
        case .openQuickly: return KeyCombo(key: "k", command: true)
        case .commitChanges: return KeyCombo(key: "k", command: true, control: true)
        case .revertLastEdit: return nil
        // Sidebar commands ship unbound: they appear in menus and the
        // Keyboard settings, and the user records a combo if they want one.
        case .revealInFinder: return nil
        case .copyPath: return nil
        case .refreshFolder: return nil
        case .clearRecents: return nil
        case .pageSetup: return KeyCombo(key: "p", command: true, shift: true)
        case .printDocument: return KeyCombo(key: "p", command: true)
        case .exportPDF: return nil
        case .exportHTML: return nil
        case .editMode: return KeyCombo(key: "e", command: true)
        case .copyAsMarkdown: return KeyCombo(key: "c", command: true, option: true)
        case .findInPage: return KeyCombo(key: "f", command: true)
        case .findNext: return KeyCombo(key: "g", command: true)
        case .findPrevious: return KeyCombo(key: "g", command: true, shift: true)
        case .searchAllFiles: return KeyCombo(key: "f", command: true, shift: true)
        case .toggleOutline: return KeyCombo(key: "o", command: true, option: true)
        case .toggleSource: return KeyCombo(key: "u", command: true, option: true)
        case .reloadDocument: return KeyCombo(key: "r", command: true)
        // The unshifted key: ⌘= is what a physical "⌘+" press starts as,
        // and the menu bar joins VS Code in labeling it that way (Safari
        // shows ⌘+, but one binding can't match both spellings here).
        // ⇧⌘= — holding shift for a literal "+" — is honored by
        // ZoomKeyCatcher while the binding is at its default.
        case .zoomIn: return KeyCombo(key: "=", command: true)
        case .zoomOut: return KeyCombo(key: "-", command: true)
        case .actualSize: return KeyCombo(key: "0", command: true)
        case .prRenderedDiff: return KeyCombo(key: "1", command: true)
        case .prSourceDiff: return KeyCombo(key: "2", command: true)
        case .prResult: return KeyCombo(key: "3", command: true)
        case .prFlipLayout: return KeyCombo(key: "l", command: true, option: true)
        // ⇧⌘R ("Review"): free of the reserved table and every other
        // default; ShortcutStore.init unbinds it from any older user
        // recording rather than double-binding.
        case .reviewChanges: return KeyCombo(key: "r", command: true, shift: true)
        // ⌥⌘R ("Resolved"): same discipline — ShortcutStore.init unbinds
        // any pre-existing user recording of this combo.
        case .showResolvedConversations: return KeyCombo(key: "r", command: true, option: true)
        // ⌥⌘M ("Margin note"): free of the reserved table and every
        // other default; the file-level and visibility variants ship
        // unbound.
        case .addMarginNote: return KeyCombo(key: "m", command: true, option: true)
        case .addFileMarginNote: return nil
        case .toggleMarginNotes: return nil
        }
    }
}

/// The user's customizations: absent = default, `combo: nil` = shortcut
/// removed, otherwise the recorded combo. Pure so encoding and conflict
/// resolution are testable.
struct ShortcutOverrides: Codable, Equatable {
    /// Wrapper so "explicitly no shortcut" survives JSON round-trips
    /// (a bare optional value would be dropped from the dictionary).
    struct Value: Codable, Equatable {
        var combo: KeyCombo?
    }

    private var values: [String: Value] = [:]

    var isEmpty: Bool { values.isEmpty }

    func isCustomized(_ action: ShortcutAction) -> Bool {
        values[action.rawValue] != nil
    }

    /// The effective combo for an action after overrides.
    func combo(for action: ShortcutAction) -> KeyCombo? {
        if let value = values[action.rawValue] { return value.combo }
        return action.defaultCombo
    }

    mutating func set(_ combo: KeyCombo?, for action: ShortcutAction) {
        if combo == action.defaultCombo {
            values[action.rawValue] = nil
        } else {
            values[action.rawValue] = Value(combo: combo)
        }
    }

    mutating func reset(_ action: ShortcutAction) {
        values[action.rawValue] = nil
    }

    mutating func resetAll() {
        values = [:]
    }

    /// The other action currently holding `combo`, if any.
    func conflict(with combo: KeyCombo, excluding action: ShortcutAction) -> ShortcutAction? {
        ShortcutAction.allCases.first { $0 != action && self.combo(for: $0) == combo }
    }

    func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(self)
    }

    static func decoded(from data: Data?) -> ShortcutOverrides {
        guard let data,
              let decoded = try? JSONDecoder().decode(ShortcutOverrides.self, from: data)
        else { return ShortcutOverrides() }
        return decoded
    }
}
