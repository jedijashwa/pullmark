import Foundation

struct PullRequestRef: Equatable, Hashable {
    let owner: String
    let repo: String
    let number: Int

    /// Accepts full GitHub URLs (`https://github.com/owner/repo/pull/123`,
    /// with or without trailing path segments like `/files`), bare
    /// `owner/repo/pull/123` paths, and the short `owner/repo#123` form.
    static func parse(_ input: String) -> PullRequestRef? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let patterns = [
            #"^(?:https?://)?(?:www\.)?github\.com/([\w.-]+)/([\w.-]+)/pull/(\d+)"#,
            // Anchored so a plausible filename ("docs/setup/pull/3.md")
            // can't parse as a PR reference — ⌘K feeds arbitrary queries here.
            #"^([\w.-]+)/([\w.-]+)/pull/(\d+)(?:[/?#].*)?$"#,
            #"^([\w.-]+)/([\w.-]+)#(\d+)$"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(s.startIndex..., in: s)
            guard let match = regex.firstMatch(in: s, range: range),
                  let ownerRange = Range(match.range(at: 1), in: s),
                  let repoRange = Range(match.range(at: 2), in: s),
                  let numberRange = Range(match.range(at: 3), in: s),
                  let number = Int(s[numberRange])
            else { continue }
            return PullRequestRef(owner: String(s[ownerRange]), repo: String(s[repoRange]), number: number)
        }
        return nil
    }
}
