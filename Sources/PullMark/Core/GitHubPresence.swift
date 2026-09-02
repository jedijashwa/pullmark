import Foundation

/// Whether a path in a checkout has a page on GitHub, and if not, why
/// (spec: copy-github-link §8). Pure: the index is built by LocalGit
/// off the main thread from git's own answers; classification is a
/// few set lookups, cheap enough for a context-menu builder that
/// SwiftUI evaluates at row render.
enum GitHubPresence {
    /// Where an ignore rule came from — the two subtitles differ
    /// because the fix differs (edit the repo's .gitignore vs. your own
    /// excludes).
    enum IgnoreSource: Equatable {
        case gitignore
        case local
    }

    enum Reason: Equatable {
        case ignoredByGitignore
        case ignoredLocally
        /// Untracked, or added to the index but not yet in a commit.
        case notCommitted
        /// In a commit the remote doesn't have — or on a branch the
        /// remote doesn't have at all.
        case notPushed
    }

    enum State: Equatable {
        case onGitHub
        case absent(Reason)
        /// No index for this checkout (no opened folder covers it, or
        /// git couldn't answer): offer the item and let the click check.
        case unknown
    }

    /// One checkout's answers, all paths toplevel-relative. A reference
    /// type compared by fingerprint, so `RepoInfo`/`LocalFolder`
    /// equality — and SwiftUI's diffing on every activation heartbeat —
    /// never walks the sets. That comparison cost is why trackedness
    /// used to stop at 50,000 files; the fingerprint is hashed once, off
    /// main, from git's raw output.
    final class Index: Equatable {
        let trackedFiles: Set<String>
        /// Every ancestor directory of a tracked file (git tracks no
        /// directories itself).
        let trackedDirs: Set<String>
        /// In the index but not in HEAD.
        let stagedNew: Set<String>
        /// Added in commits the upstream doesn't have.
        let unpushed: Set<String>
        /// No upstream at all: every path on this branch is unpushed.
        let branchUnpushed: Bool
        /// Ignored paths among the ones the caller asked about (the
        /// sidebar's Markdown files) and which rule family ignored them.
        let ignored: [String: IgnoreSource]
        let fingerprint: Int

        init(trackedFiles: Set<String>, trackedDirs: Set<String>,
             stagedNew: Set<String> = [], unpushed: Set<String> = [],
             branchUnpushed: Bool = false, ignored: [String: IgnoreSource] = [:],
             fingerprint: Int) {
            self.trackedFiles = trackedFiles
            self.trackedDirs = trackedDirs
            self.stagedNew = stagedNew
            self.unpushed = unpushed
            self.branchUnpushed = branchUnpushed
            self.ignored = ignored
            self.fingerprint = fingerprint
        }

        static func == (lhs: Index, rhs: Index) -> Bool {
            lhs === rhs || lhs.fingerprint == rhs.fingerprint
        }
    }

    /// The repo root itself always links (bare tree/<ref>). Directories
    /// are on GitHub when any tracked file lives under them — the index
    /// approximation the menu has used since §3; files get the full
    /// reason ladder: ignored → not committed → not pushed → on GitHub.
    static func classify(relativePath: String, isDirectory: Bool, index: Index?) -> State {
        guard let index else { return .unknown }
        if relativePath.isEmpty { return .onGitHub }
        if isDirectory {
            return index.trackedDirs.contains(relativePath) ? .onGitHub : .absent(.notCommitted)
        }
        if let source = index.ignored[relativePath] {
            return .absent(source == .gitignore ? .ignoredByGitignore : .ignoredLocally)
        }
        if !index.trackedFiles.contains(relativePath) || index.stagedNew.contains(relativePath) {
            return .absent(.notCommitted)
        }
        if index.branchUnpushed || index.unpushed.contains(relativePath) {
            return .absent(.notPushed)
        }
        return .onGitHub
    }

    /// Pure parser for `git check-ignore -v -z --stdin`: NUL-separated
    /// quads `<source> <linenum> <pattern> <path>`; paths git does not
    /// ignore are simply absent. The source is a `.gitignore` somewhere
    /// in the tree (repo rules) or anything else — `.git/info/exclude`,
    /// the global excludes file — which is the user's own machine.
    static func parseCheckIgnore(_ output: String) -> [String: IgnoreSource] {
        let fields = output.split(separator: "\0", omittingEmptySubsequences: false)
        var result: [String: IgnoreSource] = [:]
        var index = 0
        while index + 3 < fields.count {
            let source = String(fields[index])
            let path = String(fields[index + 3])
            index += 4
            guard !path.isEmpty else { continue }
            let isRepoRule = source == ".gitignore" || source.hasSuffix("/.gitignore")
            result[path] = isRepoRule ? .gitignore : .local
        }
        return result
    }

    /// Pure parser for NUL-separated path lists (`git diff --name-only
    /// -z`, `ls-files -z`): empty entries dropped.
    static func parsePathList(_ output: String) -> Set<String> {
        Set(output.split(separator: "\0").map(String.init).filter { !$0.isEmpty })
    }
}
