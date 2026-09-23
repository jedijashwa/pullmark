import Foundation

/// WKWebView only loads local subresources (the vendored JS/CSS) for pages
/// loaded via loadFileURL(_:allowingReadAccessTo:), not for HTML strings.
/// So generated pages are written into a temp directory that also holds a
/// copy of the rendering assets, and loaded from there.
final class RenderPageStore {
    /// Everything a generated page may reference relatively. A script the
    /// page names but this list doesn't mirror fails to load silently
    /// (CSP + file access), which is how the rich editor first shipped
    /// its bundle without mounting — HTMLBuilderTests keeps them in sync.
    static let mirroredAssets = ["vendor", "app.js", "app.css", "pm-extensions.js", "pm-editor.js"]

    static let shared = RenderPageStore(
        directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("PullMarkRender", isDirectory: true),
        resources: HTMLBuilder.resourcesBaseURL)

    let directory: URL
    private let resources: URL?
    /// Every mirrored file, relative to `directory` — what each page
    /// write checks is still there.
    private let assetFiles: [String]

    init(directory: URL, resources: URL?) {
        self.directory = directory
        self.resources = resources
        assetFiles = Self.files(of: Self.mirroredAssets, in: resources)
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)

        // Purge pages left over from a previous launch.
        if let existing = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for url in existing where url.lastPathComponent.hasPrefix("page-") {
                try? fm.removeItem(at: url)
            }
        }
        mirrorAssets()
    }

    private func mirrorAssets() {
        guard let resources else { return }
        let fm = FileManager.default
        for item in Self.mirroredAssets {
            let destination = directory.appendingPathComponent(item)
            try? fm.removeItem(at: destination)
            try? fm.copyItem(at: resources.appendingPathComponent(item), to: destination)
        }
    }

    /// macOS deletes files in $TMPDIR not accessed in three days (dirhelper,
    /// daily at 03:35) but records only the first read after a write — so
    /// assets every page loads still look untouched since launch.
    /// After three days up the sweep took them, and every document opened
    /// from then on rendered blank until relaunch. A few dozen stats per
    /// page buys the copy back whenever anything has gone missing.
    private func restoreMissingAssets() {
        let fm = FileManager.default
        guard assetFiles.contains(where: {
            !fm.fileExists(atPath: directory.appendingPathComponent($0).path)
        }) else { return }
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        mirrorAssets()
    }

    private static func files(of items: [String], in resources: URL?) -> [String] {
        guard let resources else { return [] }
        let fm = FileManager.default
        var files: [String] = []
        for item in items {
            var isDirectory: ObjCBool = false
            let url = resources.appendingPathComponent(item)
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            guard isDirectory.boolValue, let walker = fm.enumerator(atPath: url.path) else {
                files.append(item)
                continue
            }
            while let relative = walker.nextObject() as? String {
                if (walker.fileAttributes?[.type] as? FileAttributeType) == .typeRegular {
                    files.append(item + "/" + relative)
                }
            }
        }
        return files
    }

    func writePage(_ html: String) -> URL? {
        restoreMissingAssets()
        let url = directory.appendingPathComponent("page-\(UUID().uuidString).html")
        do {
            try html.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    func removePage(_ url: URL?) {
        guard let url, url.lastPathComponent.hasPrefix("page-") else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
