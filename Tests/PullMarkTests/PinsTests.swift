import Foundation
import Testing
@testable import PullMark

@Suite("Pins and sidebar naming")
struct PinsTests {
    @Test func pinTitleFallsBackToName() {
        let folder = Pin(kind: .folder, path: "/Users/dev/Code/repo/docs/guides")
        #expect(folder.title == "guides")
        #expect(folder.id == "folder:/Users/dev/Code/repo/docs/guides")
        let file = Pin(kind: .file, path: "/Users/dev/notes/runbook.md", alias: "Runbook")
        #expect(file.title == "Runbook")
        #expect(file.name == "runbook.md")
    }

    @Test func pinListRoundTripsThroughJSON() {
        let pins = [
            Pin(kind: .folder, path: "/a/b", alias: "B", viewMode: "tree", expanded: ["", "x"]),
            Pin(kind: .file, path: "/a/c.md"),
        ]
        let data = try? #require(Pin.encodeList(pins))
        #expect(Pin.decodeList(data) == pins)
        #expect(Pin.decodeList(nil).isEmpty)
        #expect(Pin.decodeList(Data("garbage".utf8)).isEmpty)
    }

    @Test func aliasedEntriesAlwaysShowTheirPath() {
        let ids = SidebarNaming.entriesNeedingPath([
            .init(id: "1", title: "Runbook", aliased: true),
            .init(id: "2", title: "docs", aliased: false),
        ])
        #expect(ids == ["1"])
    }

    @Test func titleTwinsShowTheirPathsCaseInsensitively() {
        let ids = SidebarNaming.entriesNeedingPath([
            .init(id: "1", title: "docs", aliased: false),
            .init(id: "2", title: "Docs", aliased: false),
            .init(id: "3", title: "guides", aliased: false),
        ])
        #expect(ids == ["1", "2"])
    }

    @Test func aliasNormalization() {
        #expect(SidebarNaming.normalizedAlias("  Runbook ", name: "runbook.md") == "Runbook")
        #expect(SidebarNaming.normalizedAlias("", name: "docs") == nil)
        #expect(SidebarNaming.normalizedAlias("   ", name: "docs") == nil)
        #expect(SidebarNaming.normalizedAlias("docs", name: "docs") == nil)
    }

    @Test func reopenMigrationKeepsExistingUsersOn() {
        #expect(SessionReopen.migratedValue(storedSetting: nil, hasSnapshot: true) == true)
        #expect(SessionReopen.migratedValue(storedSetting: nil, hasSnapshot: false) == false)
        #expect(SessionReopen.migratedValue(storedSetting: false, hasSnapshot: true) == false)
        #expect(SessionReopen.migratedValue(storedSetting: true, hasSnapshot: false) == true)
    }
}
