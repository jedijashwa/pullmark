import Foundation
import Testing
@testable import PullMark

@Suite struct SemVerTests {
    @Test func numericNotLexicographic() {
        #expect(SemVer.isNewer("1.10.0", than: "1.2.3"))
        #expect(!SemVer.isNewer("1.2.3", than: "1.10.0"))
        #expect(SemVer.compare("1.2.3", "1.10.0") == .orderedAscending)
    }

    @Test func vPrefixIgnored() {
        #expect(SemVer.isNewer("v0.2.0", than: "0.1.1"))
        #expect(SemVer.isNewer("0.2.0", than: "v0.1.1"))
        #expect(SemVer.compare("v1.0.0", "1.0.0") == .orderedSame)
    }

    @Test func equalVersions() {
        #expect(SemVer.compare("0.1.1", "0.1.1") == .orderedSame)
        #expect(!SemVer.isNewer("0.1.1", than: "0.1.1"))
    }

    @Test func missingComponentsCountAsZero() {
        #expect(SemVer.compare("1.2", "1.2.0") == .orderedSame)
        #expect(SemVer.isNewer("1.2.1", than: "1.2"))
    }

    @Test func prereleaseAndBuildSuffixesIgnored() {
        #expect(SemVer.compare("1.2.3-beta.1", "1.2.3") == .orderedSame)
        #expect(SemVer.isNewer("v1.3.0-rc.1+build.5", than: "1.2.9"))
        #expect(!SemVer.isNewer("1.2.3+42", than: "1.2.3"))
    }

    @Test func normalizedStripsPrefix() {
        #expect(SemVer.normalized("v0.2.0") == "0.2.0")
        #expect(SemVer.normalized(" 0.2.0 ") == "0.2.0")
    }
}

@Suite struct UpdateReleaseTests {
    @Test func decodesReleaseJSON() throws {
        let json = """
        {
          "tag_name": "v0.2.0",
          "name": "PullMark 0.2.0",
          "html_url": "https://github.com/jedijashwa/pullmark/releases/tag/v0.2.0",
          "body": "## Highlights\\n\\n- In-app update checks\\n- What's New sheet",
          "draft": false,
          "prerelease": false,
          "assets": []
        }
        """
        let release = try JSONDecoder().decode(UpdateRelease.self, from: Data(json.utf8))
        #expect(release.tagName == "v0.2.0")
        #expect(release.htmlUrl == "https://github.com/jedijashwa/pullmark/releases/tag/v0.2.0")
        #expect(release.body?.contains("In-app update checks") == true)
        #expect(release.draft == false)
        #expect(release.prerelease == false)
    }

    @Test func decodesReleaseListWithMissingOptionalFields() throws {
        let json = """
        [
          {"tag_name": "v0.2.0", "html_url": "https://example.com/2", "body": "notes"},
          {"tag_name": "v0.1.1", "html_url": "https://example.com/1", "body": null}
        ]
        """
        let releases = try JSONDecoder().decode([UpdateRelease].self, from: Data(json.utf8))
        #expect(releases.count == 2)
        #expect(releases[1].body == nil)
        #expect(releases[0].prerelease == nil)
    }

    @Test func betweenSelectsRangeNewestFirst() {
        func release(_ tag: String, prerelease: Bool = false) -> UpdateRelease {
            UpdateRelease(tagName: tag, body: "notes for \(tag)",
                          htmlUrl: "https://example.com/\(tag)",
                          prerelease: prerelease, draft: false)
        }
        let releases = [
            release("v0.1.0"), release("v0.1.1"), release("v0.2.0"),
            release("v0.3.0"), release("v0.3.1-beta.1", prerelease: true),
        ]
        let picked = UpdateRelease.between(releases, after: "0.1.0", upTo: "0.3.0")
        #expect(picked.map(\.tagName) == ["v0.3.0", "v0.2.0", "v0.1.1"])
    }
}
