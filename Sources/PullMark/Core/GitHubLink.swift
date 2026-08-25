import Foundation

/// Assembles github.com URLs for local checkout content (spec:
/// copy-github-link). Pure string work — resolution (branch, remote,
/// HEAD SHA) happens in LocalGit at click time, never here.
enum GitHubLink {
    /// `blob/<ref>/<path>` for files, `tree/<ref>/<path>` for
    /// directories, and the bare `tree/<ref>` for the repo root (empty
    /// path). Every segment is percent-encoded; slashes inside branch
    /// names and paths stay verbatim — GitHub resolves ref/path
    /// greedily, so `feature/foo` links work as typed.
    static func url(owner: String, repo: String, ref: String,
                    path: String, isDirectory: Bool) -> String {
        var out = "https://github.com/" + encode(owner) + "/" + encode(repo)
        out += isDirectory ? "/tree/" : "/blob/"
        out += encodeKeepingSlashes(ref)
        if !path.isEmpty {
            out += "/" + encodeKeepingSlashes(path)
        }
        return out
    }

    /// Whether `url` lives inside a git checkout: some ancestor holds a
    /// `.git` entry — a directory for clones, a FILE for linked
    /// worktrees, and both count. A pure filesystem walk, cheap enough
    /// to run while building a context menu (which SwiftUI evaluates at
    /// ROW RENDER, not menu open); the git subprocesses wait for an
    /// actual click.
    ///
    /// The walk runs on path STRINGS, deliberately. URL-based walking
    /// hung the app: AppKit hands out NSURL-backed URLs, and NSURL's
    /// deletingLastPathComponent never stops at "/" — it appends "../"
    /// forever (Swift-native URLs clamp, which is why unit tests passed
    /// while the sidebar beachballed). NSString's path API is a true
    /// fixed point at the root.
    static func inRepository(_ url: URL, isDirectory: Bool) -> Bool {
        nearestRepoRoot(url, isDirectory: isDirectory) != nil
    }

    /// The nearest checkout root: the CLOSEST ancestor holding a `.git`
    /// entry, as a standardized path string. "Nearest" matters — a
    /// nested checkout or submodule file belongs to the inner repo, and
    /// the click-time resolution (git rev-parse from the file's own
    /// directory) agrees with this walk on which repo that is.
    static func nearestRepoRoot(_ url: URL, isDirectory: Bool) -> String? {
        let fm = FileManager.default
        let start = isDirectory ? url.path : (url.path as NSString).deletingLastPathComponent
        var dir = (start as NSString).standardizingPath
        while true {
            if fm.fileExists(atPath: (dir as NSString).appendingPathComponent(".git")) {
                return dir
            }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir { return nil }
            dir = parent
        }
    }

    /// Whether a row should offer Copy GitHub Link, given what the
    /// index tracks (spec: copy-github-link §3). Untracked and ignored
    /// content has no page on GitHub, so the item stays out of the
    /// menu. Nil sets mean the tracked list isn't known (no opened
    /// folder covers this repo, or it was too large to hold) — offer
    /// the item and let the click resolve, which is the pre-cache
    /// behavior. The repo root itself always links (bare tree/<ref>).
    static func offersLink(relativePath: String, isDirectory: Bool,
                           trackedFiles: Set<String>?, trackedDirs: Set<String>?) -> Bool {
        guard let trackedFiles, let trackedDirs else { return true }
        if relativePath.isEmpty { return true }
        return isDirectory ? trackedDirs.contains(relativePath)
                           : trackedFiles.contains(relativePath)
    }

    /// Unreserved characters only — everything else, including "/",
    /// percent-encodes. Segments that need their slashes call
    /// `encodeKeepingSlashes`.
    private static let segmentAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func encode(_ segment: String) -> String {
        segment.addingPercentEncoding(withAllowedCharacters: segmentAllowed) ?? segment
    }

    private static func encodeKeepingSlashes(_ value: String) -> String {
        value.split(separator: "/", omittingEmptySubsequences: false)
            .map { encode(String($0)) }
            .joined(separator: "/")
    }
}
