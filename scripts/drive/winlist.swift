import CoreGraphics
import Foundation

// Usage: swift winlist.swift <pid> — prints "id x y w h layer" for each window.
let pid = Int32(CommandLine.arguments[1])!
let opts: CGWindowListOption = [.optionOnScreenOnly]
let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as! [[String: Any]]
for info in list {
    guard let owner = info[kCGWindowOwnerPID as String] as? Int32, owner == pid,
          let id = info[kCGWindowNumber as String] as? Int,
          let bounds = info[kCGWindowBounds as String] as? [String: CGFloat]
    else { continue }
    let layer = info[kCGWindowLayer as String] as? Int ?? 0
    print("\(id) \(Int(bounds["X"]!)) \(Int(bounds["Y"]!)) \(Int(bounds["Width"]!)) \(Int(bounds["Height"]!)) \(layer)")
}
