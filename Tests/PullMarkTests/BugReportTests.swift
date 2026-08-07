import Foundation
import Testing
@testable import PullMark

@Suite struct BugReportTests {
    @Test func urlPrefillsTemplateFields() throws {
        let url = try #require(BugReport.url(version: "0.28.0-beta.3",
                                             macOSVersion: "macOS 26.5"))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.host == "github.com")
        #expect(components.path == "/jedijashwa/pullmark/issues/new")
        let items = Dictionary(uniqueKeysWithValues:
            (components.queryItems ?? []).map { ($0.name, $0.value) })
        #expect(items["template"] == "1-bug_report.yml")
        #expect(items["version"] == "0.28.0-beta.3")
        #expect(items["macos"] == "macOS 26.5")
    }

    @Test func macOSVersionShape() {
        let v = OperatingSystemVersion(majorVersion: 26, minorVersion: 5, patchVersion: 1)
        #expect(BugReport.macOSVersionString(v) == "macOS 26.5")
    }
}
