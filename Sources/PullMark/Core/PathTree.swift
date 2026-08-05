import Foundation

/// Builds the sidebar's file trees from slash-separated relative paths —
/// shared by folder roots and PR file lists (spec §2/§3). Pure and
/// order-independent so it stays unit-testable:
/// - directories before files, case-insensitive name sort
/// - single-child directory chains compress into one node ("docs/en"),
///   GitHub-style, so depth stays honest
/// - directories exist only because a file path runs through them, so
///   empty directories are pruned by construction
enum PathTree {
    struct Node: Identifiable, Equatable {
        /// Display name — one component, or a compressed "a/b" chain.
        var name: String
        /// Full relative path of this node from the tree root.
        var path: String
        /// Nil for directories; the original path payload for files.
        var filePath: String?
        var children: [Node]

        var id: String { (filePath == nil ? "dir:" : "file:") + path }
        var isDirectory: Bool { filePath == nil }
    }

    /// Builds a sorted, compressed tree. `paths` are relative,
    /// slash-separated file paths; duplicates collapse.
    static func build(_ paths: [String]) -> [Node] {
        var root = MutableNode(name: "", path: "")
        for path in Set(paths) {
            let components = path.split(separator: "/").map(String.init)
            guard !components.isEmpty else { continue }
            var cursor = root
            var walked: [String] = []
            for component in components.dropLast() {
                walked.append(component)
                cursor = cursor.child(component, path: walked.joined(separator: "/"))
            }
            cursor.files.append((components.last!, path))
        }
        let nodes = finalize(root)
        root = MutableNode(name: "", path: "") // break cycles for ARC clarity
        return nodes
    }

    /// The file paths of every leaf under a node, in tree order.
    /// GitHub's rule for what a place shows by default: the directory's
    /// README (any case, any Markdown extension), else its index file,
    /// else nothing. `directory` is a root-relative path ("" = the root);
    /// only that directory's own files are considered, never descendants.
    static func readmePath(in paths: [String], directory: String = "") -> String? {
        let prefix = directory.isEmpty ? "" : directory + "/"
        let ownFiles = paths.filter {
            $0.hasPrefix(prefix) && !$0.dropFirst(prefix.count).contains("/")
        }
        func match(_ base: String) -> String? {
            ownFiles.first {
                let name = (($0 as NSString).lastPathComponent as NSString).deletingPathExtension
                return name.caseInsensitiveCompare(base) == .orderedSame
            }
        }
        return match("README") ?? match("index")
    }

    static func leafPaths(_ node: Node) -> [String] {
        if let filePath = node.filePath { return [filePath] }
        return node.children.flatMap(leafPaths)
    }

    // MARK: - Internals

    private final class MutableNode {
        let name: String
        let path: String
        var directories: [String: MutableNode] = [:]
        var files: [(name: String, path: String)] = []

        init(name: String, path: String) {
            self.name = name
            self.path = path
        }

        func child(_ name: String, path: String) -> MutableNode {
            if let existing = directories[name] { return existing }
            let node = MutableNode(name: name, path: path)
            directories[name] = node
            return node
        }
    }

    private static func finalize(_ node: MutableNode) -> [Node] {
        let dirs = node.directories.values
            .map(compress)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let files = node.files
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { Node(name: $0.name, path: $0.path, filePath: $0.path, children: []) }
        return dirs + files
    }

    /// A directory whose only content is one subdirectory merges with it.
    private static func compress(_ node: MutableNode) -> Node {
        var name = node.name
        var cursor = node
        while cursor.files.isEmpty, cursor.directories.count == 1,
              let only = cursor.directories.values.first {
            name += "/" + only.name
            cursor = only
        }
        return Node(name: name, path: cursor.path, filePath: nil,
                    children: finalize(cursor))
    }
}
