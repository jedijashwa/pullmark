import CoreGraphics
import Foundation
let pid = Int(CommandLine.arguments[1])!
let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
for w in info {
    guard let owner = w["kCGWindowOwnerPID"] as? Int, owner == pid,
          let bounds = w["kCGWindowBounds"] as? [String: Any],
          let height = bounds["Height"] as? Double, height > 300,
          let num = w["kCGWindowNumber"] as? Int else { continue }
    print(num)
}
