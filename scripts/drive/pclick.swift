import CoreGraphics
import Foundation

// Usage: swift pclick.swift <pid> <x> <y> — left click delivered straight to
// the pid's event queue via CGEvent.postToPid. Coordinates are still global
// screen points (the app resolves which of its windows contains them), but
// the visible cursor never moves and the target app need not be frontmost.
guard CommandLine.arguments.count >= 4,
      let pid = pid_t(CommandLine.arguments[1]),
      let x = Double(CommandLine.arguments[2]),
      let y = Double(CommandLine.arguments[3])
else {
    FileHandle.standardError.write(Data("usage: swift pclick.swift <pid> <x> <y>\n".utf8))
    exit(1)
}
let pt = CGPoint(x: x, y: y)
let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                   mouseCursorPosition: pt, mouseButton: .left)!
down.flags = []
down.setIntegerValueField(.mouseEventClickState, value: 1)
down.postToPid(pid)
usleep(90_000)
let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                 mouseCursorPosition: pt, mouseButton: .left)!
up.flags = []
up.setIntegerValueField(.mouseEventClickState, value: 1)
up.postToPid(pid)
