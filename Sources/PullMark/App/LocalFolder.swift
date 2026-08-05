import Foundation

/// An opened folder root in the sidebar — a closeable place being
/// browsed, distinct from the individually opened documents in Files
/// (spec §1). The tree is the scan result; expansion and view mode
/// persist per root in the session snapshot.
struct LocalFolder: Identifiable, Equatable {
    enum ViewMode: String, Codable {
        case tree
        case list
    }

    let rootURL: URL
    var nodes: [PathTree.Node] = []
    /// Root-relative paths of every scanned file, in tree order — feeds
    /// the flat List view, ⌘K, and ⇧⌘F without re-walking the tree.
    var filePaths: [String] = []
    var truncated = false
    /// The root path itself is gone (unmounted volume, deleted checkout).
    /// The row dims like a dead recent and revives when the path returns.
    var missing = false
    var scanning = false
    var viewMode: ViewMode = .tree
    var expandedPaths: Set<String> = []
    /// Git identity of the root, computed off-main at open/rescan and on
    /// app activation — never during rendering. Nil outside a repo.
    var git: LocalGit.RepoInfo?

    var id: URL { rootURL }
    var displayName: String { rootURL.lastPathComponent }

    func fileURL(for relativePath: String) -> URL {
        rootURL.appendingPathComponent(relativePath)
    }
}
