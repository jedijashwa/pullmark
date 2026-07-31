import CoreGraphics
import Foundation
// usage: gscroll <x> <y> <dy> [cmd] — scroll at point with clean flags, restore cursor
let x = Double(CommandLine.arguments[1])!, y = Double(CommandLine.arguments[2])!
let dy = Int32(CommandLine.arguments[3])!
let cmd = CommandLine.arguments.count > 4 && CommandLine.arguments[4] == "cmd"
let prev = CGEvent(source: nil)!.location
let mv = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)!
mv.flags = []
mv.post(tap: .cghidEventTap)
usleep(100000)
for _ in 0..<6 {
    let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0)!
    e.flags = cmd ? .maskCommand : []
    e.location = CGPoint(x: x, y: y)
    e.post(tap: .cghidEventTap)
    usleep(25000)
}
usleep(100000)
let back = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: prev, mouseButton: .left)!
back.flags = []
back.post(tap: .cghidEventTap)
