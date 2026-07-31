import CoreGraphics
import Foundation

// Usage: swift key2.swift <keycode> [cmd]
let code = CGKeyCode(UInt16(CommandLine.arguments[1])!)
let cmd = CommandLine.arguments.contains("cmd")
let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)!
down.flags = cmd ? .maskCommand : []
down.post(tap: .cghidEventTap)
usleep(80_000)
let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)!
up.flags = cmd ? .maskCommand : []
up.post(tap: .cghidEventTap)
