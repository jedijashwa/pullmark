import SwiftUI

/// The SwiftUI backdrop behind every Markdown web view. The web view is
/// transparent until its first paint, so this must be the same paper color
/// the page will paint — otherwise loading flashes the wrong color (white
/// over dark mode was the worst case).
enum ThemePaper {
    /// Cached per raw value: resolving a custom theme lists the themes
    /// directory, and backgrounds re-evaluate on every scroll-driven body
    /// pass — no disk I/O belongs there. Papers depend only on the resolved
    /// base theme, which is stable for a given raw value within a launch.
    @MainActor private static var cache: [String: Color] = [:]

    @MainActor
    static func color(for themeRaw: String) -> Color {
        if let cached = cache[themeRaw] { return cached }
        let (light, dark) = Theme.paperHex(for: ThemeSelection.pageStyle(from: themeRaw).theme)
        let color = Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return nsColor(hex: isDark ? dark : light)
        })
        cache[themeRaw] = color
        return color
    }

    /// "#rrggbb" → NSColor; falls back to textBackgroundColor on a bad hex
    /// (cannot happen with the compiled-in palette, but never crash over paint).
    private static func nsColor(hex: String) -> NSColor {
        var value: UInt64 = 0
        let scanner = Scanner(string: String(hex.dropFirst()))
        guard hex.hasPrefix("#"), hex.count == 7, scanner.scanHexInt64(&value) else {
            return .textBackgroundColor
        }
        return NSColor(srgbRed: CGFloat((value >> 16) & 0xff) / 255,
                       green: CGFloat((value >> 8) & 0xff) / 255,
                       blue: CGFloat(value & 0xff) / 255,
                       alpha: 1)
    }
}
