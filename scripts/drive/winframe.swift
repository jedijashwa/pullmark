// winframe.swift <pid> <width> <height> [<x> <y>]
//
// Pins the pid's main-sized window to an exact logical frame via the
// Accessibility API — the screenshot generator uses it so every capture
// run produces pixel-comparable geometry. Origin defaults to (160, 60).
// Prints the resulting frame.

import AppKit
import ApplicationServices

guard CommandLine.arguments.count >= 4,
      let pid = pid_t(CommandLine.arguments[1]),
      let width = Double(CommandLine.arguments[2]),
      let height = Double(CommandLine.arguments[3])
else {
    FileHandle.standardError.write(Data("usage: winframe.swift <pid> <w> <h> [<x> <y>]\n".utf8))
    exit(2)
}
let x = CommandLine.arguments.count > 5 ? Double(CommandLine.arguments[4]) ?? 160 : 160
let y = CommandLine.arguments.count > 5 ? Double(CommandLine.arguments[5]) ?? 60 : 60

guard AXIsProcessTrusted() else {
    FileHandle.standardError.write(Data("error: Accessibility permission missing\n".utf8))
    exit(1)
}

let app = AXUIElementCreateApplication(pid)
var windowsRef: CFTypeRef?
guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
      let windows = windowsRef as? [AXUIElement], !windows.isEmpty
else {
    FileHandle.standardError.write(Data("error: no AX windows for pid \(pid)\n".utf8))
    exit(1)
}

// Largest window = the main one (same heuristic as winid.swift).
func size(of window: AXUIElement) -> CGSize {
    var ref: CFTypeRef?
    var value = CGSize.zero
    if AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &ref) == .success,
       let axValue = ref, CFGetTypeID(axValue) == AXValueGetTypeID() {
        AXValueGetValue(axValue as! AXValue, .cgSize, &value)
    }
    return value
}
let window = windows.max(by: { size(of: $0).width * size(of: $0).height
                             < size(of: $1).width * size(of: $1).height })!

var position = CGPoint(x: x, y: y)
var dimensions = CGSize(width: width, height: height)
let positionValue = AXValueCreate(.cgPoint, &position)!
let sizeValue = AXValueCreate(.cgSize, &dimensions)!
// Size, position, then size again: AppKit clamps a size set while the
// window would fall offscreen, so settle position between the passes.
AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)

let resulting = size(of: window)
print("frame: \(Int(x)),\(Int(y)) \(Int(resulting.width))x\(Int(resulting.height))")
