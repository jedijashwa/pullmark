import Testing
@testable import PullMark

@Suite struct PullRequestRefTests {
    @Test func fullURL() {
        #expect(PullRequestRef.parse("https://github.com/apple/swift/pull/12345")
                == PullRequestRef(owner: "apple", repo: "swift", number: 12345))
    }

    @Test func urlWithTrailingSegments() {
        #expect(PullRequestRef.parse("https://github.com/my-org/my.repo/pull/7/files#diff-abc")
                == PullRequestRef(owner: "my-org", repo: "my.repo", number: 7))
    }

    @Test func urlWithoutScheme() {
        #expect(PullRequestRef.parse("github.com/a/b/pull/1")
                == PullRequestRef(owner: "a", repo: "b", number: 1))
    }

    @Test func shortForm() {
        #expect(PullRequestRef.parse("rails/rails#100")
                == PullRequestRef(owner: "rails", repo: "rails", number: 100))
    }

    @Test func barePathForm() {
        #expect(PullRequestRef.parse("owner/repo/pull/42")
                == PullRequestRef(owner: "owner", repo: "repo", number: 42))
    }

    @Test func whitespaceIsTrimmed() {
        #expect(PullRequestRef.parse("  https://github.com/a/b/pull/2  ")
                == PullRequestRef(owner: "a", repo: "b", number: 2))
    }

    @Test func invalidInputs() {
        #expect(PullRequestRef.parse("") == nil)
        #expect(PullRequestRef.parse("https://github.com/owner/repo") == nil)
        #expect(PullRequestRef.parse("https://github.com/owner/repo/issues/5") == nil)
        #expect(PullRequestRef.parse("not a pr at all") == nil)
    }

    @Test func bareFormIsAnchoredAgainstFilenames() {
        // ⌘K feeds arbitrary queries through parse — a plausible file path
        // must never sprout a pull request.
        #expect(PullRequestRef.parse("docs/setup/pull/3.md") == nil)
        #expect(PullRequestRef.parse("a/b/pull/12.backup") == nil)
        // Real bare forms, with or without trailing URL-ish segments, still parse.
        #expect(PullRequestRef.parse("owner/repo/pull/123")
                == PullRequestRef(owner: "owner", repo: "repo", number: 123))
        #expect(PullRequestRef.parse("owner/repo/pull/123/files")
                == PullRequestRef(owner: "owner", repo: "repo", number: 123))
    }
}
