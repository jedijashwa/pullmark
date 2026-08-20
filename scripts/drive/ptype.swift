import CoreGraphics
import Foundation

// Usage: swift ptype.swift <pid> <text> — type text into the pid's event
// queue as unicode keyboard events. Replaces pbcopy+⌘V flows: it never
// touches the shared clipboard, so parallel capture instances (and the
// human's copy buffer) stay unmolested.
guard CommandLine.arguments.count >= 3,
      let pid = pid_t(CommandLine.arguments[1])
else {
    FileHandle.standardError.write(Data("usage: swift ptype.swift <pid> <text>\n".utf8))
    exit(1)
}
let text = CommandLine.arguments.dropFirst(2).joined(separator: " ")
for character in text {
    let units = Array(String(character).utf16)
    let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!
    down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
    down.postToPid(pid)
    usleep(30_000)
    let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)!
    up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
    up.postToPid(pid)
    usleep(30_000)
}
