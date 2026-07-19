import Testing
@testable import PullMark

@Suite("Doc Doctor")
struct DocDoctorTests {
    private func scan(_ corpus: [String: String], extra: [String] = []) -> [DocDoctor.Issue] {
        DocDoctor.scan(files: Array(corpus.keys) + extra, read: { corpus[$0] })
    }

    @Test func flagsBrokenLinksImagesAndAnchors() {
        let issues = scan([
            "docs/guide.md": """
            # Guide

            Good: [setup](setup.md#install) and ![ok](../img/ok.png).
            Bad link: [gone](missing.md)
            Bad image: ![x](img/nope.png)
            Bad anchor: [s](setup.md#nonexistent)
            Bad self anchor: [here](#nowhere)
            """,
            "docs/setup.md": "# Setup\n\n## Install\n\n[back](guide.md)",
        ], extra: ["img/ok.png"])
        let kinds = issues.map { "\($0.kind.rawValue):\($0.target)" }.sorted()
        #expect(kinds == [
            "Broken link:missing.md",
            "Dead anchor:#nowhere",
            "Dead anchor:setup.md#nonexistent",
            "Missing image:img/nope.png",
        ])
        // Line numbers point at the offending references.
        #expect(issues.first { $0.target == "missing.md" }?.line == 4)
    }

    @Test func ignoresExternalURLsAndCodeFences() {
        let issues = scan([
            "a.md": """
            [ext](https://example.com/x.md) [mail](mailto:x@y.z)

            ```
            [not real](fake.md)
            ```
            """,
        ])
        #expect(issues.isEmpty)
    }

    @Test func findsOrphanPagesButNotRootsOrEntryPoints() {
        let issues = scan([
            "README.md": "[guide](docs/guide.md)",
            "docs/guide.md": "# G",
            "docs/floating.md": "# Nobody links here",
            "toplevel.md": "# Entry point, fine",
        ])
        #expect(issues.map(\.target) == ["docs/floating.md"])
        #expect(issues.first?.kind == .orphanPage)
    }

    @Test func parsesAngleBracketAndParenTargets() {
        let refs = DocDoctor.references(in: "[a](<sp aced.md>) [b](one(x).md) ![c](img.png \"t\")")
        #expect(refs.map(\.target) == ["sp aced.md", "one(x).md", "img.png"])
        #expect(refs.map(\.label) == ["a", "b", "c"])
    }

    @Test func percentEncodedTargetsResolve() {
        let issues = scan([
            "a.md": "[x](sp%20aced.md) [y](#my-heading)\n\n# My Heading",
            "sp aced.md": "# S\n\n[back](a.md)",
        ])
        #expect(issues.isEmpty)
    }

    @Test func linksEscapingTheRootAreSkippedNotGuessed() {
        // The un-verifiable out-of-root link is skipped (no broken-link
        // guess); the page itself being an orphan is a separate, true fact.
        let issues = scan(["docs/a.md": "[out](../../elsewhere.md)"])
        #expect(!issues.contains { $0.kind == .brokenLink })
    }

    @Test func normalizeResolvesDotSegments() {
        #expect(DocDoctor.normalize("docs/../img/./a.png") == "img/a.png")
        #expect(DocDoctor.normalize("../outside.md") == nil)
        #expect(DocDoctor.normalize("./x.md") == "x.md")
    }
}
