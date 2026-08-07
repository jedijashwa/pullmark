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

    @Test func urlCarriesWhatHappenedWhenGiven() throws {
        let url = try #require(BugReport.url(
            version: "0.27.0", macOSVersion: "macOS 26.5",
            whatHappened: "Clicked pullmark://settings/experimental/margin-notes"))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues:
            (components.queryItems ?? []).map { ($0.name, $0.value) })
        #expect((items["what-happened"] ?? nil)?.contains("margin-notes") == true)
    }

    @Test func titleOnlyWhenGiven() throws {
        let plain = try #require(BugReport.url(version: "1", macOSVersion: "macOS 26"))
        #expect(plain.absoluteString.contains("title=") == false)
        let titled = try #require(BugReport.url(
            version: "1", macOSVersion: "macOS 26",
            title: "Unsupported link: pullmark://x"))
        let items = Dictionary(uniqueKeysWithValues:
            (URLComponents(url: titled, resolvingAgainstBaseURL: false)?
                .queryItems ?? []).map { ($0.name, $0.value) })
        #expect((items["title"] ?? nil) == "Unsupported link: pullmark://x")
    }

    @Test func macOSVersionShape() {
        let v = OperatingSystemVersion(majorVersion: 26, minorVersion: 5, patchVersion: 1)
        #expect(BugReport.macOSVersionString(v) == "macOS 26.5")
    }
}
