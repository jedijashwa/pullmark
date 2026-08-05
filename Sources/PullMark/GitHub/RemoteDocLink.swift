import Foundation

/// A GitHub URL pointing at a Markdown file — the links PullMark can open
/// in-app instead of bouncing to the browser. Accepts `blob` URLs and
/// raw.githubusercontent.com; everything else (`/tree/`, gists, non-Markdown
/// blobs) stays with the browser.
struct RemoteDocLink: Equatable, Hashable {
    let owner: String
    let repo: String
    /// The ref exactly as it appeared in the URL (branch, tag, or SHA) —
    /// resolved to a commit SHA at fetch time. Branch names containing "/"
    /// can't be told apart from the file path without asking the API, so
    /// the first path segment is taken as the ref.
    let ref: String
    /// Repo-relative file path.
    let path: String
    /// Heading anchor to scroll to after the document loads.
    let fragment: String?

    static func parse(_ url: URL) -> RemoteDocLink? {
        guard let host = url.host?.lowercased() else { return nil }
        // pathComponents percent-decodes and starts with "/".
        let parts = Array(url.pathComponents.dropFirst())
        let fragment = url.fragment.flatMap { $0.isEmpty ? nil : $0 }

        func link(owner: String, repo: String, ref: String, pathParts: ArraySlice<String>) -> RemoteDocLink? {
            let path = pathParts.joined(separator: "/")
            guard !ref.isEmpty, !path.isEmpty,
                  !pathParts.contains(".."),
                  MarkdownFileType.matches((path as NSString).pathExtension),
                  isRepoName(owner), isRepoName(repo)
            else { return nil }
            return RemoteDocLink(owner: owner, repo: repo, ref: ref, path: path, fragment: fragment)
        }

        switch host {
        case "github.com", "www.github.com":
            guard parts.count >= 5, parts[2] == "blob" else { return nil }
            return link(owner: parts[0], repo: parts[1], ref: parts[3], pathParts: parts[4...])
        case "raw.githubusercontent.com":
            guard parts.count >= 4 else { return nil }
            // Modern raw URLs spell the ref as refs/heads/<branch> or
            // refs/tags/<tag>; older ones put the bare ref first.
            if parts.count >= 6, parts[2] == "refs", parts[3] == "heads" || parts[3] == "tags" {
                return link(owner: parts[0], repo: parts[1], ref: parts[4], pathParts: parts[5...])
            }
            return link(owner: parts[0], repo: parts[1], ref: parts[2], pathParts: parts[3...])
        default:
            return nil
        }
    }

    private static func isRepoName(_ s: String) -> Bool {
        !s.isEmpty && s.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" || $0 == "."
        }
    }
}
