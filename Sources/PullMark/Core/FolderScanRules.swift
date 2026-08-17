import Foundation

/// What the folder scanner refuses to descend into — and the matching
/// judgment for watcher events: changes wholly inside skipped subtrees
/// cannot alter the visible Markdown tree, so they must not trigger
/// rescans. Git's own churn under .git (index writes, object packs —
/// constant while tools work in a repo) was rescanning whole monorepos
/// continuously.
enum FolderScanRules {
    /// Raw object stores and dependency mirrors the walker never enters.
    static let skippedDirectories: Set<String> =
        ["node_modules", "vendor", ".build", "dist", ".git"]

    /// True when any changed path could affect the visible tree under
    /// the root. Paths outside the root — or otherwise unparseable —
    /// count as relevant: when unsure, rescan. FSEvents reports real
    /// (symlink-resolved) paths, so the caller passes the resolved root.
    static func rescanRelevant(changedPaths: [String], resolvedRootPath: String,
                               showHidden: Bool) -> Bool {
        guard !changedPaths.isEmpty else { return true }
        let prefix = resolvedRootPath.hasSuffix("/")
            ? resolvedRootPath : resolvedRootPath + "/"
        for changed in changedPaths {
            // Trailing slashes arrive inconsistently; normalize away.
            let path = changed.hasSuffix("/") ? String(changed.dropLast()) : changed
            if path == resolvedRootPath { return true }
            guard path.hasPrefix(prefix) else { return true }
            let skipped = path.dropFirst(prefix.count).split(separator: "/")
                .contains { component in
                    skippedDirectories.contains(String(component))
                        || (!showHidden && component.hasPrefix("."))
                }
            if !skipped { return true }
        }
        return false
    }
}
