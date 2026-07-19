import CryptoKit
import Foundation

/// Safety net for block editing: before PullMark writes a file, the
/// previous contents are snapshotted to Application Support, and File →
/// Revert Last Edit swaps the newest snapshot back (itself snapshotting
/// first, so a revert can be reverted). Bounded per file; local files
/// only — nothing remote ever lands here.
@MainActor
enum EditHistory {
    private static let perFileLimit = 20

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("PullMark/History", isDirectory: true)
    }

    private static func folder(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.path.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined().prefix(16)
        return directory.appendingPathComponent(String(name), isDirectory: true)
    }

    /// Snapshots the file's current on-disk contents. Call BEFORE writing.
    static func snapshot(_ url: URL) {
        guard let contents = try? Data(contentsOf: url) else { return }
        let folder = folder(for: url)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = String(Int(Date().timeIntervalSince1970 * 1000))
        try? contents.write(to: folder.appendingPathComponent("\(stamp).md"))
        prune(folder)
    }

    static func lastSnapshot(for url: URL) -> URL? {
        snapshots(in: folder(for: url)).last
    }

    /// Restores the newest snapshot: the current contents are snapshotted
    /// first (so the revert is itself revertible), then the file is
    /// rewritten and the used snapshot removed.
    static func revertLastEdit(for url: URL) throws {
        guard let snapshotURL = lastSnapshot(for: url) else { return }
        let previous = try Data(contentsOf: snapshotURL)
        try FileManager.default.removeItem(at: snapshotURL)
        snapshot(url)
        try previous.write(to: url, options: .atomic)
    }

    private static func snapshots(in folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder,
                                                       includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func prune(_ folder: URL) {
        let all = snapshots(in: folder)
        guard all.count > perFileLimit else { return }
        for stale in all.prefix(all.count - perFileLimit) {
            try? FileManager.default.removeItem(at: stale)
        }
    }
}
