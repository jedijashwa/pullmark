import Testing
import Foundation
@testable import PullMark

@Suite("Document zoom")
struct ZoomTests {

    @Test("The step ladder is sorted, unique, and anchored at 100%")
    func ladderShape() {
        #expect(DocumentZoom.steps == DocumentZoom.steps.sorted())
        #expect(Set(DocumentZoom.steps).count == DocumentZoom.steps.count)
        #expect(DocumentZoom.steps.contains(1.0))
        #expect(DocumentZoom.steps.first == DocumentZoom.minimum)
        #expect(DocumentZoom.steps.last == DocumentZoom.maximum)
    }

    @Test("Zoom In climbs the ladder and stops at the top")
    func zoomInSteps() {
        #expect(DocumentZoom.zoomIn(from: 1.0) == 1.1)
        #expect(DocumentZoom.zoomIn(from: 1.1) == 1.25)
        #expect(DocumentZoom.zoomIn(from: 3.0) == 3.0)
        #expect(DocumentZoom.zoomIn(from: 2.75) == 3.0)
    }

    @Test("Zoom Out descends and stops at the bottom")
    func zoomOutSteps() {
        #expect(DocumentZoom.zoomOut(from: 1.0) == 0.9)
        #expect(DocumentZoom.zoomOut(from: 0.5) == 0.5)
        #expect(DocumentZoom.zoomOut(from: 3.0) == 2.5)
    }

    @Test("Pinch can leave the value between steps; the commands snap past it")
    func betweenSteps() {
        #expect(DocumentZoom.zoomIn(from: 1.37) == 1.5)
        #expect(DocumentZoom.zoomOut(from: 1.37) == 1.25)
        // A hair off a step (Double math) counts as being on it.
        #expect(DocumentZoom.zoomIn(from: 1.1000000001) == 1.25)
        #expect(DocumentZoom.zoomOut(from: 1.0999999999) == 1.0)
    }

    @Test("Clamping bounds the value and shrugs off garbage")
    func clamping() {
        #expect(DocumentZoom.clamped(0.1) == DocumentZoom.minimum)
        #expect(DocumentZoom.clamped(9.0) == DocumentZoom.maximum)
        #expect(DocumentZoom.clamped(1.25) == 1.25)
        // A corrupted default must not wedge the app at nonsense zoom.
        #expect(DocumentZoom.clamped(.nan) == 1.0)
        #expect(DocumentZoom.clamped(.infinity) == 1.0)
    }

    @Test("Labels are whole percentages")
    func labels() {
        #expect(DocumentZoom.label(1.0) == "100%")
        #expect(DocumentZoom.label(1.25) == "125%")
        #expect(DocumentZoom.label(0.65) == "65%")
        #expect(DocumentZoom.label(1.3699999) == "137%")
    }

    @Test("Actual-size detection tolerates float dust")
    func actualSize() {
        #expect(DocumentZoom.isActualSize(1.0))
        #expect(DocumentZoom.isActualSize(1.0000001))
        #expect(!DocumentZoom.isActualSize(1.1))
    }

    @Test("Chrome scale is damped and capped")
    func chromeScale() {
        #expect(DocumentZoom.chromeScale(for: 1.0) == 1.0)
        // Half the document's travel…
        #expect(abs(DocumentZoom.chromeScale(for: 1.5) - 1.25) < 0.0001)
        #expect(abs(DocumentZoom.chromeScale(for: 2.0) - 1.5) < 0.0001)
        // …capped so 300% never produces billboard sidebars…
        #expect(DocumentZoom.chromeScale(for: 3.0) == 2.0)
        // …and floored so zooming out never makes the chrome unreadable.
        #expect(DocumentZoom.chromeScale(for: 0.5) == 0.85)
    }

    @Test("The zoom commands have the standard bindings")
    func zoomShortcuts() {
        #expect(ShortcutAction.zoomIn.defaultCombo == KeyCombo(key: "=", command: true))
        #expect(ShortcutAction.zoomOut.defaultCombo == KeyCombo(key: "-", command: true))
        #expect(ShortcutAction.actualSize.defaultCombo == KeyCombo(key: "0", command: true))
        #expect(ShortcutAction.zoomIn.category == "View")
    }
}
