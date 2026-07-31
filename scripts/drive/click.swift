import CoreGraphics
import Foundation

// Usage: swift click.swift <x> <y> — left click at global screen point.
let x = Double(CommandLine.arguments[1])!
let y = Double(CommandLine.arguments[2])!
let pt = CGPoint(x: x, y: y)
let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                   mouseCursorPosition: pt, mouseButton: .left)!
move.flags = []
move.post(tap: .cghidEventTap)
usleep(120_000)
let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                   mouseCursorPosition: pt, mouseButton: .left)!
down.flags = []
down.post(tap: .cghidEventTap)
usleep(90_000)
let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                 mouseCursorPosition: pt, mouseButton: .left)!
up.flags = []
up.post(tap: .cghidEventTap)
