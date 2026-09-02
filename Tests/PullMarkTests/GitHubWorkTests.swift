import Foundation
import Testing
@testable import PullMark

@Suite("GitHub work: queries, buckets, unread")
struct GitHubWorkTests {
    private func item(_ n: Int, kind: GitHubWork.Kind = .pr, author: String = "someone",
                      updated: String = "2026-08-28T10:00:00Z") -> GitHubWork.Item {
        GitHubWork.Item(kind: kind, ref: PullRequestRef(owner: "acme", repo: "docs", number: n),
                        title: "Item \(n)", author: author, draft: false, updatedAt: updated)
    }

    // MARK: - Queries

    @Test func bucketQueriesUseTheViewerQualifiers() {
        #expect(GitHubWork.bucketQuery(.reviewRequests, kind: nil)
                == "is:open is:pr review-requested:@me archived:false")
        #expect(GitHubWork.bucketQuery(.created, kind: .issue)
                == "is:open is:issue author:@me archived:false")
        #expect(GitHubWork.bucketQuery(.assigned, kind: nil)
                == "is:open assignee:@me archived:false")
        #expect(GitHubWork.bucketQuery(.participating, kind: .pr)
                == "is:open is:pr involves:@me -author:@me -assignee:@me archived:false")
    }

    @Test func repoQueryScopesOneRepository() {
        let repo = GitHubWork.FollowedRepo(owner: "acme", repo: "docs")
        #expect(GitHubWork.repoQuery(repo) == "repo:acme/docs is:open archived:false")
        #expect(GitHubWork.repoQuery(repo, kind: .issue) == "repo:acme/docs is:open is:issue archived:false")
    }

    @Test func bucketsPerKind() {
        #expect(GitHubWork.Bucket.buckets(for: .pr) == [.reviewRequests, .created, .assigned, .participating])
        #expect(GitHubWork.Bucket.buckets(for: .issue) == [.created, .assigned, .participating])
    }

    // MARK: - Followed repositories

    @Test func followedRepoParsesNamesAndURLs() {
        #expect(GitHubWork.FollowedRepo.parse("acme/docs")?.id == "acme/docs")
        #expect(GitHubWork.FollowedRepo.parse("https://github.com/acme/docs/pulls?q=x")?.id == "acme/docs")
        #expect(GitHubWork.FollowedRepo.parse("github.com/acme/docs.git")?.id == "acme/docs")
        #expect(GitHubWork.FollowedRepo.parse("not a repo") == nil)
        #expect(GitHubWork.FollowedRepo.parse("") == nil)
    }

    @Test func followedRepoListRoundTrips() {
        let list = [GitHubWork.FollowedRepo(owner: "a", repo: "b", unread: .onlyMine)]
        let data = try? #require(GitHubWork.FollowedRepo.encodeList(list))
        #expect(GitHubWork.FollowedRepo.decodeList(data) == list)
        #expect(GitHubWork.FollowedRepo.decodeList(nil).isEmpty)
    }

    // MARK: - Assembly

    @Test func rolesAccumulateAcrossBucketsAndParticipatingYields() {
        var snapshot = GitHubWork.Snapshot()
        GitHubWork.merge([item(1), item(2)], into: &snapshot, bucket: .created, repoID: nil, page: 1, hasMore: false)
        GitHubWork.merge([item(2), item(3)], into: &snapshot, bucket: .assigned, repoID: nil, page: 1, hasMore: false)
        GitHubWork.merge([item(1), item(4)], into: &snapshot, bucket: .participating, repoID: nil, page: 1, hasMore: true)
        GitHubWork.settle(&snapshot)
        #expect(snapshot.items["acme/docs#2"]?.roles == [.created, .assigned])
        #expect(snapshot.buckets[.created] == ["acme/docs#1", "acme/docs#2"])
        #expect(snapshot.buckets[.assigned] == ["acme/docs#2", "acme/docs#3"])
        // #1 is created by the viewer: it leaves Participating.
        #expect(snapshot.buckets[.participating] == ["acme/docs#4"])
        #expect(snapshot.items["acme/docs#1"]?.roles == [.created])
        #expect(snapshot.moreAvailable == ["bucket:participating"])
    }

    @Test func appendJoinsABucketWithoutPaging() {
        var snapshot = GitHubWork.Snapshot()
        GitHubWork.merge([item(1)], into: &snapshot, bucket: .participating, repoID: nil, page: 1, hasMore: true)
        GitHubWork.append([item(1), item(9)], into: &snapshot, bucket: .participating)
        #expect(snapshot.buckets[.participating] == ["acme/docs#1", "acme/docs#9"])
        #expect(snapshot.pages["bucket:participating"] == 1)
        #expect(snapshot.moreAvailable.contains("bucket:participating"))
    }

    @Test func showMoreAppendsWithoutDuplicates() {
        var snapshot = GitHubWork.Snapshot()
        GitHubWork.merge([item(1), item(2)], into: &snapshot, bucket: nil, repoID: "acme/docs", page: 1, hasMore: true)
        GitHubWork.merge([item(2), item(3)], into: &snapshot, bucket: nil, repoID: "acme/docs", page: 2, hasMore: false)
        #expect(snapshot.repoGroups["acme/docs"] == ["acme/docs#1", "acme/docs#2", "acme/docs#3"])
        #expect(snapshot.moreAvailable.isEmpty)
        #expect(snapshot.pages["repo:acme/docs"] == 2)
        #expect(snapshot.items(inRepo: "acme/docs", kind: .issue).isEmpty)
        #expect(snapshot.items(inRepo: "acme/docs", kind: .pr).count == 3)
    }

    @Test func kindFilteredBucketViews() {
        var snapshot = GitHubWork.Snapshot()
        GitHubWork.merge([item(1, kind: .issue), item(2)], into: &snapshot, bucket: .created, repoID: nil, page: 1, hasMore: false)
        #expect(snapshot.items(in: .created, kind: .issue).map(\.id) == ["acme/docs#1"])
        #expect(snapshot.items(in: .created, kind: .pr).map(\.id) == ["acme/docs#2"])
    }

    // MARK: - Unread

    @Test func unreadFollowsSeenStamps() {
        let it = item(1)
        #expect(GitHubWork.isUnread(it, seen: [:], viewer: nil, override: nil, repoRule: nil))
        #expect(!GitHubWork.isUnread(it, seen: [it.id: it.updatedAt], viewer: nil, override: nil, repoRule: nil))
        #expect(GitHubWork.isUnread(it, seen: [it.id: "older"], viewer: nil, override: nil, repoRule: nil))
    }

    @Test func repoRulesAndOverridesRank() {
        var mine = item(1, author: "me")
        let theirs = item(2, author: "them")
        // Repo group rules
        #expect(!GitHubWork.isUnread(theirs, seen: [:], viewer: "me", override: nil, repoRule: .silent))
        #expect(!GitHubWork.isUnread(theirs, seen: [:], viewer: "me", override: nil, repoRule: .onlyMine))
        #expect(GitHubWork.isUnread(mine, seen: [:], viewer: "me", override: nil, repoRule: .onlyMine))
        mine.roles = []
        var assigned = theirs
        assigned.roles = [.assigned]
        #expect(GitHubWork.isUnread(assigned, seen: [:], viewer: "me", override: nil, repoRule: .onlyMine))
        // The item's own choice wins
        #expect(GitHubWork.isUnread(theirs, seen: [:], viewer: "me", override: .always, repoRule: .silent))
        #expect(!GitHubWork.isUnread(mine, seen: [:], viewer: "me", override: .never, repoRule: .everything))
        #expect(!GitHubWork.isUnread(theirs, seen: [theirs.id: theirs.updatedAt], viewer: "me", override: .always, repoRule: nil))
    }

    @Test func mixedCountLabel() {
        #expect(GitHubWork.countLabel(prs: 6, issues: 14) == "6 · 14")
        #expect(GitHubWork.countLabel(prs: 3, issues: 0) == "3")
        #expect(GitHubWork.countLabel(prs: 0, issues: 2) == "2")
    }

    // MARK: - Search parsing

    @Test func searchResponseParsesBothKinds() throws {
        let json = """
        {"total_count": 61, "items": [
          {"number": 12, "title": "Fix docs", "repository_url": "https://api.github.com/repos/acme/docs",
           "updated_at": "2026-08-28T09:00:00Z", "user": {"login": "sam"}, "draft": true,
           "pull_request": {"url": "https://api.github.com/repos/acme/docs/pulls/12"}},
          {"number": 7, "title": "Broken link", "repository_url": "https://api.github.com/repos/acme/docs",
           "updated_at": "2026-08-27T09:00:00Z", "user": {"login": "kim"}}
        ]}
        """
        let parsed = try GitHubWork.parseSearch(Data(json.utf8), page: 2)
        #expect(parsed.items.count == 2)
        #expect(parsed.items[0].kind == .pr)
        #expect(parsed.items[0].draft)
        #expect(parsed.items[0].ref == PullRequestRef(owner: "acme", repo: "docs", number: 12))
        #expect(parsed.items[1].kind == .issue)
        #expect(parsed.items[1].author == "kim")
        // 61 results, page 2 of 30 shown → one more page.
        #expect(parsed.hasMore)
        let last = try GitHubWork.parseSearch(Data(json.utf8), page: 3)
        #expect(!last.hasMore)
    }
}
