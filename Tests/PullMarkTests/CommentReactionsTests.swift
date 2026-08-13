import Foundation
import Testing
@testable import PullMark

@Suite struct CommentReactionsTests {

    // MARK: - Kind mapping

    @Test func canonicalOrderMatchesGitHubsPicker() {
        #expect(ReactionKind.allCases.map(\.rawValue)
            == ["+1", "-1", "laugh", "hooray", "confused", "heart", "rocket", "eyes"])
    }

    @Test func graphQLNamesRoundTrip() {
        for kind in ReactionKind.allCases {
            #expect(ReactionKind(graphQL: kind.graphQLName) == kind)
        }
        #expect(ReactionKind(graphQL: "SPARKLES") == nil)
    }

    // MARK: - Chips

    @Test func chipsShowOnlyPresentReactionsInCanonicalOrder() {
        let rollup = ReactionRollup(plusOne: 3, heart: 1, rocket: 2)
        let chips = CommentReactions.chips(rollup: rollup, viewerReacted: ["rocket"])
        #expect(chips == [
            ReactionChipPayload(content: "+1", count: 3, mine: false),
            ReactionChipPayload(content: "heart", count: 1, mine: false),
            ReactionChipPayload(content: "rocket", count: 2, mine: true),
        ])
    }

    @Test func chipsAreEmptyWithoutARollup() {
        #expect(CommentReactions.chips(rollup: nil, viewerReacted: ["+1"]).isEmpty)
        #expect(CommentReactions.chips(rollup: ReactionRollup(), viewerReacted: []).isEmpty)
    }

    // MARK: - Who reacted

    @Test func whoLabelNamesReactorsViewerFirst() {
        let roster = ReactorRoster(logins: ["sam-ortega", "jedijashwa", "tobias-lund"],
                                   totalCount: 3)
        #expect(CommentReactions.whoLabel(roster: roster, viewer: "JediJashwa")
            == "You, sam-ortega, and tobias-lund reacted")
    }

    @Test func whoLabelShapes() {
        #expect(CommentReactions.whoLabel(
            roster: ReactorRoster(logins: ["ana"], totalCount: 1), viewer: nil)
            == "ana reacted")
        #expect(CommentReactions.whoLabel(
            roster: ReactorRoster(logins: ["ana", "bo"], totalCount: 2), viewer: nil)
            == "ana and bo reacted")
        // Beyond three, the tail counts against the TRUE total — the
        // fetch caps the names it carries.
        #expect(CommentReactions.whoLabel(
            roster: ReactorRoster(logins: ["ana", "bo", "cy", "di"], totalCount: 12),
            viewer: nil)
            == "ana, bo, cy, and 9 others reacted")
        #expect(CommentReactions.whoLabel(roster: nil, viewer: "x") == nil)
        #expect(CommentReactions.whoLabel(
            roster: ReactorRoster(logins: [], totalCount: 0), viewer: nil) == nil)
    }

    @Test func chipsCarryWhoTooltips() {
        let rollup = ReactionRollup(plusOne: 2)
        let chips = CommentReactions.chips(
            rollup: rollup, viewerReacted: ["+1"],
            reactors: ["+1": ReactorRoster(logins: ["jedijashwa", "sam-ortega"],
                                           totalCount: 2)],
            viewer: "jedijashwa")
        #expect(chips.count == 1)
        #expect(chips[0].who == "You and sam-ortega reacted")
        // Missing roster → nil who → chips keep their action tooltip.
        let bare = CommentReactions.chips(rollup: rollup, viewerReacted: [])
        #expect(bare[0].who == nil)
    }

    // MARK: - Toggle math

    @Test func addingAReactionIncrementsAndMarksMine() {
        let (rollup, mine) = CommentReactions.applied(
            rollup: ReactionRollup(plusOne: 2), viewerReacted: [],
            content: "+1", reacted: true)
        #expect(rollup.plusOne == 3)
        #expect(mine == ["+1"])
    }

    @Test func removingAReactionDecrementsAndClearsMine() {
        let (rollup, mine) = CommentReactions.applied(
            rollup: ReactionRollup(heart: 1), viewerReacted: ["heart", "eyes"],
            content: "heart", reacted: false)
        #expect(rollup.heart == 0)
        #expect(mine == ["eyes"])
    }

    @Test func togglesAreIdempotent() {
        // Re-adding a reaction the viewer already has changes nothing.
        let added = CommentReactions.applied(
            rollup: ReactionRollup(rocket: 4), viewerReacted: ["rocket"],
            content: "rocket", reacted: true)
        #expect(added.rollup.rocket == 4)
        // Removing one they don't have changes nothing (and can't go
        // negative even against a zero count).
        let removed = CommentReactions.applied(
            rollup: ReactionRollup(), viewerReacted: [],
            content: "laugh", reacted: false)
        #expect(removed.rollup.laugh == 0)
        #expect(removed.viewerReacted.isEmpty)
    }

    @Test func unknownContentIsIgnored() {
        let (rollup, mine) = CommentReactions.applied(
            rollup: ReactionRollup(plusOne: 1), viewerReacted: [],
            content: "sparkles", reacted: true)
        #expect(rollup == ReactionRollup(plusOne: 1))
        #expect(mine.isEmpty)
    }

    // MARK: - Meta lookups

    private let meta: [Int: ThreadMeta] = [
        10: ThreadMeta(nodeID: "T1", isResolved: false, comments: [
            10: ReviewCommentMeta(nodeID: "C10"),
            11: ReviewCommentMeta(nodeID: "C11", viewerReacted: ["+1"]),
        ]),
        20: ThreadMeta(nodeID: "T2", isResolved: true, comments: [
            20: ReviewCommentMeta(nodeID: "C20"),
        ]),
    ]

    @Test func findsCommentNodeIDThroughAnyThread() {
        #expect(CommentReactions.commentNodeID(of: 11, in: meta) == "C11")
        #expect(CommentReactions.commentNodeID(of: 20, in: meta) == "C20")
        #expect(CommentReactions.commentNodeID(of: 99, in: meta) == nil)
    }

    @Test func findsMetaRootForAReply() {
        #expect(CommentReactions.metaRoot(of: 11, in: meta) == 10)
        #expect(CommentReactions.metaRoot(of: 99, in: meta) == nil)
    }

    // MARK: - Author gating

    @Test func viewerOwnsOnlyTheirOwnComments() {
        #expect(CommentAuthorship.viewerOwns(author: "alice", viewer: "alice"))
        // GitHub logins are case-insensitive.
        #expect(CommentAuthorship.viewerOwns(author: "Alice", viewer: "alice"))
        #expect(!CommentAuthorship.viewerOwns(author: "bob", viewer: "alice"))
        // Nil on either side gates everything off.
        #expect(!CommentAuthorship.viewerOwns(author: nil, viewer: "alice"))
        #expect(!CommentAuthorship.viewerOwns(author: "alice", viewer: nil))
    }

    // MARK: - REST rollup decoding

    @Test func decodesRESTReactionRollup() throws {
        let json = Data("""
        {
          "id": 7, "path": "a.md", "body": "hi", "line": 3, "side": "RIGHT",
          "user": { "login": "alice" },
          "reactions": {
            "url": "https://api.github.com/x", "total_count": 6,
            "+1": 3, "-1": 0, "laugh": 0, "hooray": 1, "confused": 0,
            "heart": 0, "rocket": 0, "eyes": 2
          }
        }
        """.utf8)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let comment = try decoder.decode(ReviewComment.self, from: json)
        #expect(comment.reactions == ReactionRollup(plusOne: 3, hooray: 1, eyes: 2))
        // A comment without the rollup (older fixture shapes) still decodes.
        let bare = Data(#"{"id": 8, "path": "a.md", "body": "b"}"#.utf8)
        #expect(try decoder.decode(ReviewComment.self, from: bare).reactions == nil)
    }

    // MARK: - Payload enrichment

    private func comment(id: Int, author: String = "alice",
                         reactions: ReactionRollup? = nil) -> ReviewComment {
        ReviewComment(id: id, path: "a.md", body: "c\(id)", line: 5, side: "RIGHT",
                      startLine: nil, originalLine: nil, subjectType: nil,
                      inReplyToId: nil, user: .init(login: author),
                      createdAt: nil, htmlUrl: nil, reactions: reactions)
    }

    @Test func enrichedPayloadCarriesViewerState() {
        let threadMeta = ThreadMeta(nodeID: "T", isResolved: false, comments: [
            5: ReviewCommentMeta(nodeID: "C5", viewerReacted: ["eyes"], edited: true),
        ])
        let payload = CommentPayload(comment(id: 5, reactions: ReactionRollup(eyes: 2)),
                                     meta: threadMeta, viewer: "alice")
        #expect(payload.id == 5)
        #expect(payload.edited)
        #expect(payload.viewerOwned)
        #expect(payload.canReact)
        #expect(payload.reactions == [ReactionChipPayload(content: "eyes", count: 2, mine: true)])
    }

    @Test func missingMetaDegradesToReadOnlyChips() {
        let payload = CommentPayload(comment(id: 6, reactions: ReactionRollup(plusOne: 1)),
                                     meta: nil, viewer: "alice")
        #expect(!payload.canReact)
        #expect(!payload.edited)
        #expect(payload.reactions == [ReactionChipPayload(content: "+1", count: 1, mine: false)])
        // No viewer: no menu, no toggles, chips still informative.
        let unauthenticated = CommentPayload(comment(id: 6), meta: nil, viewer: nil)
        #expect(!unauthenticated.viewerOwned)
        #expect(!unauthenticated.canReact)
    }

    // MARK: - Thread-meta page parsing

    @Test func parsesThreadMetaPageWithReactionGroups() throws {
        let json = Data("""
        {
          "data": { "repository": { "pullRequest": { "reviewThreads": {
            "pageInfo": { "hasNextPage": true, "endCursor": "abc" },
            "nodes": [
              { "id": "T1", "isResolved": false, "comments": { "nodes": [
                { "id": "C1", "databaseId": 100, "lastEditedAt": null,
                  "reactionGroups": [
                    { "content": "THUMBS_UP", "viewerHasReacted": true,
                      "reactors": { "totalCount": 2,
                                    "nodes": [ { "login": "jedijashwa" },
                                               { "login": "sam-ortega" } ] } },
                    { "content": "HEART", "viewerHasReacted": false,
                      "reactors": { "totalCount": 0, "nodes": [] } }
                  ] },
                { "id": "C2", "databaseId": 101, "lastEditedAt": "2026-07-30T12:00:00Z",
                  "reactionGroups": [] }
              ] } },
              { "id": "T2", "isResolved": true, "comments": { "nodes": [] } }
            ]
          } } } }
        }
        """.utf8)
        let page = try GitHubClient.parseThreadMetaPage(json)
        #expect(page.nextCursor == "abc")
        let thread = try #require(page.meta[100])
        #expect(thread.nodeID == "T1")
        #expect(!thread.isResolved)
        // Reactors fold per REST content name; empty rosters are dropped
        // (a zero-count group would only clutter tooltips). The fixture
        // shape mirrors a live-API response, verified 2026-08-13.
        #expect(thread.comments[100] == ReviewCommentMeta(
            nodeID: "C1", viewerReacted: ["+1"], edited: false,
            reactors: ["+1": ReactorRoster(logins: ["jedijashwa", "sam-ortega"],
                                           totalCount: 2)]))
        #expect(thread.comments[101] == ReviewCommentMeta(nodeID: "C2",
                                                          viewerReacted: [],
                                                          edited: true))
        // A comment-less thread has no root id and is skipped, not fatal.
        #expect(page.meta.count == 1)
    }

    @Test func threadMetaPageWithoutNextPageEndsPagination() throws {
        let json = Data("""
        {
          "data": { "repository": { "pullRequest": { "reviewThreads": {
            "pageInfo": { "hasNextPage": false, "endCursor": "zzz" },
            "nodes": []
          } } } }
        }
        """.utf8)
        #expect(try GitHubClient.parseThreadMetaPage(json).nextCursor == nil)
    }
}
