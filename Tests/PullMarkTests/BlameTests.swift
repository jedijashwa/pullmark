import Foundation
import Testing
@testable import PullMark

@Suite struct BlamePorcelainTests {
    // Two commits over four lines: commit A blames lines 1-2 and 4, commit B
    // line 3. Metadata appears only on a commit's first occurrence, exactly
    // as `git blame --porcelain` emits it.
    static let fixture = """
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 1 1 2
    author Ada Lovelace
    author-mail <ada@example.com>
    author-time 1721000000
    author-tz -0700
    committer Ada Lovelace
    committer-mail <ada@example.com>
    committer-time 1721000000
    committer-tz -0700
    summary Add the README
    filename README.md
    \t# Title
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 2 2
    filename README.md
    \tIntro line
    bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb 3 3 1
    author Grace Hopper
    author-mail <grace@example.com>
    author-time 1722000000
    author-tz -0700
    committer Grace Hopper
    committer-mail <grace@example.com>
    committer-time 1722000000
    committer-tz -0700
    summary Clarify the intro
    previous aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa README.md
    filename README.md
    \tBetter intro
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 4 4 1
    filename README.md
    \tOutro
    """

    @Test func parsesAndCoalescesRanges() {
        let ranges = LocalGit.parseBlamePorcelain(Self.fixture)
        #expect(ranges.count == 3)
        #expect(ranges[0].start == 1)
        #expect(ranges[0].end == 2) // lines 1-2 coalesce (same commit, contiguous)
        #expect(ranges[0].commit.authorName == "Ada Lovelace")
        #expect(ranges[0].commit.authorEmail == "ada@example.com")
        #expect(ranges[0].commit.summary == "Add the README")
        #expect(ranges[0].commit.date == Date(timeIntervalSince1970: 1_721_000_000))
        #expect(ranges[1].start == 3)
        #expect(ranges[1].end == 3)
        #expect(ranges[1].commit.authorName == "Grace Hopper")
        #expect(ranges[1].commit.authorEmail == "grace@example.com")
        #expect(ranges[2].start == 4)
        #expect(ranges[2].end == 4)
        // Line 4 reuses commit A's metadata even though only the header repeats.
        #expect(ranges[2].commit.summary == "Add the README")
    }

    @Test func uncommittedLinesGetTheZeroSHA() {
        let out = """
        0000000000000000000000000000000000000000 1 1 1
        author Not Committed Yet
        author-mail <not.committed.yet>
        author-time 1723000000
        author-tz +0000
        summary Version of README.md from README.md
        filename README.md
        \tnew line
        """
        let ranges = LocalGit.parseBlamePorcelain(out)
        #expect(ranges.count == 1)
        #expect(ranges[0].commit.isUncommitted)
    }

    @Test func emptyAndGarbageInput() {
        #expect(LocalGit.parseBlamePorcelain("").isEmpty)
        #expect(LocalGit.parseBlamePorcelain("not blame output\nat all").isEmpty)
    }
}

@Suite struct GitHubRemoteParserTests {
    @Test func httpsRemotes() {
        #expect(LocalGit.parseGitHubRemote("https://github.com/jedijashwa/pullmark.git\n")! == ("jedijashwa", "pullmark"))
        #expect(LocalGit.parseGitHubRemote("https://github.com/o/r")! == ("o", "r"))
        #expect(LocalGit.parseGitHubRemote("https://user@github.com/o/r.git")! == ("o", "r"))
    }

    @Test func sshRemotes() {
        #expect(LocalGit.parseGitHubRemote("git@github.com:o/repo.name.git")! == ("o", "repo.name"))
        #expect(LocalGit.parseGitHubRemote("ssh://git@github.com/o/r.git")! == ("o", "r"))
    }

    @Test func nonGitHubRemotes() {
        #expect(LocalGit.parseGitHubRemote("https://gitlab.com/o/r.git") == nil)
        #expect(LocalGit.parseGitHubRemote("git@bitbucket.org:o/r.git") == nil)
        #expect(LocalGit.parseGitHubRemote("") == nil)
    }
}

// Shared commit factory for the mapper/tier/history suites.
private let testNow = Date(timeIntervalSince1970: 1_724_000_000)

private func makeCommit(_ sha: String, _ author: String, daysAgo: Double,
                        summary: String = "", email: String? = nil,
                        userAvatar: String? = nil, actorAvatar: String? = nil,
                        url: String? = nil) -> BlameCommit {
    BlameCommit(sha: sha, authorName: author, authorEmail: email,
                date: testNow.addingTimeInterval(-daysAgo * 86400),
                summary: summary, userAvatarUrl: userAvatar,
                actorAvatarUrl: actorAvatar, url: url)
}

private func sha(_ character: Character) -> String {
    String(repeating: character, count: 40)
}

@Suite struct BlameRunsTests {
    @Test func coalescesConsecutiveBlocksWithSameCommit() {
        let blocks = [MarkdownBlock(text: "# Title", startLine: 1, endLine: 1),
                      MarkdownBlock(text: "Intro", startLine: 3, endLine: 4),
                      MarkdownBlock(text: "Body", startLine: 6, endLine: 9),
                      MarkdownBlock(text: "Outro", startLine: 11, endLine: 12)]
        let a = makeCommit(sha("a"), "Ada", daysAgo: 10, summary: "add docs",
                           url: "https://github.com/o/r/commit/\(sha("a"))")
        let b = makeCommit(sha("b"), "Grace", daysAgo: 2, summary: "edit outro")
        let ranges = [BlameRange(start: 1, end: 9, commit: a),
                      BlameRange(start: 10, end: 12, commit: b)]
        let runs = BlameMapper.runs(blocks: blocks, ranges: ranges, now: testNow)
        // Blocks 1-3 share commit A → one run spanning their whole range.
        #expect(runs.count == 2)
        #expect(runs[0].lineStart == 1)
        #expect(runs[0].lineEnd == 9)
        #expect(runs[0].author == "Ada")
        #expect(runs[0].shortSHA == "aaaaaaa")
        #expect(runs[0].headline == "add docs")
        #expect(runs[0].dateLabel == "1 week ago")
        #expect(runs[0].url == "https://github.com/o/r/commit/\(sha("a"))")
        #expect(runs[1].lineStart == 11)
        #expect(runs[1].lineEnd == 12)
        #expect(runs[1].author == "Grace")
    }

    @Test func mostRecentCommitWinsPerBlock() {
        let blocks = [MarkdownBlock(text: "Body", startLine: 1, endLine: 5)]
        let old = makeCommit(sha("a"), "Ada", daysAgo: 100)
        let recent = makeCommit(sha("b"), "Grace", daysAgo: 2)
        let ranges = [BlameRange(start: 1, end: 3, commit: old),
                      BlameRange(start: 4, end: 5, commit: recent)]
        let runs = BlameMapper.runs(blocks: blocks, ranges: ranges, now: testNow)
        #expect(runs.count == 1)
        #expect(runs[0].author == "Grace")
    }

    @Test func unblamedBlockBreaksARun() {
        let blocks = [MarkdownBlock(text: "a", startLine: 1, endLine: 1),
                      MarkdownBlock(text: "b", startLine: 50, endLine: 50),
                      MarkdownBlock(text: "c", startLine: 3, endLine: 3)]
        let a = makeCommit(sha("a"), "Ada", daysAgo: 1)
        let ranges = [BlameRange(start: 1, end: 3, commit: a)]
        let runs = BlameMapper.runs(blocks: blocks, ranges: ranges, now: testNow)
        // The uncovered middle block yields no run and splits the outer two.
        #expect(runs.count == 2)
        #expect(runs[0].lineStart == 1)
        #expect(runs[0].lineEnd == 1)
        #expect(runs[1].lineStart == 3)
        #expect(runs[1].lineEnd == 3)
    }

    @Test func uncommittedRunsAreFlagged() {
        let blocks = [MarkdownBlock(text: "wip", startLine: 1, endLine: 2)]
        let wip = BlameCommit(sha: String(repeating: "0", count: 40),
                              authorName: "Not Committed Yet", date: testNow, summary: "")
        let runs = BlameMapper.runs(blocks: blocks,
                                    ranges: [BlameRange(start: 1, end: 2, commit: wip)],
                                    now: testNow)
        #expect(runs.count == 1)
        #expect(runs[0].uncommitted == true)
        #expect(runs[0].url == nil)
    }

    @Test func noBlocksOrRangesProduceNoRuns() {
        #expect(BlameMapper.runs(blocks: [], ranges: [], now: testNow).isEmpty)
        let blocks = [MarkdownBlock(text: "x", startLine: 1, endLine: 1)]
        #expect(BlameMapper.runs(blocks: blocks, ranges: [], now: testNow).isEmpty)
    }

    @Test func relativeDateLabels() {
        func ago(_ seconds: Double) -> String {
            BlameMapper.relativeLabel(from: testNow.addingTimeInterval(-seconds), to: testNow)
        }
        #expect(ago(10) == "just now")
        #expect(ago(90) == "2 minutes ago")
        #expect(ago(3600) == "1 hour ago")
        #expect(ago(86400) == "1 day ago")
        #expect(ago(3 * 86400) == "3 days ago")
        #expect(ago(21 * 86400) == "3 weeks ago")
        #expect(ago(61 * 86400) == "2 months ago")
        #expect(ago(800 * 86400) == "2 years ago")
    }
}

@Suite struct AvatarTierTests {
    static let viewer = ViewerIdentity(login: "jedijashwa", name: "Josh Riesenbach",
                                       email: "josh@example.com",
                                       avatarUrl: "https://avatars.example/viewer")

    @Test func accountAvatarWinsOverEverything() {
        let commit = makeCommit(sha("a"), "Josh Riesenbach", daysAgo: 1,
                                email: "josh@example.com",
                                userAvatar: "https://avatars.example/account",
                                actorAvatar: "https://avatars.example/actor")
        #expect(BlameMapper.avatarURL(for: commit, viewer: Self.viewer)
                == "https://avatars.example/account")
    }

    @Test func viewerTierMatchesByName() {
        let commit = makeCommit(sha("a"), "Josh Riesenbach", daysAgo: 1,
                                email: "private@nowhere.invalid")
        #expect(BlameMapper.avatarURL(for: commit, viewer: Self.viewer)
                == "https://avatars.example/viewer")
    }

    @Test func viewerTierMatchesByLoginAsName() {
        let commit = makeCommit(sha("a"), "jedijashwa", daysAgo: 1)
        #expect(BlameMapper.avatarURL(for: commit, viewer: Self.viewer)
                == "https://avatars.example/viewer")
    }

    @Test func viewerTierMatchesByEmail() {
        let commit = makeCommit(sha("a"), "Someone Else", daysAgo: 1,
                                email: "Josh@Example.com")
        #expect(BlameMapper.avatarURL(for: commit, viewer: Self.viewer)
                == "https://avatars.example/viewer")
    }

    @Test func viewerTierMatchesNoreplyEmails() {
        for email in ["jedijashwa@users.noreply.github.com",
                      "12345+jedijashwa@users.noreply.github.com"] {
            let commit = makeCommit(sha("a"), "Mystery Name", daysAgo: 1, email: email)
            #expect(BlameMapper.avatarURL(for: commit, viewer: Self.viewer)
                    == "https://avatars.example/viewer", "email: \(email)")
        }
    }

    @Test func viewerTierBeatsActorAvatar() {
        let commit = makeCommit(sha("a"), "Josh Riesenbach", daysAgo: 1,
                                actorAvatar: "https://avatars.example/actor")
        #expect(BlameMapper.avatarURL(for: commit, viewer: Self.viewer)
                == "https://avatars.example/viewer")
    }

    @Test func actorAvatarUsedWhenNoUserOrViewerMatch() {
        let commit = makeCommit(sha("a"), "Someone Else", daysAgo: 1,
                                email: "else@example.com",
                                actorAvatar: "https://avatars.example/actor")
        #expect(BlameMapper.avatarURL(for: commit, viewer: Self.viewer)
                == "https://avatars.example/actor")
        #expect(BlameMapper.avatarURL(for: commit, viewer: nil)
                == "https://avatars.example/actor")
    }

    @Test func noMatchFallsThroughToNilForInitials() {
        let commit = makeCommit(sha("a"), "Someone Else", daysAgo: 1)
        #expect(BlameMapper.avatarURL(for: commit, viewer: Self.viewer) == nil)
        #expect(BlameMapper.avatarURL(for: commit, viewer: nil) == nil)
    }

    @Test func uncommittedLinesUseTheViewerAvatar() {
        let wip = BlameCommit(sha: String(repeating: "0", count: 40),
                              authorName: "Not Committed Yet", date: nil, summary: "")
        #expect(BlameMapper.avatarURL(for: wip, viewer: Self.viewer)
                == "https://avatars.example/viewer")
        #expect(BlameMapper.avatarURL(for: wip, viewer: nil) == nil)
    }
}

@Suite struct LineLogParserTests {
    // git log -L output interleaves the --format line (prefixed with the
    // \u{01} sentinel) with full patch text per commit.
    static let fixture = "\u{01}"
        + "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\tGrace Hopper\tgrace@example.com\t1722000000\tClarify the intro\n"
        + """
        diff --git a/README.md b/README.md
        --- a/README.md
        +++ b/README.md
        @@ -2,1 +2,1 @@
        -Intro line
        +Better intro

        """
        + "\u{01}"
        + "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\tAda Lovelace\tada@example.com\t1721000000\tAdd the README\twith\ttabs\n"
        + """
        diff --git a/README.md b/README.md
        --- /dev/null
        +++ b/README.md
        @@ -0,0 +2,1 @@
        +Intro line
        +\u{01}not a commit line even with the sentinel
        """

    @Test func parsesCommitLinesAndSkipsPatchBodies() {
        let commits = LocalGit.parseLineLog(Self.fixture)
        #expect(commits.count == 2)
        #expect(commits[0].sha == sha("b"))
        #expect(commits[0].authorName == "Grace Hopper")
        #expect(commits[0].authorEmail == "grace@example.com")
        #expect(commits[0].date == Date(timeIntervalSince1970: 1_722_000_000))
        #expect(commits[0].summary == "Clarify the intro")
        // Tabs inside the subject are preserved.
        #expect(commits[1].summary == "Add the README\twith\ttabs")
    }

    @Test func sentinelInPatchContentIsRejectedBySHAValidation() {
        let commits = LocalGit.parseLineLog(Self.fixture)
        #expect(!commits.contains { $0.authorName.contains("not a commit") })
    }

    @Test func emptyAndGarbageInput() {
        #expect(LocalGit.parseLineLog("").isEmpty)
        #expect(LocalGit.parseLineLog("diff --git a/x b/x\n+added").isEmpty)
        // Sentinel with too few fields or a bad sha is dropped.
        #expect(LocalGit.parseLineLog("\u{01}deadbeef\tAda\n").isEmpty)
    }
}

@Suite struct HistoryBuilderTests {
    @Test func buildsEntriesWithAvatarTiering() {
        let viewer = ViewerIdentity(login: "jedijashwa", name: "Josh Riesenbach",
                                    avatarUrl: "https://avatars.example/viewer")
        let commits = [
            makeCommit(sha("a"), "Josh Riesenbach", daysAgo: 2, summary: "Latest",
                       email: "1+jedijashwa@users.noreply.github.com",
                       url: "https://github.com/o/r/commit/\(sha("a"))"),
            makeCommit(sha("b"), "Grace Hopper", daysAgo: 9, summary: "Older",
                       userAvatar: "https://avatars.example/grace"),
        ]
        let entries = HistoryBuilder.entries(from: commits, viewer: viewer, now: testNow)
        #expect(entries.count == 2)
        #expect(entries[0].shortSHA == "aaaaaaa")
        #expect(entries[0].dateLabel == "2 days ago")
        #expect(entries[0].headline == "Latest")
        // Viewer tier catches the noreply-email commit.
        #expect(entries[0].avatarUrl == "https://avatars.example/viewer")
        #expect(entries[0].url == "https://github.com/o/r/commit/\(sha("a"))")
        #expect(entries[1].avatarUrl == "https://avatars.example/grace")
        #expect(entries[1].dateLabel == "1 week ago")
    }

    static func entry(_ sha: String) -> HistoryEntry {
        HistoryEntry(sha: sha, shortSHA: String(sha.prefix(7)), author: "A",
                     dateLabel: nil, headline: "", avatarUrl: nil, url: nil)
    }

    @Test func partitionPutsPRCommitsFirstThenBase() {
        let entries = [Self.entry(sha("a")), Self.entry(sha("b")),
                       Self.entry(sha("c")), Self.entry(sha("d"))]
        // "b" and "d" are on the PR branch; the interleaved order collapses
        // to PR commits first, both sides keeping their own order.
        let result = HistoryBuilder.partition(entries: entries,
                                              prSHAs: [sha("b"), sha("d")])
        #expect(result.entries.map(\.sha) == [sha("b"), sha("d"), sha("a"), sha("c")])
        #expect(result.baseStart == 2)
    }

    @Test func partitionWithoutBaseCommitsHasNoDivider() {
        let entries = [Self.entry(sha("a")), Self.entry(sha("b"))]
        let all = HistoryBuilder.partition(entries: entries,
                                           prSHAs: [sha("a"), sha("b")])
        #expect(all.entries.map(\.sha) == [sha("a"), sha("b")])
        #expect(all.baseStart == nil)
    }

    @Test func partitionWithoutPRCommitsHasNoDivider() {
        let entries = [Self.entry(sha("a")), Self.entry(sha("b"))]
        let none = HistoryBuilder.partition(entries: entries, prSHAs: [sha("f")])
        #expect(none.entries.map(\.sha) == [sha("a"), sha("b")])
        #expect(none.baseStart == nil)
    }
}

@Suite struct GitHubBlameDecodeTests {
    static let fixture = """
    {
      "data": {
        "repository": {
          "object": {
            "blame": {
              "ranges": [
                {
                  "startingLine": 1,
                  "endingLine": 12,
                  "commit": {
                    "oid": "0123456789abcdef0123456789abcdef01234567",
                    "messageHeadline": "Add contributing guide",
                    "committedDate": "2026-06-27T10:15:00Z",
                    "url": "https://github.com/github/docs/commit/0123456789abcdef0123456789abcdef01234567",
                    "author": {
                      "name": "Mona Lisa",
                      "email": "mona@example.com",
                      "avatarUrl": "https://avatars.githubusercontent.com/u/1?size=40",
                      "user": { "login": "mona", "avatarUrl": "https://avatars.githubusercontent.com/u/1?v=4" }
                    }
                  }
                },
                {
                  "startingLine": 13,
                  "endingLine": 20,
                  "commit": {
                    "oid": "fedcba9876543210fedcba9876543210fedcba98",
                    "messageHeadline": "Fix typos",
                    "committedDate": "2026-07-01T08:00:00Z",
                    "url": "https://github.com/github/docs/commit/fedcba9876543210fedcba9876543210fedcba98",
                    "author": {
                      "name": null,
                      "email": "octo@private.invalid",
                      "avatarUrl": "https://avatars.githubusercontent.com/u/2?size=40",
                      "user": null
                    }
                  }
                }
              ]
            }
          }
        }
      }
    }
    """

    @Test func decodesRangesAndCommits() throws {
        let ranges = try GitHubBlame.parse(Data(Self.fixture.utf8))
        #expect(ranges.count == 2)
        #expect(ranges[0].start == 1)
        #expect(ranges[0].end == 12)
        #expect(ranges[0].commit.authorName == "Mona Lisa")
        #expect(ranges[0].commit.authorEmail == "mona@example.com")
        // Account avatar and email-derived avatar land in separate tiers.
        #expect(ranges[0].commit.userAvatarUrl == "https://avatars.githubusercontent.com/u/1?v=4")
        #expect(ranges[0].commit.actorAvatarUrl == "https://avatars.githubusercontent.com/u/1?size=40")
        #expect(ranges[0].commit.summary == "Add contributing guide")
        #expect(ranges[0].commit.date == ISO8601DateFormatter().date(from: "2026-06-27T10:15:00Z"))
        // No matched user: no account avatar, but the actor avatar survives.
        #expect(ranges[1].commit.authorName == "unknown")
        #expect(ranges[1].commit.userAvatarUrl == nil)
        #expect(ranges[1].commit.actorAvatarUrl == "https://avatars.githubusercontent.com/u/2?size=40")
        #expect(ranges[1].commit.url?.contains("/commit/fedcba98") == true)
    }

    @Test func missingBlameThrows() {
        let empty = #"{"data": {"repository": {"object": null}}}"#
        #expect(throws: GitHubBlame.ParseError.self) {
            _ = try GitHubBlame.parse(Data(empty.utf8))
        }
    }

    @Test func queryRequestsAllAvatarTiers() {
        #expect(GitHubBlame.query.contains("user { login avatarUrl }"))
        #expect(GitHubBlame.query.contains("email"))
    }
}

@Suite struct GitHubHistoryDecodeTests {
    static let fixture = """
    {
      "data": {
        "repository": {
          "object": {
            "history": {
              "nodes": [
                {
                  "oid": "1111111111111111111111111111111111111111",
                  "messageHeadline": "Newest change",
                  "committedDate": "2026-07-10T08:00:00Z",
                  "url": "https://github.com/o/r/commit/1111111111111111111111111111111111111111",
                  "author": {
                    "name": "Mona Lisa",
                    "email": "mona@example.com",
                    "avatarUrl": "https://avatars.githubusercontent.com/u/1?size=40",
                    "user": { "login": "mona", "avatarUrl": "https://avatars.githubusercontent.com/u/1?v=4" }
                  }
                },
                {
                  "oid": "2222222222222222222222222222222222222222",
                  "messageHeadline": "Older change",
                  "committedDate": "2026-06-01T08:00:00Z",
                  "url": "https://github.com/o/r/commit/2222222222222222222222222222222222222222",
                  "author": { "name": "Ghost", "email": null, "avatarUrl": null, "user": null }
                }
              ]
            }
          }
        }
      }
    }
    """

    @Test func decodesHistoryCommits() throws {
        let commits = try GitHubHistory.parse(Data(Self.fixture.utf8))
        #expect(commits.count == 2)
        #expect(commits[0].sha == "1111111111111111111111111111111111111111")
        #expect(commits[0].summary == "Newest change")
        #expect(commits[0].userAvatarUrl == "https://avatars.githubusercontent.com/u/1?v=4")
        #expect(commits[0].url?.contains("/commit/1111") == true)
        #expect(commits[1].authorName == "Ghost")
        #expect(commits[1].userAvatarUrl == nil)
        #expect(commits[1].actorAvatarUrl == nil)
    }

    @Test func missingHistoryThrows() {
        let empty = #"{"data": {"repository": {"object": null}}}"#
        #expect(throws: GitHubHistory.ParseError.self) {
            _ = try GitHubHistory.parse(Data(empty.utf8))
        }
    }
}
