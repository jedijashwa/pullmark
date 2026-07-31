import CoreGraphics
import Foundation

// Usage: swift pkey.swift <pid> <keycode> [cmd] — key press delivered straight
// to the pid's event queue via CGEvent.postToPid. Does not require the app to
// be frontmost and never disturbs whatever the human is typing into.
guard CommandLine.arguments.count >= 3,
      let pid = pid_t(CommandLine.arguments[1]),
      let raw = UInt16(CommandLine.arguments[2])
else {
    FileHandle.standardError.write(Data("usage: swift pkey.swift <pid> <keycode> [cmd]\n".utf8))
    exit(1)
}
let code = CGKeyCode(raw)
let cmd = CommandLine.arguments.contains("cmd")
let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)!
down.flags = cmd ? .maskCommand : []
down.postToPid(pid)
usleep(80_000)
let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)!
up.flags = cmd ? .maskCommand : []
up.postToPid(pid)
