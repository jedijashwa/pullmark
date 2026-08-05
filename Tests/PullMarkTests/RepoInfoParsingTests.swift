import Testing
@testable import PullMark

@Suite struct RepoInfoParsingTests {
    @Test func remotesOriginFirstAndDeduplicated() {
        let out = """
        upstream\thttps://github.com/obra/superpowers.git (fetch)
        upstream\thttps://github.com/obra/superpowers.git (push)
        origin\tgit@github.com:jedijashwa/superpowers.git (fetch)
        origin\tgit@github.com:jedijashwa/superpowers.git (push)
        """
        let repos = LocalGit.parseRemotesOutput(out)
        #expect(repos == [LocalGit.GitHubRepoID(owner: "jedijashwa", repo: "superpowers"),
                          LocalGit.GitHubRepoID(owner: "obra", repo: "superpowers")])
    }

    @Test func nonGitHubRemotesIgnored() {
        let out = """
        origin\thttps://gitlab.com/o/r.git (fetch)
        backup\t/Volumes/backup/repo.git (fetch)
        """
        #expect(LocalGit.parseRemotesOutput(out).isEmpty)
    }

    @Test func repoIDMatchingIsCaseInsensitive() {
        let id = LocalGit.GitHubRepoID(owner: "JediJashwa", repo: "PullMark")
        #expect(id.matches(owner: "jedijashwa", repo: "pullmark"))
        #expect(!id.matches(owner: "jedijashwa", repo: "pullmark-livetest"))
    }

    @Test func worktreeListParses() {
        let out = """
        worktree /Users/j/Code/pullmark
        HEAD 0123456789012345678901234567890123456789
        branch refs/heads/main

        worktree /Users/j/Code/pullmark-feature
        HEAD abcdefabcdefabcdefabcdefabcdefabcdefabcd
        branch refs/heads/feature/chips

        worktree /Users/j/Code/pullmark-detached
        HEAD abcdefabcdefabcdefabcdefabcdefabcdefabcd
        detached
        """
        let worktrees = LocalGit.parseWorktreeList(out)
        #expect(worktrees == [
            LocalGit.Worktree(path: "/Users/j/Code/pullmark", branch: "main"),
            LocalGit.Worktree(path: "/Users/j/Code/pullmark-feature", branch: "feature/chips"),
            LocalGit.Worktree(path: "/Users/j/Code/pullmark-detached", branch: nil),
        ])
    }
}
