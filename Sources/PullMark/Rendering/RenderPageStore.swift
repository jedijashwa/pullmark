import Foundation

/// WKWebView only loads local subresources (the vendored JS/CSS) for pages
/// loaded via loadFileURL(_:allowingReadAccessTo:), not for HTML strings.
/// So generated pages are written into a temp directory that also holds a
/// copy of the rendering assets, and loaded from there.
enum RenderPageStore {
    static let directory: URL = {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("PullMarkRender", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        // Purge pages left over from a previous launch.
        if let existing = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for url in existing where url.lastPathComponent.hasPrefix("page-") {
                try? fm.removeItem(at: url)
            }
        }

        if let resources = HTMLBuilder.resourcesBaseURL {
            for item in ["vendor", "app.js", "app.css", "pm-extensions.js"] {
                let destination = dir.appendingPathComponent(item)
                try? fm.removeItem(at: destination)
                try? fm.copyItem(at: resources.appendingPathComponent(item), to: destination)
            }
        }
        return dir
    }()

    static func writePage(_ html: String) -> URL? {
        let url = directory.appendingPathComponent("page-\(UUID().uuidString).html")
        do {
            try html.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    static func removePage(_ url: URL?) {
        guard let url, url.lastPathComponent.hasPrefix("page-") else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
