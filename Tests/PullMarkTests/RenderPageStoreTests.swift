import Foundation
import Testing
@testable import PullMark

/// Every test gets its own resources + render directory — never the real
/// `$TMPDIR/PullMarkRender`, which any running PullMark is loading from.
@Suite struct RenderPageStoreTests {
    private let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("RenderPageStoreTests-\(UUID().uuidString)", isDirectory: true)
    private var resources: URL { base.appendingPathComponent("resources", isDirectory: true) }
    private var renderDir: URL { base.appendingPathComponent("render", isDirectory: true) }

    private let assets = [
        "app.js": "app()",
        "app.css": "body{}",
        "pm-extensions.js": "ext()",
        "pm-editor.js": "editor()",
        "vendor/marked.min.js": "marked()",
        "vendor/katex/fonts/KaTeX_Main.woff2": "font",
    ]

    private func makeStore() throws -> RenderPageStore {
        for (path, body) in assets {
            let url = resources.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try body.write(to: url, atomically: true, encoding: .utf8)
        }
        return RenderPageStore(directory: renderDir, resources: resources)
    }

    private func mirrored(_ path: String) -> String? {
        try? String(contentsOf: renderDir.appendingPathComponent(path), encoding: .utf8)
    }

    /// What dirhelper's daily sweep does to a render directory older than
    /// three days: every regular file goes, the directories stay.
    private func sweepFiles(keepingPages: Bool) {
        let fm = FileManager.default
        guard let walker = fm.enumerator(atPath: renderDir.path) else { return }
        while let relative = walker.nextObject() as? String {
            guard (walker.fileAttributes?[.type] as? FileAttributeType) == .typeRegular else { continue }
            if keepingPages, relative.hasPrefix("page-") { continue }
            try? fm.removeItem(at: renderDir.appendingPathComponent(relative))
        }
    }

    @Test func restoresAssetsTheTempCleanerDeleted() throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let store = try makeStore()
        sweepFiles(keepingPages: false)
        #expect(mirrored("app.js") == nil)

        let page = try #require(store.writePage("<p>after the sweep</p>"))
        #expect(FileManager.default.fileExists(atPath: page.path))
        for (path, body) in assets {
            #expect(mirrored(path) == body, "\(path) was not restored")
        }
    }

    @Test func recreatesTheDirectoryWhenItIsGone() throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let store = try makeStore()
        try FileManager.default.removeItem(at: renderDir)

        let page = try #require(store.writePage("<p>after a cleaner app</p>"))
        #expect(FileManager.default.fileExists(atPath: page.path))
        #expect(mirrored("app.js") == "app()")
        #expect(mirrored("vendor/katex/fonts/KaTeX_Main.woff2") == "font")
    }

    /// Restoring must not purge pages other windows have loaded — a
    /// WebKit reload of those reads them from disk again.
    @Test func restoringKeepsOtherPages() throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let store = try makeStore()
        let open = try #require(store.writePage("<p>open in another window</p>"))
        sweepFiles(keepingPages: true)

        _ = try #require(store.writePage("<p>newly opened</p>"))
        #expect(FileManager.default.fileExists(atPath: open.path))
        #expect(mirrored("app.js") == "app()")
    }

    /// One asset gone on its own (a file first read later than the rest
    /// ages out on a later sweep) is still caught.
    @Test func restoresASingleMissingNestedAsset() throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let store = try makeStore()
        try FileManager.default.removeItem(
            at: renderDir.appendingPathComponent("vendor/katex/fonts/KaTeX_Main.woff2"))

        _ = try #require(store.writePage("<p>math</p>"))
        #expect(mirrored("vendor/katex/fonts/KaTeX_Main.woff2") == "font")
    }

    // MARK: - Janitor

    private var root: URL { base.appendingPathComponent("root", isDirectory: true) }

    /// What every process shared before each got its own directory.
    private let flatLayout = ["app.js", "app.css", "pm-extensions.js", "pm-editor.js",
                              "vendor/marked.min.js", "page-OLD.html"]

    private func plant(_ paths: [String]) throws {
        for path in paths {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try "x".write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)
    }

    @Test func janitorRemovesOnlyExitedProcessesDirectories() throws {
        defer { try? FileManager.default.removeItem(at: base) }
        try plant(["101/app.js", "101/page-A.html", "102/app.js", "102/vendor/marked.min.js"])

        RenderPageStore.removeLeftovers(in: root, otherInstances: [101], isRunning: { $0 == 101 })
        #expect(exists("101/app.js"))
        #expect(exists("101/page-A.html"))
        #expect(!exists("102"))
    }

    @Test func janitorRemovesTheSharedLayoutOnceNothingCanBeLoadingIt() throws {
        defer { try? FileManager.default.removeItem(at: base) }
        try plant(flatLayout + ["101/app.js"])

        RenderPageStore.removeLeftovers(in: root, otherInstances: [101], isRunning: { $0 == 101 })
        for path in flatLayout {
            #expect(!exists(path), "\(path) was left behind")
        }
        #expect(!exists("vendor"))
        #expect(exists("101/app.js"))
    }

    /// A running instance with no directory may be a build from before
    /// the split — the installed app, until it updates — whose open
    /// windows and next page still load from the flat layout.
    @Test func janitorKeepsTheSharedLayoutWhileAnOlderBuildMayUseIt() throws {
        defer { try? FileManager.default.removeItem(at: base) }
        try plant(flatLayout + ["101/app.js", "103/app.js"])

        RenderPageStore.removeLeftovers(in: root, otherInstances: [101, 202],
                                        isRunning: { $0 == 101 || $0 == 202 })
        for path in flatLayout {
            #expect(exists(path), "\(path) was removed while an older build may use it")
        }
        #expect(!exists("103"))
    }

    /// Only canonical positive pids name a process directory; anything
    /// else at the top level is flat-layout debris. (kill(0, 0) and
    /// kill(-n, 0) probe process groups, so they must never be asked.)
    @Test func janitorTreatsNonPidNamesAsFlatLayout() throws {
        defer { try? FileManager.default.removeItem(at: base) }
        try plant(["0/app.js", "-5/app.js", "0101/app.js", "notes/app.js"])

        var probed: [pid_t] = []
        RenderPageStore.removeLeftovers(in: root, otherInstances: [], isRunning: {
            probed.append($0)
            return true
        })
        #expect(probed.isEmpty)
        for entry in ["0", "-5", "0101", "notes"] {
            #expect(!exists(entry), "\(entry) was kept")
        }
    }
}
