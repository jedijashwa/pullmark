import Foundation
import Testing
@testable import PullMark

/// The containment rule guards against paths the DOCUMENT writes (`..`
/// escapes); symlinks the FOLDER contains are the user's own layout and
/// are followed even when their targets live outside the root.
@Suite("Local resource resolution")
struct LocalResourceResolveTests {
    private func makeWorld() throws -> (root: URL, outside: URL, cleanup: () -> Void) {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pm-resolve-\(UUID().uuidString)")
        let root = base.appendingPathComponent("notes")
        let outside = base.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("real-subdir"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "inside".write(to: root.appendingPathComponent("real-subdir/target.md"),
                           atomically: true, encoding: .utf8)
        try "outside".write(to: outside.appendingPathComponent("file.md"),
                            atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linked-dir"),
            withDestinationURL: outside)
        return (root, outside, { try? FileManager.default.removeItem(at: base) })
    }

    private func resolve(_ relative: String, root: URL) -> URL? {
        LocalResourceSchemeHandler.resolve(
            URL(string: "pullmark-local:///\(relative)")!, root: root)
    }

    @Test func plainRelativePathsResolveInsideTheRoot() throws {
        let world = try makeWorld()
        defer { world.cleanup() }
        let resolved = resolve("real-subdir/target.md", root: world.root)
        #expect(resolved != nil)
        #expect(FileManager.default.fileExists(atPath: resolved?.path ?? ""))
    }

    @Test func symlinksEscapingTheRootAreFollowed() throws {
        let world = try makeWorld()
        defer { world.cleanup() }
        let resolved = resolve("linked-dir/file.md", root: world.root)
        #expect(resolved != nil)
        // The resolved URL lands at the symlink's real target.
        #expect(resolved?.path.hasSuffix("elsewhere/file.md") == true)
        #expect(FileManager.default.fileExists(atPath: resolved?.path ?? ""))
    }

    @Test func dotDotEscapesAreRefusedForAutoLoadedResources() throws {
        let world = try makeWorld()
        defer { world.cleanup() }
        #expect(resolve("../elsewhere/file.md", root: world.root) == nil)
        #expect(resolve("real-subdir/../../elsewhere/file.md", root: world.root) == nil)
    }

    @Test func clickedLinksFollowDotDotOutOfTheRoot() throws {
        let world = try makeWorld()
        defer { world.cleanup() }
        let resolved = LocalResourceSchemeHandler.resolveClickedLink(
            URL(string: "pullmark-local:///../elsewhere/file.md")!, root: world.root)
        #expect(resolved?.path.hasSuffix("elsewhere/file.md") == true)
        #expect(FileManager.default.fileExists(atPath: resolved?.path ?? ""))
    }

    @Test func pmrelQueryCarriesDotDotPastURLNormalization() throws {
        let world = try makeWorld()
        defer { world.cleanup() }
        // What the page actually emits: the URL path already normalized
        // (".." swallowed), the raw relative riding the query parameter.
        let url = URL(string:
            "pullmark-local:///elsewhere/file.md?pmrel=..%2Felsewhere%2Ffile.md")!
        let resolved = LocalResourceSchemeHandler.resolveClickedLink(url, root: world.root)
        #expect(resolved?.path.hasSuffix("elsewhere/file.md") == true)
        #expect(resolved?.path.contains("/notes/") == false)
        #expect(FileManager.default.fileExists(atPath: resolved?.path ?? ""))
    }

    @Test func clickedLinksFollowSymlinksToo() throws {
        let world = try makeWorld()
        defer { world.cleanup() }
        let resolved = LocalResourceSchemeHandler.resolveClickedLink(
            URL(string: "pullmark-local:///linked-dir/file.md")!, root: world.root)
        #expect(resolved?.path.hasSuffix("elsewhere/file.md") == true)
    }

    @Test func dotDotCollapsingInsideTheRootStillResolves() throws {
        let world = try makeWorld()
        defer { world.cleanup() }
        let resolved = resolve("real-subdir/../real-subdir/target.md", root: world.root)
        #expect(resolved != nil)
    }

    @Test func emptyPathsAreRefused() throws {
        let world = try makeWorld()
        defer { world.cleanup() }
        #expect(resolve("", root: world.root) == nil)
    }
}
