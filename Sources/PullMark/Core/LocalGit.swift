import Foundation

/// Read-only git queries for local files (history and branch comparison).
/// All functions shell out to the system git and are safe to call from a
/// background task.
enum LocalGit {
    struct Commit: Equatable, Identifiable {
        let sha: String
        let shortSHA: String
        let date: String
        let subject: String
        var id: String { sha }
    }

    static func repoRoot(for url: URL) -> URL? {
        let dir = url.deletingLastPathComponent().path
        guard let out = run(["rev-parse", "--show-toplevel"], in: dir) else { return nil }
        let path = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
    }

    static func relativePath(of url: URL, in root: URL) -> String {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return url.path.hasPrefix(rootPath) ? String(url.path.dropFirst(rootPath.count)) : url.lastPathComponent
    }

    static func history(of url: URL, limit: Int = 25) -> [Commit] {
        guard let root = repoRoot(for: url) else { return [] }
        let rel = relativePath(of: url, in: root)
        guard let out = run(["log", "--follow", "-n", "\(limit)",
                             "--format=%H%x09%h%x09%ad%x09%s", "--date=short", "--", rel],
                            in: root.path) else { return [] }
        return out.components(separatedBy: "\n").compactMap { line in
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 4 else { return nil }
            return Commit(sha: parts[0], shortSHA: parts[1], date: parts[2],
                          subject: parts[3...].joined(separator: "\t"))
        }
    }

    static func branches(in root: URL, remote: Bool) -> [String] {
        let args = remote
            ? ["branch", "-r", "--format=%(refname:short)"]
            : ["branch", "--format=%(refname:short)"]
        guard let out = run(args, in: root.path) else { return [] }
        return out.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains("HEAD") }
            .prefix(20)
            .map { $0 }
    }

    /// File contents at a ref (commit sha or branch name); nil when the file
    /// doesn't exist there.
    static func content(of url: URL, at ref: String) -> String? {
        guard let root = repoRoot(for: url) else { return nil }
        let rel = relativePath(of: url, in: root)
        return run(["show", "\(ref):\(rel)"], in: root.path)
    }

    /// Per-line blame of the working-tree file; nil when the file is
    /// untracked or not in a repo.
    static func blame(of url: URL) -> [BlameRange]? {
        guard let root = repoRoot(for: url) else { return nil }
        let rel = relativePath(of: url, in: root)
        guard let out = run(["blame", "--porcelain", "--", rel], in: root.path) else { return nil }
        let ranges = parseBlamePorcelain(out)
        return ranges.isEmpty ? nil : ranges
    }

    static func headSHA(in root: URL) -> String? {
        run(["rev-parse", "HEAD"], in: root.path)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// (owner, repo) when the origin remote points at github.com.
    static func githubRemote(in root: URL) -> (owner: String, repo: String)? {
        guard let out = run(["remote", "get-url", "origin"], in: root.path) else { return nil }
        return parseGitHubRemote(out)
    }

    /// Pure parser for `git blame --porcelain` output: header lines carry
    /// "<sha> <origLine> <finalLine> [<groupSize>]"; commit metadata tags
    /// (author, author-time, summary, …) appear only the first time a commit
    /// is seen. Contiguous lines blamed to the same commit coalesce into one
    /// range.
    static func parseBlamePorcelain(_ output: String) -> [BlameRange] {
        struct Partial { var name = "unknown"; var date: Date?; var summary = "" }
        var commits: [String: Partial] = [:]
        var lineSHAs: [(line: Int, sha: String)] = []
        var currentSHA: String?

        for raw in output.components(separatedBy: "\n") {
            if raw.hasPrefix("\t") { continue } // file content line
            let parts = raw.components(separatedBy: " ")
            if parts.count >= 3, parts[0].count == 40,
               parts[0].allSatisfy(\.isHexDigit),
               Int(parts[1]) != nil, let final = Int(parts[2]) {
                currentSHA = parts[0]
                if commits[parts[0]] == nil { commits[parts[0]] = Partial() }
                lineSHAs.append((final, parts[0]))
                continue
            }
            guard let sha = currentSHA else { continue }
            if raw.hasPrefix("author ") {
                commits[sha]?.name = String(raw.dropFirst("author ".count))
            } else if raw.hasPrefix("author-time ") {
                if let t = TimeInterval(raw.dropFirst("author-time ".count)) {
                    commits[sha]?.date = Date(timeIntervalSince1970: t)
                }
            } else if raw.hasPrefix("summary ") {
                commits[sha]?.summary = String(raw.dropFirst("summary ".count))
            }
        }

        var ranges: [BlameRange] = []
        for (line, sha) in lineSHAs.sorted(by: { $0.line < $1.line }) {
            if let last = ranges.last, last.commit.sha == sha, last.end + 1 == line {
                ranges[ranges.count - 1] = BlameRange(start: last.start, end: line,
                                                      commit: last.commit)
            } else {
                let p = commits[sha] ?? Partial()
                ranges.append(BlameRange(start: line, end: line, commit: BlameCommit(
                    sha: sha, authorName: p.name, date: p.date, summary: p.summary
                )))
            }
        }
        return ranges
    }

    /// Pure parser for github.com remote URLs (https, ssh, git@, git://).
    static func parseGitHubRemote(_ remote: String) -> (owner: String, repo: String)? {
        let s = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        let patterns = [
            #"^https?://(?:[^@/\s]+@)?github\.com/([^/\s]+)/([^/\s]+?)(?:\.git)?/?$"#,
            #"^(?:ssh://)?git@github\.com[:/]([^/\s]+)/([^/\s]+?)(?:\.git)?/?$"#,
            #"^git://github\.com/([^/\s]+)/([^/\s]+?)(?:\.git)?/?$"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(s.startIndex..., in: s)
            guard let match = regex.firstMatch(in: s, range: range),
                  let ownerRange = Range(match.range(at: 1), in: s),
                  let repoRange = Range(match.range(at: 2), in: s)
            else { continue }
            return (String(s[ownerRange]), String(s[repoRange]))
        }
        return nil
    }

    private static func run(_ args: [String], in directory: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", directory] + args
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = env
        let stdout = Pipe()
        process.standardOutput = stdout
        // Discard rather than Pipe(): an undrained pipe can fill and
        // deadlock git if it writes enough warnings to stderr.
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Shared segment construction for rendered diffs (PR files and local
/// comparisons): block diff plus word-level markup on modified blocks.
enum DiffPageBuilder {
    static func segments(old: String, new: String) -> [DiffSegmentPayload] {
        let oldBlocks = MarkdownBlocks.split(old)
        let newBlocks = MarkdownBlocks.split(new)
        return BlockDiff.diff(old: oldBlocks, new: newBlocks).map { segment in
            var payload = segment.payload
            if case .modified(let oldBlock, let newBlock) = segment {
                payload.wordDiff = WordDiff.markup(old: oldBlock.text, new: newBlock.text)
            }
            return payload
        }
    }
}
