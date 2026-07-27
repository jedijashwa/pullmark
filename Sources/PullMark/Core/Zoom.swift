import Foundation

/// Document magnification (View → Zoom In/Out/Actual Size, pinch). The value
/// is a WKWebView.pageZoom factor — browser-style zoom, so text, images, and
/// the content column all scale together and reflow inside the window. Pure
/// so the ladder and clamping are unit-testable.
enum DocumentZoom {
    static let minimum = 0.5
    static let maximum = 3.0

    /// The menu-command ladder: browser-style steps, fine near 100% and
    /// coarser at the extremes. Pinch and ⌘-scroll can land between
    /// steps; Zoom In/Out then snap to the next step past the live value.
    static let steps: [Double] = [0.5, 0.65, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]

    /// Tolerance for "already at this step" — pinch persistence and Double
    /// math can leave values a hair off a step.
    private static let epsilon = 0.001

    static func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return 1.0 }
        return min(max(value, minimum), maximum)
    }

    static func zoomIn(from current: Double) -> Double {
        steps.first { $0 > current + epsilon } ?? maximum
    }

    static func zoomOut(from current: Double) -> Double {
        steps.last { $0 < current - epsilon } ?? minimum
    }

    static func label(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    static func isActualSize(_ value: Double) -> Bool {
        abs(value - 1.0) < epsilon
    }

    /// Scale factor for the app's own chrome (sidebar rows, outline panel).
    /// Damped: half the document's travel, and capped — the navigation
    /// should grow with the reading size without a 300% document zoom
    /// producing billboard sidebars.
    static func chromeScale(for zoom: Double) -> Double {
        let damped = 1.0 + (clamped(zoom) - 1.0) * 0.5
        return min(max(damped, 0.85), 2.0)
    }
}
