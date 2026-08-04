import Foundation

/// GitHub's eight canonical comment reactions, in the picker's canonical
/// order (👍 👎 😄 🎉 😕 ❤️ 🚀 👀). Raw values are the REST content names
/// (the rollup's keys and the write payloads); `graphQLName` bridges to the
/// ReactionContent enum used by the add/remove mutations and
/// `reactionGroups`.
enum ReactionKind: String, CaseIterable, Equatable {
    case thumbsUp = "+1"
    case thumbsDown = "-1"
    case laugh
    case hooray
    case confused
    case heart
    case rocket
    case eyes

    var graphQLName: String {
        switch self {
        case .thumbsUp: return "THUMBS_UP"
        case .thumbsDown: return "THUMBS_DOWN"
        case .laugh: return "LAUGH"
        case .hooray: return "HOORAY"
        case .confused: return "CONFUSED"
        case .heart: return "HEART"
        case .rocket: return "ROCKET"
        case .eyes: return "EYES"
        }
    }

    init?(graphQL: String) {
        guard let kind = Self.allCases.first(where: { $0.graphQLName == graphQL }) else {
            return nil
        }
        self = kind
    }

    func count(in rollup: ReactionRollup) -> Int {
        switch self {
        case .thumbsUp: return rollup.plusOne
        case .thumbsDown: return rollup.minusOne
        case .laugh: return rollup.laugh
        case .hooray: return rollup.hooray
        case .confused: return rollup.confused
        case .heart: return rollup.heart
        case .rocket: return rollup.rocket
        case .eyes: return rollup.eyes
        }
    }
}

/// One reaction chip at a comment's foot: emoji + count, tinted when the
/// viewer pressed it. The page owns the content→emoji table (it also draws
/// the picker); the payload carries the REST content name.
struct ReactionChipPayload: Encodable, Equatable {
    let content: String
    let count: Int
    let mine: Bool
}

/// Pure reaction state math — chips shown, optimistic toggles folded back
/// into the model — kept out of the UI so every rule is unit-testable.
enum CommentReactions {
    /// Chips for the reactions present (count > 0), in canonical order.
    /// Counts come from the REST rollup; `viewerReacted` (REST content
    /// names, from GraphQL `reactionGroups.viewerHasReacted`) tints the
    /// viewer's own.
    static func chips(rollup: ReactionRollup?,
                      viewerReacted: Set<String>) -> [ReactionChipPayload] {
        guard let rollup else { return [] }
        return ReactionKind.allCases.compactMap { kind in
            let count = kind.count(in: rollup)
            guard count > 0 else { return nil }
            return ReactionChipPayload(content: kind.rawValue, count: count,
                                       mine: viewerReacted.contains(kind.rawValue))
        }
    }

    /// A confirmed toggle folded into the model: the rollup count and the
    /// viewer set move together. Idempotent — re-adding a reaction the
    /// viewer already has (or removing one they don't) changes nothing, so
    /// a raced refresh can never double-count.
    static func applied(rollup: ReactionRollup, viewerReacted: Set<String>,
                        content: String, reacted: Bool)
        -> (rollup: ReactionRollup, viewerReacted: Set<String>) {
        guard let kind = ReactionKind(rawValue: content),
              viewerReacted.contains(content) != reacted else {
            return (rollup, viewerReacted)
        }
        var updated = rollup
        var set = viewerReacted
        let delta = reacted ? 1 : -1
        updated.setCount(max(0, kind.count(in: rollup) + delta), for: kind)
        if reacted { set.insert(content) } else { set.remove(content) }
        return (updated, set)
    }

    /// The GraphQL node id of a comment, found through the thread-meta map
    /// (keyed by root comment id) — the subject id for addReaction /
    /// removeReaction.
    static func commentNodeID(of commentID: Int, in meta: [Int: ThreadMeta]) -> String? {
        for thread in meta.values {
            if let nodeID = thread.comments[commentID]?.nodeID { return nodeID }
        }
        return nil
    }

    /// The root-comment key of the thread holding `commentID` in the meta
    /// map, so a model update can reach its per-comment viewer state.
    static func metaRoot(of commentID: Int, in meta: [Int: ThreadMeta]) -> Int? {
        meta.first { $0.value.comments[commentID] != nil }?.key
    }
}

/// Author gating for the ⋯ (Edit/Delete) menu: only the viewer's own
/// published comments get one. GitHub logins are case-insensitive; a nil
/// viewer (unauthenticated, identity not yet resolved) gates everything off.
enum CommentAuthorship {
    static func viewerOwns(author: String?, viewer: String?) -> Bool {
        guard let author, let viewer else { return false }
        return author.lowercased() == viewer.lowercased()
    }
}
