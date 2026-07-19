import Foundation

/// User-supplied reading themes: any `*.css` file dropped into
/// `~/Library/Application Support/PullMark/Themes/` becomes a selectable
/// theme in Settings → Themes (name = filename without extension). The CSS
/// is appended to rendered pages as an inline `<style>` block (the page CSP
/// allows inline styles) on top of the default GitHub look.
enum CustomThemes {
    /// Prefix used in the persisted `pm.theme` value: "custom:<name>".
    static let selectionPrefix = "custom:"

    static var themesDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PullMark/Themes", isDirectory: true)
    }

    /// Theme names derived from a directory listing (pure — unit-testable).
    /// Only visible `*.css` files count; sorted for a stable Settings order.
    static func themeNames(fromFiles files: [String]) -> [String] {
        files
            .filter { $0.lowercased().hasSuffix(".css") && !$0.hasPrefix(".") }
            .map { String($0.dropLast(4)) }
            .filter { !$0.isEmpty }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    static func availableThemeNames() -> [String] {
        let files = (try? FileManager.default
            .contentsOfDirectory(atPath: themesDirectory.path)) ?? []
        return themeNames(fromFiles: files)
    }

    static func cssURL(for name: String) -> URL {
        themesDirectory.appendingPathComponent(name + ".css", isDirectory: false)
    }

    static func css(for name: String) -> String? {
        try? String(contentsOf: cssURL(for: name), encoding: .utf8)
    }

    /// Creates the Themes directory if needed (used by "Open Themes Folder").
    @discardableResult
    static func ensureDirectoryExists() -> URL {
        let dir = themesDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// Resolution of the persisted `pm.theme` value — either a built-in `Theme`
/// or a custom stylesheet name — into what the page builder needs.
struct ThemeSelection: Equatable {
    /// Built-in base theme. Custom themes render on the GitHub base.
    var theme: Theme
    /// Set when a custom theme is active.
    var customName: String?

    /// The raw value to persist under `pm.theme`.
    var storageValue: String {
        customName.map { CustomThemes.selectionPrefix + $0 } ?? theme.rawValue
    }

    /// Parses a stored raw value against the custom themes currently on
    /// disk. Unknown built-ins and custom themes whose file is gone fall
    /// back to the default GitHub theme.
    static func resolve(_ raw: String?, availableCustom: [String]) -> ThemeSelection {
        guard let raw, raw.hasPrefix(CustomThemes.selectionPrefix) else {
            return ThemeSelection(theme: Theme.current(from: raw), customName: nil)
        }
        let name = String(raw.dropFirst(CustomThemes.selectionPrefix.count))
        guard availableCustom.contains(name) else {
            return ThemeSelection(theme: .github, customName: nil)
        }
        return ThemeSelection(theme: .github, customName: name)
    }

    /// Convenience for views: resolve the stored value against disk and load
    /// the custom CSS (nil for built-ins or when the file vanished).
    static func pageStyle(from raw: String?) -> (theme: String, customCSS: String?) {
        let selection = resolve(raw, availableCustom: CustomThemes.availableThemeNames())
        guard let name = selection.customName, let css = CustomThemes.css(for: name) else {
            return (selection.theme.rawValue, nil)
        }
        return (selection.theme.rawValue, css)
    }
}
