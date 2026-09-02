import Foundation

/// A pinned sidebar entry (spec: pinned-and-session-reopen §1–§4): a
/// folder that lives in the Pinned section as its own root, or a file
/// bookmark. Pins are a preference — they persist on their own
/// (`pm.pinnedEntries`) and always come back, whatever the session
/// setting says. Folder pins carry their tree state so a pinned root
/// restores whole without the session snapshot.
struct Pin: Identifiable, Equatable, Codable {
    enum Kind: String, Codable {
        case folder
        case file
    }

    var kind: Kind
    var path: String
    var alias: String?
    /// "tree" | "list" — folder pins only.
    var viewMode: String?
    /// Expanded tree paths — folder pins only.
    var expanded: [String]?

    var id: String { kind.rawValue + ":" + path }
    var url: URL { URL(fileURLWithPath: path) }
    var name: String { (path as NSString).lastPathComponent }
    /// What the row shows: the alias when set, else the file or folder
    /// name.
    var title: String { alias ?? name }

    init(kind: Kind, path: String, alias: String? = nil,
         viewMode: String? = nil, expanded: [String]? = nil) {
        self.kind = kind
        self.path = path
        self.alias = alias
        self.viewMode = viewMode
        self.expanded = expanded
    }

    static func decodeList(_ data: Data?) -> [Pin] {
        guard let data, let pins = try? JSONDecoder().decode([Pin].self, from: data) else { return [] }
        return pins
    }

    static func encodeList(_ pins: [Pin]) -> Data? {
        try? JSONEncoder().encode(pins)
    }
}

/// Which sidebar titles need their true path shown beneath them (spec
/// §2): every aliased entry, and any title two entries in the same
/// section share (case-insensitive) — twins always disambiguate, a
/// unique un-aliased root stays one line.
enum SidebarNaming {
    struct Entry: Equatable {
        var id: String
        var title: String
        var aliased: Bool
    }

    static func entriesNeedingPath(_ entries: [Entry]) -> Set<String> {
        var counts: [String: Int] = [:]
        for entry in entries {
            counts[entry.title.lowercased(), default: 0] += 1
        }
        var result: Set<String> = []
        for entry in entries where entry.aliased || counts[entry.title.lowercased(), default: 0] > 1 {
            result.insert(entry.id)
        }
        return result
    }

    /// An alias field's commit: whitespace-trimmed; empty (or equal to
    /// the entry's own name) clears the alias rather than storing it.
    static func normalizedAlias(_ raw: String, name: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == name ? nil : trimmed
    }
}

/// The "Reopen previous session at launch" setting's default flip (spec
/// §5): off for fresh installs, but a user who already has a session
/// snapshot and never touched the setting keeps reopening — a default
/// change must never empty anyone's window.
enum SessionReopen {
    static func migratedValue(storedSetting: Bool?, hasSnapshot: Bool) -> Bool {
        if let storedSetting { return storedSetting }
        return hasSnapshot
    }
}
