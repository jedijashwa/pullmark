import CoreGraphics
import Foundation

// Usage: swift drag.swift <fromX> <fromY> <toX> <toY>
let fx = Double(CommandLine.arguments[1])!, fy = Double(CommandLine.arguments[2])!
let tx = Double(CommandLine.arguments[3])!, ty = Double(CommandLine.arguments[4])!
func post(_ type: CGEventType, _ x: Double, _ y: Double) {
    let e = CGEvent(mouseEventSource: nil, mouseType: type,
                    mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)!
    e.flags = []
    e.post(tap: .cghidEventTap)
}
post(.mouseMoved, fx, fy)
usleep(200_000)
post(.leftMouseDown, fx, fy)
usleep(300_000)
// Small jiggle so AppKit recognizes a drag before the big move.
for i in 1...4 { post(.leftMouseDragged, fx + Double(i) * 2, fy + Double(i) * 2); usleep(50_000) }
let steps = 30
for i in 1...steps {
    let p = Double(i) / Double(steps)
    post(.leftMouseDragged, fx + (tx - fx) * p, fy + (ty - fy) * p)
    usleep(30_000)
}
usleep(500_000)
post(.leftMouseUp, tx, ty)
