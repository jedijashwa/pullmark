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
        #expect(ranges[0].commit.summary == "Add the README")
        #expect(ranges[0].commit.date == Date(timeIntervalSince1970: 1_721_000_000))
        #expect(ranges[1].start == 3)
        #expect(ranges[1].end == 3)
        #expect(ranges[1].commit.authorName == "Grace Hopper")
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

@Suite struct BlameMapperTests {
    static let now = Date(timeIntervalSince1970: 1_724_000_000)

    static func commit(_ sha: String, _ author: String, daysAgo: Double,
                       summary: String = "", avatar: String? = nil) -> BlameCommit {
        BlameCommit(sha: sha, authorName: author,
                    date: now.addingTimeInterval(-daysAgo * 86400),
                    summary: summary, avatarUrl: avatar,
                    url: "https://github.com/o/r/commit/\(sha)")
    }

    @Test func picksMostRecentCommitPerBlock() {
        let blocks = [MarkdownBlock(text: "# Title", startLine: 1, endLine: 1),
                      MarkdownBlock(text: "Body", startLine: 3, endLine: 5)]
        let old = Self.commit(String(repeating: "a", count: 40), "Ada", daysAgo: 100, summary: "old")
        let recent = Self.commit(String(repeating: "b", count: 40), "Grace", daysAgo: 2, summary: "new")
        let ranges = [BlameRange(start: 1, end: 3, commit: old),
                      BlameRange(start: 4, end: 5, commit: recent)]
        let payloads = BlameMapper.annotations(blocks: blocks, ranges: ranges, now: Self.now)
        #expect(payloads.count == 2)
        // Block 1 only overlaps the old commit.
        #expect(payloads[0].author == "Ada")
        #expect(payloads[0].shortSHA == "aaaaaaa")
        // Block 2 spans both ranges; the most recent commit wins…
        #expect(payloads[1].author == "Grace")
        #expect(payloads[1].headline == "new")
        #expect(payloads[1].dateLabel == "2 days ago")
        #expect(payloads[1].url == "https://github.com/o/r/commit/\(String(repeating: "b", count: 40))")
        // …and the older author stacks as an extra contributor.
        #expect(payloads[1].others == [BlameAuthorPayload(name: "Ada", avatarUrl: nil)])
    }

    @Test func capsContributorsAtThreeDistinctAuthors() {
        let blocks = [MarkdownBlock(text: "big", startLine: 1, endLine: 10)]
        let ranges = (0..<5).map { i in
            BlameRange(start: i * 2 + 1, end: i * 2 + 2,
                       commit: Self.commit(String(repeating: "\(i)", count: 40),
                                           "Author \(i)", daysAgo: Double(i + 1)))
        }
        let payloads = BlameMapper.annotations(blocks: blocks, ranges: ranges, now: Self.now)
        #expect(payloads[0].author == "Author 0") // most recent
        #expect(payloads[0].others?.count == 2)   // capped: 3 avatars total
        #expect(payloads[0].others?.map(\.name) == ["Author 1", "Author 2"])
    }

    @Test func duplicateAuthorAcrossCommitsCountsOnce() {
        let blocks = [MarkdownBlock(text: "b", startLine: 1, endLine: 4)]
        let ranges = [
            BlameRange(start: 1, end: 1, commit: Self.commit(String(repeating: "a", count: 40), "Ada", daysAgo: 1)),
            BlameRange(start: 2, end: 2, commit: Self.commit(String(repeating: "b", count: 40), "Ada", daysAgo: 5)),
            BlameRange(start: 3, end: 4, commit: Self.commit(String(repeating: "c", count: 40), "Grace", daysAgo: 3)),
        ]
        let payloads = BlameMapper.annotations(blocks: blocks, ranges: ranges, now: Self.now)
        #expect(payloads[0].author == "Ada")
        #expect(payloads[0].others?.map(\.name) == ["Grace"])
    }

    @Test func blockOutsideAllRangesHasNoAnnotation() {
        let blocks = [MarkdownBlock(text: "b", startLine: 50, endLine: 60)]
        let ranges = [BlameRange(start: 1, end: 10,
                                 commit: Self.commit(String(repeating: "a", count: 40), "Ada", daysAgo: 1))]
        let payloads = BlameMapper.annotations(blocks: blocks, ranges: ranges, now: Self.now)
        #expect(payloads[0].sha == nil)
        #expect(payloads[0].text == "b")
    }

    @Test func relativeDateLabels() {
        let now = Self.now
        func ago(_ seconds: Double) -> String {
            BlameMapper.relativeLabel(from: now.addingTimeInterval(-seconds), to: now)
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
                    "abbreviatedOid": "0123456",
                    "messageHeadline": "Add contributing guide",
                    "committedDate": "2026-06-27T10:15:00Z",
                    "url": "https://github.com/github/docs/commit/0123456789abcdef0123456789abcdef01234567",
                    "author": {
                      "name": "Mona Lisa",
                      "avatarUrl": "https://avatars.githubusercontent.com/u/1?v=4",
                      "user": { "login": "mona", "url": "https://github.com/mona" }
                    }
                  }
                },
                {
                  "startingLine": 13,
                  "endingLine": 20,
                  "commit": {
                    "oid": "fedcba9876543210fedcba9876543210fedcba98",
                    "abbreviatedOid": "fedcba9",
                    "messageHeadline": "Fix typos",
                    "committedDate": "2026-07-01T08:00:00Z",
                    "url": "https://github.com/github/docs/commit/fedcba9876543210fedcba9876543210fedcba98",
                    "author": {
                      "name": null,
                      "avatarUrl": "https://avatars.githubusercontent.com/u/2?v=4",
                      "user": { "login": "octocat", "url": "https://github.com/octocat" }
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
        #expect(ranges[0].commit.avatarUrl == "https://avatars.githubusercontent.com/u/1?v=4")
        #expect(ranges[0].commit.summary == "Add contributing guide")
        #expect(ranges[0].commit.date == ISO8601DateFormatter().date(from: "2026-06-27T10:15:00Z"))
        // Missing author name falls back to the GitHub login.
        #expect(ranges[1].commit.authorName == "octocat")
        #expect(ranges[1].commit.url?.contains("/commit/fedcba98") == true)
    }

    @Test func missingBlameThrows() {
        let empty = #"{"data": {"repository": {"object": null}}}"#
        #expect(throws: GitHubBlame.ParseError.self) {
            _ = try GitHubBlame.parse(Data(empty.utf8))
        }
    }
}
