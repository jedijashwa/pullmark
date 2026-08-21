import Foundation
import Testing
@testable import PullMark

/// The demo fixture (PM_DEMO=1) is committed data, so its internal
/// consistency is enforced here: patches splice cleanly against the doc
/// texts, every anchor lands on real content, pending counts and states
/// are what the UI advertises, and authors/meta agree everywhere.
@Suite struct DemoSessionTests {
    // MARK: - Gate

    @Test func gateActivatesOnExactlyPMDemo1() {
        #expect(DemoMode.isActive(environment: ["PM_DEMO": "1"]))
        #expect(!DemoMode.isActive(environment: [:]))
        #expect(!DemoMode.isActive(environment: ["PM_DEMO": "0"]))
        #expect(!DemoMode.isActive(environment: ["PM_DEMO": "true"]))
    }

    @Test func demoDefaultsSuiteIsNotTheRealDomain() {
        #expect(DemoMode.defaultsSuiteName != "app.pullmark.PullMark")
        // Per-process since the parallel screenshot generator: shared
        // demo suites let one instance's startup wipe reset another's
        // live state (see DemoMode.defaultsSuiteName).
        #expect(DemoMode.defaultsSuiteName.hasPrefix("app.pullmark.PullMark.demo."))
        #expect(Int32(DemoMode.defaultsSuiteName.split(separator: ".").last ?? "") != nil)
    }

    // MARK: - Patch / document consistency

    private func lines(_ text: String) -> [String] {
        text.components(separatedBy: "\n")
    }

    /// Every hunk line in a demo patch must reproduce the exact text of
    /// the head (new side) and base (old side) documents at the line
    /// numbers the hunk headers claim — the same invariant a real GitHub
    /// patch has by construction.
    @Test func patchesSpliceCleanlyAgainstTheDocTexts() throws {
        for file in DemoSession.files where file.isMarkdown {
            let patch = try #require(file.patch, "\(file.filename) has no patch")
            let head = lines(try #require(DemoSession.fileContent(
                path: file.filename, at: DemoSession.headSHA)))
            let base = file.status == "added"
                ? []
                : lines(try #require(DemoSession.fileContent(
                    path: file.filename, at: DemoSession.baseSHA)))
            let origins = PatchAnchors.lineOrigins(patch: patch)
            #expect(!origins.isEmpty, "\(file.filename): patch parsed to no lines")
            let patchLines = lines(patch)
            for origin in origins {
                let content = String(patchLines[origin.index].dropFirst())
                if let new = origin.newLine {
                    #expect(new >= 1 && new <= head.count,
                            "\(file.filename): new line \(new) outside the head doc")
                    #expect(head[new - 1] == content,
                            "\(file.filename): head line \(new) diverges from the patch")
                }
                if let old = origin.oldLine {
                    #expect(old >= 1 && old <= base.count,
                            "\(file.filename): old line \(old) outside the base doc")
                    #expect(base[old - 1] == content,
                            "\(file.filename): base line \(old) diverges from the patch")
                }
            }
        }
    }

    // MARK: - Thread anchors

    private var threads: [ReviewThread] {
        ReviewThreads.group(DemoSession.reviewComments)
    }

    @Test func liveThreadAnchorsLandOnRenderedBlocks() throws {
        let visiblePaths = Set(DemoSession.files.filter(\.isMarkdown).map(\.filename))
        for thread in threads where !thread.isOutdated && !thread.isFileLevel {
            guard visiblePaths.contains(thread.path) else { continue }
            let line = try #require(thread.anchorLine)
            let head = try #require(DemoSession.fileContent(path: thread.path,
                                                            at: DemoSession.headSHA))
            let blocks = MarkdownBlocks.split(head)
            #expect(blocks.contains { $0.startLine <= line && line <= $0.endLine },
                    "\(thread.path):\(line) is not inside any rendered block — the Result-view marker would not attach")
        }
    }

    @Test func stagedThreadStatesAreAllPresent() {
        let grouped = threads
        // One multi-comment thread with a reply.
        #expect(grouped.contains { $0.replies.count == 1
            && $0.root.id == DemoSession.threadReplyRootID })
        // One resolved.
        #expect(DemoSession.threadMeta[DemoSession.threadResolvedRootID]?.isResolved == true)
        // One outdated (line dropped, originalLine kept).
        let outdated = grouped.first { $0.root.id == DemoSession.threadOutdatedRootID }
        #expect(outdated?.isOutdated == true)
        // One edited comment.
        #expect(DemoSession.threadMeta[DemoSession.threadReplyRootID]?
            .comments[DemoSession.threadReplyRootID]?.edited == true)
        // Result view markers exist for the calibration doc.
        let calibrationThreads = grouped.filter { $0.path == DemoSession.calibrationPath }
        let payloads = ThreadVisibility.resultAnchored(calibrationThreads,
                                                       meta: DemoSession.threadMeta,
                                                       viewer: DemoSession.viewerLogin)
        #expect(!payloads.isEmpty)
    }

    @Test func reactionsAreVariedAndViewerStateIsConsistent() throws {
        let byID = Dictionary(uniqueKeysWithValues:
            DemoSession.reviewComments.map { ($0.id, $0) })
        var viewerOwnedSeen = false
        for (rootID, meta) in DemoSession.threadMeta {
            for (commentID, commentMeta) in meta.comments {
                let comment = try #require(byID[commentID],
                    "meta for unknown comment \(commentID) under root \(rootID)")
                let rollup = comment.reactions ?? ReactionRollup()
                for content in commentMeta.viewerReacted {
                    viewerOwnedSeen = true
                    #expect(ReactionKind(rawValue: content) != nil,
                            "comment \(commentID): unknown reaction \(content)")
                    // A viewer-owned reaction must be included in the rollup.
                    let chips = CommentReactions.chips(rollup: rollup,
                                                       viewerReacted: commentMeta.viewerReacted)
                    #expect(chips.contains { $0.content == content && $0.mine && $0.count >= 1 },
                            "comment \(commentID): viewer reacted \(content) but the rollup disagrees")
                }
            }
        }
        #expect(viewerOwnedSeen, "no viewer-owned reaction staged")
        // Reactions vary across comments (not one repeated shape).
        let rollups = DemoSession.reviewComments.compactMap(\.reactions)
        #expect(Set(rollups.map { "\($0)" }).count >= 3)
    }

    @Test func threadMetaKeysMatchGroupedRoots() {
        let roots = Set(threads.map(\.root.id))
        #expect(Set(DemoSession.threadMeta.keys) == roots)
        // Every comment id in a thread's meta belongs to that thread.
        for thread in threads {
            guard let meta = DemoSession.threadMeta[thread.root.id] else { continue }
            let members = Set(thread.comments.map(\.id))
            #expect(Set(meta.comments.keys).isSubset(of: members))
        }
    }

    // MARK: - Pending review

    @Test func pendingCountsAndUploadStatesMatchTheControl() {
        let session = DemoSession.makeSession()
        #expect(session.pendingComments.count == 3)
        #expect(ReviewControl.buttonLabel(pendingCount: session.pendingComments.count)
            == "Finish your review · 3")
        // Mixed states: uploaded (Pending tag) and queued (Not uploaded).
        #expect(session.pendingReview?.comments.allSatisfy { $0.serverID != nil } == true)
        #expect(session.queuedComments.allSatisfy { $0.serverID == nil })
        #expect(!session.queuedComments.isEmpty)
        #expect(session.reviewInProgress)
        #expect(session.pendingReview?.summary?.isEmpty == false)
    }

    @Test func pendingAnchorsAreCommentableAndRenderable() throws {
        let session = DemoSession.makeSession()
        let filesByPath = Dictionary(uniqueKeysWithValues:
            session.files.map { ($0.filename, $0) })
        for comment in session.pendingComments {
            let file = try #require(filesByPath[comment.path],
                                    "pending comment on unknown file \(comment.path)")
            #expect(file.isMarkdown)
            // Inside the diff (GitHub would reject it otherwise).
            let runs = CommentableLines.runs(patch: try #require(file.patch))
            #expect(CommentableLines.isValid(comment.lineStart...comment.lineEnd,
                                             in: runs.right),
                    "\(comment.path):\(comment.lineStart)–\(comment.lineEnd) not commentable")
            // On a rendered block (the Result view shows pending markers).
            let head = try #require(DemoSession.fileContent(path: comment.path,
                                                            at: DemoSession.headSHA))
            let blocks = MarkdownBlocks.split(head)
            #expect(blocks.contains {
                $0.startLine <= comment.lineEnd && comment.lineEnd <= $0.endLine
            })
        }
    }

    // MARK: - Session shape

    @Test func sessionCountsMatchTheOverviewCopy() {
        let session = DemoSession.makeSession()
        #expect(session.markdownFiles.count == 3)
        #expect(session.otherFileCount == 1)
        // The hidden-file honesty line has something to count.
        #expect(ThreadVisibility.hiddenFileCommentCount(
            comments: session.reviewComments,
            meta: session.threadMeta,
            visiblePaths: Set(session.markdownFiles.map(\.filename))) == 1)
        // Sidebar badges: unresolved threads only.
        let counts = ThreadVisibility.unresolvedCommentCounts(
            comments: session.reviewComments, meta: session.threadMeta)
        #expect(counts[DemoSession.calibrationPath] == 3)  // thread A (2) + outdated (1)
        #expect(counts[DemoSession.gettingStartedPath] == nil)  // resolved
    }

    @Test func authorsAreConsistentAndFictional() {
        let known = Set(DemoSession.authors.keys)
        for comment in DemoSession.reviewComments {
            #expect(known.contains(comment.author),
                    "unknown author \(comment.author)")
        }
        #expect(DemoSession.details.user.map { known.contains($0.login) } == true)
        // The viewer authored the staged reply (drives the ⋯ own-comment menu).
        let reply = DemoSession.reviewComments.first { $0.id == DemoSession.threadReplyID }
        #expect(reply?.author == DemoSession.viewerLogin)
        #expect(reply?.inReplyToId == DemoSession.threadReplyRootID)
    }

    // MARK: - Blame / avatars

    @Test func blameCoversEveryDocLineWithDataURIAvatars() throws {
        for (path, text) in DemoSession.headTexts {
            let count = lines(text).count
            let ranges = DemoSession.blameRanges(path: path)
            #expect(!ranges.isEmpty)
            var covered = 0
            for range in ranges.sorted(by: { $0.start < $1.start }) {
                #expect(range.start == covered + 1,
                        "\(path): blame gap before line \(range.start)")
                #expect(range.end >= range.start)
                covered = range.end
            }
            #expect(covered == count, "\(path): blame covers \(covered) of \(count) lines")
            for range in ranges {
                let uri = try #require(range.commit.userAvatarUrl)
                #expect(uri.hasPrefix("data:image/png;base64,"),
                        "\(path): avatar is not a local data URI")
                #expect(uri.count > 100, "\(path): avatar failed to render")
            }
        }
    }

    @Test func demoDocsExerciseTheRendererFeatureRange() {
        #expect(DemoSession.calibrationHead.contains("```mermaid"))
        #expect(DemoSession.calibrationHead.contains("| Solution | Expected RH |"))
        #expect(DemoSession.exportFormatsHead.contains("```meridian"))
        #expect(DemoSession.gettingStartedHead.contains("1. Insert the sensor batteries."))
    }
}
