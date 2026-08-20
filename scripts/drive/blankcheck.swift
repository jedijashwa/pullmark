import AppKit
import Foundation

// Usage: swift blankcheck.swift <png> — exit 0 if the capture's content
// region has actual content, 1 if it is uniform (blank). Under parallel
// load WebKit occasionally hadn't painted a backgrounded window's page
// at capture time; the generator retries those instead of shipping an
// empty pane to the site.
//
// The sampled region sits in the right half, clear of the sidebar,
// titlebar, and window edges, and works for both appearances: any
// rendered scene puts text or diagram pixels there, and a stddev near
// zero means nothing was painted.
guard CommandLine.arguments.count == 2,
      let image = NSImage(contentsOfFile: CommandLine.arguments[1]),
      let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
else {
    FileHandle.standardError.write(Data("usage: swift blankcheck.swift <png>\n".utf8))
    exit(2)
}
let width = cg.width, height = cg.height
let rect = CGRect(x: Int(Double(width) * 0.55), y: Int(Double(height) * 0.2),
                  width: Int(Double(width) * 0.4), height: Int(Double(height) * 0.6))
guard let region = cg.cropping(to: rect),
      let data = region.dataProvider?.data,
      let bytes = CFDataGetBytePtr(data)
else { exit(2) }
let bytesPerRow = region.bytesPerRow
let bpp = region.bitsPerPixel / 8
var sum = 0.0, sumSq = 0.0, n = 0.0
var y = 0
while y < region.height {
    var x = 0
    while x < region.width {
        let p = y * bytesPerRow + x * bpp
        let luminance = 0.3 * Double(bytes[p]) + 0.6 * Double(bytes[p + 1]) + 0.1 * Double(bytes[p + 2])
        sum += luminance
        sumSq += luminance * luminance
        n += 1
        x += 8
    }
    y += 8
}
let mean = sum / n
let variance = max(0, sumSq / n - mean * mean)
let stddev = variance.squareRoot()
print(String(format: "stddev %.2f", stddev))
exit(stddev < 2.0 ? 1 : 0)
