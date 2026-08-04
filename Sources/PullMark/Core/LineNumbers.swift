import Foundation

/// Per-block source line numbers in the rendered views (Settings toggle,
/// off by default). The source and patch views carry real per-line
/// gutters already; this setting gives the rendered presentation an
/// honest coordinate — rendered lines don't map to source lines, so the
/// block is the unit and each shows its start line, full range on hover.
enum LineNumbers {
    static let defaultsKey = "pm.lineNumbers"

    static var enabled: Bool {
        UserDefaults.pullmark.bool(forKey: defaultsKey)
    }
}
