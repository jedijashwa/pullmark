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

    /// The canonical github.com page for a file at a ref — the inverse of
    /// `parse` for the plain-blob form, and the link a person actually
    /// wants shared. Never a raw URL: raw.githubusercontent.com is
    /// cookieless and renders nothing in private repos.
    static func blobURL(owner: String, repo: String, ref: String, path: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "github.com"
        components.path = "/\(owner)/\(repo)/blob/\(ref)/\(path)"
        return components.url
    }

    /// Whether a ref (as the user's link spelled it) names a commit — an
    /// abbreviated or full hex object name. A branch or tag can move
    /// underneath a session, so reload re-resolves it; a commit is
    /// immutable and reload has nothing to do. Heuristic by necessity:
    /// git itself can't tell a 7-hex-char branch name from a short SHA
    /// without asking the repo.
    static func isCommitSHA(_ ref: String) -> Bool {
        (7...40).contains(ref.count) && ref.allSatisfy(\.isHexDigit)
    }
}
