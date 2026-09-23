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
}
