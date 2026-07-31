import Foundation

/// Pure placement/visibility logic for review-conversation surfaces outside
/// the rendered diff: Result-view thread markers, Source Diff gutter
/// badges, sidebar comment counts, and pending-comment anchors (spec §1–§3).
/// Non-UI so every rule is unit-testable.
enum ThreadVisibility {
    /// Threads eligible for Result-view markers: anchored, live, new-side.
    /// Old-side, outdated, and file-level threads never mark prose — they
    /// stay in the diff views and count toward presence signals only. The
    /// payloads carry the anchor line range; the page maps it onto rendered
    /// blocks via their data-pm-lines annotations (containment only, no
    /// nearest-block guessing — a misanchored highlight in a reading view
    /// is worse than an absent one).
    static func resultAnchored(_ threads: [ReviewThread],
                               meta: [Int: ThreadMeta]) -> [ThreadPayload] {
        threads.compactMap { thread in
            guard !thread.isFileLevel, !thread.isOutdated,
                  let line = thread.anchorLine, thread.anchorSide == "RIGHT" else { return nil }
            return ThreadPayload(
                lineLabel: thread.lineLabel,
                comments: thread.comments.map(CommentPayload.init),
                rootID: thread.root.id,
                resolved: meta[thread.root.id]?.isResolved,
                anchorStart: min(thread.root.startLine ?? line, line),
                anchorEnd: line
            )
        }
    }

    /// Per-path comment counts for the sidebar badges: every comment in an
    /// unresolved thread, including outdated, old-side, and file-level ones
    /// — nothing is silently missing (spec §2).
    static func unresolvedCommentCounts(comments: [ReviewComment],
                                        meta: [Int: ThreadMeta]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for thread in ReviewThreads.group(comments)
        where meta[thread.root.id]?.isResolved != true {
            counts[thread.path, default: 0] += thread.comments.count
        }
        return counts
    }

    /// Review comments on files PullMark does not show (non-Markdown files)
    /// — the PR overview's honesty line (spec §2).
    static func hiddenFileCommentCount(comments: [ReviewComment],
                                       visiblePaths: Set<String>) -> Int {
        comments.filter { !visiblePaths.contains($0.path) }.count
    }

    /// The viewer's pending comments that can anchor in this file's Result
    /// view (new-side only — the Result view has no old side).
    static func resultPending(_ pending: [PendingComment],
                              path: String) -> [PendingPayload] {
        pending.filter { $0.path == path && $0.side == "RIGHT" }.map(PendingPayload.init)
    }
}

/// A pending review comment as the web layer renders it at its anchor —
/// always with the yellow Pending tag, never with thread actions
/// (Reply/Resolve act on published comments only).
struct PendingPayload: Encodable, Equatable {
    let lineStart: Int
    let lineEnd: Int
    let side: String
    let lineLabel: String
    let body: String
    /// False while the comment is queued locally and GitHub hasn't
    /// accepted it yet ("Not uploaded" in the review popover).
    let uploaded: Bool

    init(_ comment: PendingComment) {
        lineStart = comment.lineStart
        lineEnd = comment.lineEnd
        side = comment.side
        let which = comment.side == "LEFT" ? "old" : "new"
        lineLabel = comment.lineStart == comment.lineEnd
            ? "Line \(comment.lineEnd) (\(which))"
            : "Lines \(comment.lineStart)–\(comment.lineEnd) (\(which))"
        body = comment.body
        uploaded = comment.serverID != nil
    }
}

/// Anchors pending comments onto rendered-diff segments (spec §3: pending
/// comments appear at their anchors). Containment only — an unplaceable
/// pending comment stays visible in the review popover, never guessed into
/// the prose.
enum PendingAnchors {
    static func place(_ pending: [PendingComment],
                      in segments: [DiffSegmentPayload]) -> [DiffSegmentPayload] {
        var annotated = segments
        for comment in pending {
            let line = comment.lineEnd
            let match: Int?
            if comment.side == "LEFT" {
                // Old-file line numbers match old-side ranges only — same
                // discipline as ReviewThreads.place.
                match = annotated.firstIndex { segment in
                    if segment.side == "LEFT",
                       segment.lineStart <= line, line <= segment.lineEnd {
                        return true
                    }
                    if let start = segment.oldLineStart {
                        return start <= line && line <= (segment.oldLineEnd ?? start)
                    }
                    return false
                }
            } else {
                match = annotated.firstIndex {
                    $0.side == "RIGHT" && $0.lineStart <= line && line <= $0.lineEnd
                }
            }
            guard let index = match else { continue }
            if annotated[index].pending == nil { annotated[index].pending = [] }
            annotated[index].pending?.append(PendingPayload(comment))
        }
        return annotated
    }
}

/// One commented patch line in the Source Diff view: the 0-based index into
/// the patch's lines, plus the threads and pending comments anchored there.
struct PatchThreadPayload: Encodable, Equatable {
    let lineIndex: Int
    var threads: [ThreadPayload] = []
    var pending: [PendingPayload] = []
}

/// Maps review threads and pending comments onto raw patch lines for the
/// Source Diff gutter badges (spec §1, last bullet). All parsing is pure:
/// hunk headers give each patch line its old/new file line number, and
/// anchors match by (side, line) exactly — no guessing.
enum PatchAnchors {
    struct LineOrigin: Equatable {
        let index: Int
        let oldLine: Int?
        let newLine: Int?
    }

    /// The file-line provenance of every content line in the patch.
    /// CR is stripped before matching so CRLF patches behave (the rendered
    /// patch view shows the raw text either way).
    static func lineOrigins(patch: String) -> [LineOrigin] {
        var origins: [LineOrigin] = []
        var oldLine = 0
        var newLine = 0
        var inHunk = false
        for (index, raw) in patch.components(separatedBy: "\n").enumerated() {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if line.hasPrefix("@@") {
                guard let starts = hunkStarts(line) else { inHunk = false; continue }
                oldLine = starts.old
                newLine = starts.new
                inHunk = true
                continue
            }
            guard inHunk else { continue }
            if line.hasPrefix("+") {
                origins.append(LineOrigin(index: index, oldLine: nil, newLine: newLine))
                newLine += 1
            } else if line.hasPrefix("-") {
                origins.append(LineOrigin(index: index, oldLine: oldLine, newLine: nil))
                oldLine += 1
            } else if line.hasPrefix("\\") {
                // "\ No newline at end of file" — not a file line.
                continue
            } else {
                origins.append(LineOrigin(index: index, oldLine: oldLine, newLine: newLine))
                oldLine += 1
                newLine += 1
            }
        }
        return origins
    }

    /// "@@ -a,b +c,d @@" → (a, c); counts are optional in unified diffs.
    private static func hunkStarts(_ line: String) -> (old: Int, new: Int)? {
        let pattern = "^@@ -([0-9]+)(?:,[0-9]+)? \\+([0-9]+)(?:,[0-9]+)? @@"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line,
                                           range: NSRange(line.startIndex..., in: line)),
              let oldRange = Range(match.range(at: 1), in: line),
              let newRange = Range(match.range(at: 2), in: line),
              let old = Int(line[oldRange]),
              let new = Int(line[newRange]) else { return nil }
        return (old, new)
    }

    /// Attaches threads (live, line-anchored) and pending comments to the
    /// patch lines they target. File-level and outdated threads have no
    /// patch line and are excluded here (they are counted in the presence
    /// signals instead). Rows come back sorted by line index.
    static func place(threads: [ReviewThread], meta: [Int: ThreadMeta],
                      pending: [PendingComment], patch: String) -> [PatchThreadPayload] {
        let origins = lineOrigins(patch: patch)

        func lineIndex(side: String, line: Int) -> Int? {
            if side == "LEFT" {
                return origins.first { $0.oldLine == line }?.index
            }
            return origins.first { $0.newLine == line }?.index
        }

        var rows: [Int: PatchThreadPayload] = [:]
        for thread in threads {
            guard !thread.isFileLevel, let line = thread.anchorLine,
                  let index = lineIndex(side: thread.anchorSide, line: line) else { continue }
            var row = rows[index] ?? PatchThreadPayload(lineIndex: index)
            row.threads.append(ThreadPayload(
                lineLabel: thread.lineLabel,
                comments: thread.comments.map(CommentPayload.init),
                rootID: thread.root.id,
                resolved: meta[thread.root.id]?.isResolved
            ))
            rows[index] = row
        }
        for comment in pending {
            guard let index = lineIndex(side: comment.side, line: comment.lineEnd) else { continue }
            var row = rows[index] ?? PatchThreadPayload(lineIndex: index)
            row.pending.append(PendingPayload(comment))
            rows[index] = row
        }
        return rows.values.sorted { $0.lineIndex < $1.lineIndex }
    }
}
