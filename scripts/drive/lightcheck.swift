import AppKit
import Foundation

// Usage: swift lightcheck.swift <png>... — for each capture, verify the
// close button renders COLORED (red), i.e. the window photographed with
// active chrome. Gray lights mean the capture raced a focus change.
// Prints failures; exit 1 if any. The red button is the universal
// check: main windows show red/yellow/green and Settings windows
// red/gray/gray, but red leads in both.
var failures = 0
for path in CommandLine.arguments.dropFirst() {
    guard let image = NSImage(contentsOfFile: path),
          let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
          let data = cg.dataProvider?.data,
          let bytes = CFDataGetBytePtr(data)
    else { print("UNREADABLE \(path)"); failures += 1; continue }
    let scale = cg.width >= 1600 ? 2 : 1  // Retina captures are 2x
    let bytesPerRow = cg.bytesPerRow
    let bpp = cg.bitsPerPixel / 8
    // Sample a small box around the close button's center (~26,25 pt
    // in the window; captures are window-cropped so origin is the
    // window corner). Look for any strongly red pixel.
    var redFound = false
    for dy in stride(from: 18 * scale, to: 32 * scale, by: 2) {
        for dx in stride(from: 18 * scale, to: 36 * scale, by: 2) {
            let p = dy * bytesPerRow + dx * bpp
            let r = Int(bytes[p]), g = Int(bytes[p + 1]), b = Int(bytes[p + 2])
            if r > 190 && g < 140 && b < 140 { redFound = true }
        }
        if redFound { break }
    }
    if !redFound { print("GRAY LIGHTS \(path)"); failures += 1 }
}
exit(failures == 0 ? 0 : 1)
