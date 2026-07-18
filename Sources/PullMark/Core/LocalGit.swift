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

    private static func run(_ args: [String], in directory: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", directory] + args
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = env
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
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
