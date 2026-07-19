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

    @Test func normalizeResolvesDotSegments() {
        #expect(DocDoctor.normalize("docs/../img/./a.png") == "img/a.png")
        #expect(DocDoctor.normalize("./x.md") == "x.md")
    }
}
