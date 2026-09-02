import Foundation

/// The pull requests and issues that concern the viewer, and the
/// repositories they follow (spec: github-work). Pure: queries, bucket
/// assembly, unread rules, and the search-response parser live here so
/// the sidebar's grouping is unit-tested without a network.
enum GitHubWork {
    enum Kind: String, Codable, CaseIterable {
        case pr
        case issue
    }

    /// Why an item is in front of the viewer. An item can carry several
    /// (created AND assigned), as GitHub shows it.
    enum Role: String, Codable, CaseIterable {
        case reviewRequested
        case created
        case assigned
        case participating
    }

    /// The involvement groups, in sidebar order (spec §2).
    enum Bucket: String, CaseIterable, Identifiable {
        case reviewRequests
        case created
        case assigned
        case participating

        var id: String { rawValue }

        /// Review requests are a pull-request notion only.
        func applies(to kind: Kind) -> Bool {
            self != .reviewRequests || kind == .pr
        }

        static func buckets(for kind: Kind) -> [Bucket] {
            allCases.filter { $0.applies(to: kind) }
        }

        var role: Role {
            switch self {
            case .reviewRequests: return .reviewRequested
            case .created: return .created
            case .assigned: return .assigned
            case .participating: return .participating
            }
        }
    }

    struct Item: Identifiable, Equatable {
        let kind: Kind
        let ref: PullRequestRef
        let title: String
        let author: String?
        let draft: Bool
        /// ISO timestamp from the search API — drives unread state.
        let updatedAt: String
        var roles: Set<Role> = []

        /// The same key the review-request inbox used, so seen-state
        /// carries over across the upgrade.
        var id: String { "\(ref.owner)/\(ref.repo)#\(ref.number)" }
        var repoID: String { "\(ref.owner)/\(ref.repo)" }
    }

    /// A repository whose whole open queue shows in the sidebar (spec
    /// §3). A preference, never session state.
    struct FollowedRepo: Codable, Equatable, Identifiable {
        let owner: String
        let repo: String
        var unread: UnreadRule = .everything

        var id: String { "\(owner)/\(repo)" }

        init(owner: String, repo: String, unread: UnreadRule = .everything) {
            self.owner = owner
            self.repo = repo
            self.unread = unread
        }

        /// "owner/repo", a github.com URL, or nothing usable.
        static func parse(_ input: String) -> FollowedRepo? {
            let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
            let patterns = [
                #"^(?:https?://)?(?:www\.)?github\.com/([\w.-]+)/([\w.-]+)(?:[/?#].*)?$"#,
                #"^([\w.-]+)/([\w.-]+)$"#,
            ]
            for pattern in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                let range = NSRange(s.startIndex..., in: s)
                guard let match = regex.firstMatch(in: s, range: range),
                      let ownerRange = Range(match.range(at: 1), in: s),
                      let repoRange = Range(match.range(at: 2), in: s)
                else { continue }
                var repo = String(s[repoRange])
                if repo.hasSuffix(".git") { repo.removeLast(4) }
                return FollowedRepo(owner: String(s[ownerRange]), repo: repo)
            }
            return nil
        }

        static func decodeList(_ data: Data?) -> [FollowedRepo] {
            guard let data, let list = try? JSONDecoder().decode([FollowedRepo].self, from: data) else { return [] }
            return list
        }

        static func encodeList(_ list: [FollowedRepo]) -> Data? {
            try? JSONEncoder().encode(list)
        }
    }

    /// What earns a dot inside a followed repository's group (spec §3).
    /// `silent` rather than `none`: an enum case named `none` reads as
    /// `Optional.none` wherever the rule is optional.
    enum UnreadRule: String, Codable, CaseIterable {
        case everything
        case onlyMine
        case silent
    }

    /// A single item's own choice, outranking its repository's rule
    /// (spec §4). Absent means "use repository setting".
    enum ItemUnreadOverride: String, Codable {
        case always
        case never
    }

    /// Settings › Reviewing › Group GitHub work by (spec §6).
    enum Grouping: String {
        case type
        case involvement
    }

    static let pageSize = 30

    // MARK: - Queries

    /// The search API query for a bucket. `kind` nil asks for both types
    /// in one call (the involvement layout's cheaper shape); review
    /// requests are pull requests regardless.
    static func bucketQuery(_ bucket: Bucket, kind: Kind?) -> String {
        var parts = ["is:open"]
        let effectiveKind: Kind? = bucket == .reviewRequests ? .pr : kind
        if let effectiveKind { parts.append(effectiveKind == .pr ? "is:pr" : "is:issue") }
        switch bucket {
        case .reviewRequests: parts.append("review-requested:@me")
        case .created: parts.append("author:@me")
        case .assigned: parts.append("assignee:@me")
        case .participating: parts += ["involves:@me", "-author:@me", "-assignee:@me"]
        }
        parts.append("archived:false")
        return parts.joined(separator: " ")
    }

    /// Reviews without a comment don't count as "involves" — the second
    /// participating query for pull requests.
    static let reviewedQuery = "is:open is:pr reviewed-by:@me -author:@me -assignee:@me archived:false"

    static func repoQuery(_ repo: FollowedRepo, kind: Kind? = nil) -> String {
        var parts = ["repo:\(repo.owner)/\(repo.repo)", "is:open"]
        if let kind { parts.append(kind == .pr ? "is:pr" : "is:issue") }
        parts.append("archived:false")
        return parts.joined(separator: " ")
    }

    // MARK: - Assembly

    /// Everything the sidebar renders, refreshed as a unit.
    struct Snapshot: Equatable {
        /// Every item seen by any query, by id.
        var items: [String: Item] = [:]
        /// Per bucket, item ids in query order (most recently updated
        /// first). An id may appear in several buckets.
        var buckets: [Bucket: [String]] = [:]
        /// Per followed repository id, item ids in query order.
        var repoGroups: [String: [String]] = [:]
        /// Group keys ("bucket:created", "repo:owner/repo") with more
        /// pages behind Show more….
        var moreAvailable: Set<String> = []
        /// Pages fetched so far per group key.
        var pages: [String: Int] = [:]

        var isEmpty: Bool { items.isEmpty }

        func items(in bucket: Bucket, kind: Kind) -> [Item] {
            (buckets[bucket] ?? []).compactMap { items[$0] }.filter { $0.kind == kind }
        }

        func items(in bucket: Bucket) -> [Item] {
            (buckets[bucket] ?? []).compactMap { items[$0] }
        }

        func items(inRepo repoID: String, kind: Kind? = nil) -> [Item] {
            (repoGroups[repoID] ?? []).compactMap { items[$0] }
                .filter { kind == nil || $0.kind == kind }
        }

        static func bucketKey(_ bucket: Bucket) -> String { "bucket:" + bucket.rawValue }
        static func repoKey(_ repoID: String) -> String { "repo:" + repoID }
    }

    /// Folds one query's results into the snapshot: items merge (roles
    /// accumulate), the group's order is the query's order. Participating
    /// excludes anything the viewer created or is assigned to (spec §2),
    /// applied after every bucket has landed via `settle`.
    static func merge(_ results: [Item], into snapshot: inout Snapshot,
                      bucket: Bucket?, repoID: String?, page: Int, hasMore: Bool) {
        let key = bucket.map(Snapshot.bucketKey) ?? Snapshot.repoKey(repoID ?? "")
        var order = page > 1 ? (bucket.map { snapshot.buckets[$0] } ?? snapshot.repoGroups[repoID ?? ""]) ?? [] : []
        for var item in results {
            if let bucket { item.roles.insert(bucket.role) }
            if var existing = snapshot.items[item.id] {
                existing.roles.formUnion(item.roles)
                snapshot.items[item.id] = existing
            } else {
                snapshot.items[item.id] = item
            }
            if !order.contains(item.id) { order.append(item.id) }
        }
        if let bucket {
            snapshot.buckets[bucket] = order
        } else if let repoID {
            snapshot.repoGroups[repoID] = order
        }
        if hasMore { snapshot.moreAvailable.insert(key) } else { snapshot.moreAvailable.remove(key) }
        snapshot.pages[key] = page
    }

    /// Folds a supplementary query into a bucket without touching its
    /// paging — the reviewed-by pull requests that `involves:` misses
    /// join Participating this way (spec §2).
    static func append(_ results: [Item], into snapshot: inout Snapshot, bucket: Bucket) {
        var order = snapshot.buckets[bucket] ?? []
        for var item in results {
            item.roles.insert(bucket.role)
            if var existing = snapshot.items[item.id] {
                existing.roles.formUnion(item.roles)
                snapshot.items[item.id] = existing
            } else {
                snapshot.items[item.id] = item
            }
            if !order.contains(item.id) { order.append(item.id) }
        }
        snapshot.buckets[bucket] = order
    }

    /// Participating minus created and assigned — an item you opened or
    /// own already has a bucket that says so.
    static func settle(_ snapshot: inout Snapshot) {
        let owned = Set((snapshot.buckets[.created] ?? []) + (snapshot.buckets[.assigned] ?? []))
        snapshot.buckets[.participating] = (snapshot.buckets[.participating] ?? []).filter { !owned.contains($0) }
        for id in owned { snapshot.items[id]?.roles.remove(.participating) }
    }

    // MARK: - Unread

    /// The dot rule (spec §3–§4). `seen` maps item id → the `updatedAt`
    /// last opened; `repoRule` applies only when the row sits in a
    /// followed repository's group; the item's own override wins.
    static func isUnread(_ item: Item, seen: [String: String], viewer: String?,
                         override: ItemUnreadOverride?, repoRule: UnreadRule?) -> Bool {
        let changed = seen[item.id] != item.updatedAt
        switch override {
        case .never: return false
        case .always: return changed
        case nil: break
        }
        switch repoRule {
        case nil, .everything?: return changed
        case .silent?: return false
        case .onlyMine?:
            let mine = !item.roles.isEmpty || (viewer != nil && item.author == viewer)
            return mine && changed
        }
    }

    /// "6 · 14" for a mixed group header; a single kind shows its number
    /// alone.
    static func countLabel(prs: Int, issues: Int) -> String {
        switch (prs, issues) {
        case (_, 0): return "\(prs)"
        case (0, _): return "\(issues)"
        default: return "\(prs) · \(issues)"
        }
    }

    // MARK: - Search response

    /// Pure parser for `GET /search/issues`: pull requests carry a
    /// `pull_request` key, issues don't. `total_count` decides whether
    /// another page exists.
    static func parseSearch(_ data: Data, page: Int) throws -> (items: [Item], hasMore: Bool) {
        struct Response: Decodable {
            struct Entry: Decodable {
                struct User: Decodable { let login: String }
                struct PRMarker: Decodable {}
                let number: Int
                let title: String
                let repositoryUrl: String
                let updatedAt: String
                let user: User?
                let draft: Bool?
                let pullRequest: PRMarker?
            }
            let totalCount: Int
            let items: [Entry]
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(Response.self, from: data)
        let items = response.items.compactMap { entry -> Item? in
            let parts = entry.repositoryUrl.components(separatedBy: "/repos/").last?
                .components(separatedBy: "/") ?? []
            guard parts.count == 2 else { return nil }
            return Item(kind: entry.pullRequest == nil ? .issue : .pr,
                        ref: PullRequestRef(owner: parts[0], repo: parts[1], number: entry.number),
                        title: entry.title, author: entry.user?.login,
                        draft: entry.draft ?? false, updatedAt: entry.updatedAt)
        }
        return (items, page * pageSize < response.totalCount)
    }
}
