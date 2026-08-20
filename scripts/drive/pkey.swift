import CoreGraphics
import Foundation

// Usage: swift pkey.swift <pid> <keycode> [cmd] [shift] [opt] [ctrl] — key
// press delivered straight to the pid's event queue via CGEvent.postToPid.
// Does not require the app to be frontmost and never disturbs whatever the
// human is typing into. Modifier args combine (e.g. `5 cmd shift` = ⇧⌘G).
guard CommandLine.arguments.count >= 3,
      let pid = pid_t(CommandLine.arguments[1]),
      let raw = UInt16(CommandLine.arguments[2])
else {
    FileHandle.standardError.write(Data("usage: swift pkey.swift <pid> <keycode> [cmd] [shift] [opt] [ctrl]\n".utf8))
    exit(1)
}
let code = CGKeyCode(raw)
var flags: CGEventFlags = []
if CommandLine.arguments.contains("cmd") { flags.insert(.maskCommand) }
if CommandLine.arguments.contains("shift") { flags.insert(.maskShift) }
if CommandLine.arguments.contains("opt") { flags.insert(.maskAlternate) }
if CommandLine.arguments.contains("ctrl") { flags.insert(.maskControl) }
let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)!
down.flags = flags
down.postToPid(pid)
usleep(80_000)
let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)!
up.flags = flags
up.postToPid(pid)
