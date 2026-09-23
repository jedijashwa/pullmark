import Foundation

/// WKWebView only loads local subresources (the vendored JS/CSS) for pages
/// loaded via loadFileURL(_:allowingReadAccessTo:), not for HTML strings.
/// So generated pages are written into a temp directory that also holds a
/// copy of the rendering assets, and loaded from there.
///
/// Each process gets its own directory, `$TMPDIR/PullMarkRender/<pid>`.
/// When every process shared one, each launch purged the pages the others
/// had loaded and swapped in its own build's assets, so starting a dev
/// build or a screenshot run left the installed app on another version's
/// app.js — blank or broken until relaunch. (`TMPDIR` can't isolate a
/// launch from outside: `FileManager.temporaryDirectory` ignores it.)
final class RenderPageStore {
    /// Everything a generated page may reference relatively. A script the
    /// page names but this list doesn't mirror fails to load silently
    /// (CSP + file access), which is how the rich editor first shipped
    /// its bundle without mounting — HTMLBuilderTests keeps them in sync.
    static let mirroredAssets = ["vendor", "app.js", "app.css", "pm-extensions.js", "pm-editor.js"]

    static let shared: RenderPageStore = {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PullMarkRender", isDirectory: true)
        let pid = ProcessInfo.processInfo.processIdentifier
        removeLeftovers(in: root, otherInstances: runningInstances().filter { $0 != pid })
        return RenderPageStore(
            directory: root.appendingPathComponent(String(pid), isDirectory: true),
            resources: HTMLBuilder.resourcesBaseURL)
    }()

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

        // Purge pages an earlier process with this pid left behind.
        if let existing = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for url in existing where url.lastPathComponent.hasPrefix("page-") {
                try? fm.removeItem(at: url)
            }
        }
        mirrorAssets()
    }

    /// Janitor for `root`, run before this process creates its directory.
    /// Removes directories whose pid has exited — kill(pid, 0) probes
    /// without signaling, so a live instance's folder is never touched —
    /// and the flat layout from before per-process directories: pages and
    /// one shared copy of the assets at the top level. That goes only when
    /// every other running instance has a directory of its own. One
    /// without could be an older build, like an installed copy not yet
    /// updated, still loading its pages from there; an instance that
    /// hasn't rendered yet only defers the cleanup to a later launch.
    static func removeLeftovers(in root: URL, otherInstances: [pid_t],
                                isRunning: (pid_t) -> Bool = { kill($0, 0) == 0 }) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: root.path) else { return }
        let flatLayoutInUse = otherInstances.contains { !entries.contains(String($0)) }
        for entry in entries {
            if let pid = pid_t(entry), pid > 0, String(pid) == entry {
                if isRunning(pid) { continue }
            } else if flatLayoutInUse {
                continue
            }
            try? fm.removeItem(at: root.appendingPathComponent(entry))
        }
    }

    /// Every running process named PullMark: the installed app, dist
    /// trials and debug builds, whatever their version.
    private static func runningInstances() -> [pid_t] {
        let capacity = proc_listallpids(nil, 0) + 64
        guard capacity > 64 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(capacity))
        let count = pids.withUnsafeMutableBytes {
            proc_listallpids($0.baseAddress, Int32($0.count))
        }
        return pids.prefix(Int(max(count, 0))).filter { pid in
            var name = [CChar](repeating: 0, count: 64)
            return proc_name(pid, &name, UInt32(name.count)) > 0 && String(cString: name) == "PullMark"
        }
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
