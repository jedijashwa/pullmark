import Foundation

/// Pure support logic for the in-page inline comment composer (spec §5):
/// which file lines are inside the PR diff (inline validation), the patch
/// view's per-line provenance payload (GitHub-style line-number targeting),
/// and disk persistence for click-away drafts. Non-UI so every rule is
/// unit-testable; the page mirrors the tiny validity/clamp checks in JS.
enum CommentableLines {
    /// Contiguous per-hunk line runs, per side. GitHub review comments must
    /// anchor inside one hunk (context lines included) — a range spanning
    /// hunks is rejected by the API, so a run never crosses one.
    struct Runs: Equatable {
        var right: [ClosedRange<Int>] = []
        var left: [ClosedRange<Int>] = []
    }

    /// Runs straight from the unified-diff hunk headers:
    /// "@@ -a,b +c,d @@" covers old lines a..(a+b-1) and new lines
    /// c..(c+d-1). Counts are optional (default 1); a zero count means the
    /// side has no lines in the hunk.
    static func runs(patch: String) -> Runs {
        let pattern = "^@@ -([0-9]+)(?:,([0-9]+))? \\+([0-9]+)(?:,([0-9]+))? @@"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return Runs() }
        var result = Runs()
        for raw in patch.components(separatedBy: "\n") {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            guard line.hasPrefix("@@"),
                  let match = regex.firstMatch(in: line,
                                               range: NSRange(line.startIndex..., in: line))
            else { continue }
            func group(_ index: Int) -> Int? {
                guard let range = Range(match.range(at: index), in: line) else { return nil }
                return Int(line[range])
            }
            let oldStart = group(1) ?? 0
            let oldCount = group(2) ?? 1
            let newStart = group(3) ?? 0
            let newCount = group(4) ?? 1
            if oldCount > 0 { result.left.append(oldStart...(oldStart + oldCount - 1)) }
            if newCount > 0 { result.right.append(newStart...(newStart + newCount - 1)) }
        }
        return result
    }

    /// A range is commentable iff it sits entirely inside one run — matches
    /// GitHub's rule that multi-line comments cannot span hunks.
    static func isValid(_ range: ClosedRange<Int>, in runs: [ClosedRange<Int>]) -> Bool {
        runs.contains { $0.lowerBound <= range.lowerBound && range.upperBound <= $0.upperBound }
    }

    /// The default anchor clamped into the diff: the largest intersection
    /// of `range` with any single run (ties keep the earlier run), or nil
    /// when the range touches no run at all. Used when a whole-block anchor
    /// pokes outside its hunk's context lines.
    static func clamp(_ range: ClosedRange<Int>,
                      to runs: [ClosedRange<Int>]) -> ClosedRange<Int>? {
        var best: ClosedRange<Int>?
        for run in runs {
            let lower = max(range.lowerBound, run.lowerBound)
            let upper = min(range.upperBound, run.upperBound)
            guard lower <= upper else { continue }
            if best == nil || (upper - lower) > (best!.upperBound - best!.lowerBound) {
                best = lower...upper
            }
        }
        return best
    }

    /// The page's copy of the runs: [[start, end], …] per side.
    struct Payload: Encodable, Equatable {
        let right: [[Int]]
        let left: [[Int]]
    }

    static func payload(patch: String?) -> Payload? {
        guard let patch, !patch.isEmpty else { return nil }
        let runs = runs(patch: patch)
        guard !runs.right.isEmpty || !runs.left.isEmpty else { return nil }
        return Payload(right: runs.right.map { [$0.lowerBound, $0.upperBound] },
                       left: runs.left.map { [$0.lowerBound, $0.upperBound] })
    }
}

/// One patch line's file provenance for the Source Diff view's line-number
/// gutter: clicking (and shift-clicking) these numbers sets the composer's
/// range, GitHub-style. Same origins as the gutter badges (PatchAnchors).
struct PatchLinePayload: Encodable, Equatable {
    /// 0-based index into the patch's lines.
    let index: Int
    let old: Int?
    let new: Int?
}

enum PatchComposerLines {
    static func payloads(patch: String) -> [PatchLinePayload] {
        PatchAnchors.lineOrigins(patch: patch).map {
            PatchLinePayload(index: $0.index, old: $0.oldLine, new: $0.newLine)
        }
    }
}

extension PRSession {
    /// Whether a review is in progress for composer labeling (spec §5):
    /// primary reads "Add review comment" once a pending review exists on
    /// GitHub — or comments are queued toward one (offline counts; the
    /// queue becomes that review on sync).
    var reviewInProgress: Bool {
        pendingReview != nil || !queuedComments.isEmpty
    }
}

/// Click-away drafts for the in-page composers (spec §5: clicking outside
/// preserves the typed text on that block; Cancel discards). Persisted in
/// the app's existing UserDefaults domain so drafts survive relaunch.
///
/// Keys pair the page's own draft key (block-shaped: "RIGHT:12-14", or
/// "reply:<rootID>") with the PR context: line-anchored drafts include the
/// head SHA (anchors are only valid against the head they were authored
/// on); reply drafts target a thread, not lines, so they survive head
/// moves.
enum ComposerDraftStore {
    struct StoredDraft: Codable, Equatable {
        var text: String
        var savedAt: Date
    }

    static let maxDrafts = 100
    private static let replyPrefix = "reply:"

    static func storageKey(ref: PullRequestRef, headSHA: String,
                           path: String, jsKey: String) -> String {
        let pr = "\(ref.owner)/\(ref.repo)#\(ref.number)"
        return jsKey.hasPrefix(replyPrefix)
            ? "\(pr)|\(path)|\(jsKey)"
            : "\(pr)@\(headSHA)|\(path)|\(jsKey)"
    }

    // Pure encode/decode/update over the stored set (unit-tested); the
    // UserDefaults accessors below stay thin shims over them.

    static func decode(_ data: Data?) -> [String: StoredDraft] {
        guard let data,
              let decoded = try? JSONDecoder().decode([String: StoredDraft].self, from: data)
        else { return [:] }
        return decoded
    }

    static func encode(_ drafts: [String: StoredDraft]) -> Data? {
        try? JSONEncoder().encode(drafts)
    }

    /// One draft update applied to the stored set: empty text drops the
    /// key, and the set is capped oldest-first so abandoned drafts can't
    /// grow unbounded.
    static func updated(_ drafts: [String: StoredDraft], key: String,
                        text: String, now: Date = Date()) -> [String: StoredDraft] {
        var result = drafts
        if text.isEmpty {
            result[key] = nil
        } else {
            result[key] = StoredDraft(text: text, savedAt: now)
        }
        while result.count > maxDrafts {
            guard let oldest = result.min(by: { $0.value.savedAt < $1.value.savedAt })
            else { break }
            result[oldest.key] = nil
        }
        return result
    }

    /// Drafts for one file of one PR at one head, keyed by the page's own
    /// draft keys — the shape __pmSetComposerDrafts consumes.
    static func drafts(in stored: [String: StoredDraft], ref: PullRequestRef,
                       headSHA: String, path: String) -> [String: String] {
        let pr = "\(ref.owner)/\(ref.repo)#\(ref.number)"
        let linePrefix = "\(pr)@\(headSHA)|\(path)|"
        let replyKeyPrefix = "\(pr)|\(path)|\(replyPrefix)"
        var result: [String: String] = [:]
        for (key, draft) in stored {
            if key.hasPrefix(linePrefix) {
                result[String(key.dropFirst(linePrefix.count))] = draft.text
            } else if key.hasPrefix(replyKeyPrefix) {
                result[replyPrefix + String(key.dropFirst(replyKeyPrefix.count))] = draft.text
            }
        }
        return result
    }

    static func save(jsKey: String, text: String, ref: PullRequestRef,
                     headSHA: String, path: String) {
        let stored = decode(UserDefaults.standard.data(forKey: DefaultsKeys.composerDrafts))
        let updated = updated(stored,
                              key: storageKey(ref: ref, headSHA: headSHA, path: path, jsKey: jsKey),
                              text: text)
        UserDefaults.standard.set(encode(updated), forKey: DefaultsKeys.composerDrafts)
    }

    static func load(ref: PullRequestRef, headSHA: String, path: String) -> [String: String] {
        drafts(in: decode(UserDefaults.standard.data(forKey: DefaultsKeys.composerDrafts)),
               ref: ref, headSHA: headSHA, path: path)
    }
}
