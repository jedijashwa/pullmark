import CoreGraphics
import Foundation

// Move the mouse to a point (menus track hover).
let x = Double(CommandLine.arguments[1])!, y = Double(CommandLine.arguments[2])!
let e = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)!
e.flags = []
e.post(tap: .cghidEventTap)
