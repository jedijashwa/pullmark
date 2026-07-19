import Foundation
import Testing
@testable import PullMark

@Suite struct PathAbbreviatorTests {
    let home = "/Users/alice"

    @Test func abbreviatesHomePrefix() {
        #expect(PathAbbreviator.abbreviate("/Users/alice/Code/pullmark", home: home)
                == "~/Code/pullmark")
        #expect(PathAbbreviator.abbreviate("/Users/alice/doc.md", home: home) == "~/doc.md")
    }

    @Test func leavesNonHomePathsUntouched() {
        #expect(PathAbbreviator.abbreviate("/tmp/notes", home: home) == "/tmp/notes")
        #expect(PathAbbreviator.abbreviate("/Users/bob/Code", home: home) == "/Users/bob/Code")
        // Sibling directory sharing the home path as a string prefix must not match.
        #expect(PathAbbreviator.abbreviate("/Users/alice-backup/x", home: home)
                == "/Users/alice-backup/x")
    }

    @Test func exactHomeBecomesTilde() {
        #expect(PathAbbreviator.abbreviate("/Users/alice", home: home) == "~")
        // Trailing slash on the configured home is tolerated.
        #expect(PathAbbreviator.abbreviate("/Users/alice", home: "/Users/alice/") == "~")
        #expect(PathAbbreviator.abbreviate("/Users/alice/Code", home: "/Users/alice/")
                == "~/Code")
    }

    @Test func degenerateHomesAreIgnored() {
        #expect(PathAbbreviator.abbreviate("/anything", home: "") == "/anything")
        #expect(PathAbbreviator.abbreviate("/anything", home: "/") == "/anything")
    }

    @Test func defaultHomeIsCurrentUsers() {
        let inside = NSHomeDirectory() + "/some/file.md"
        #expect(PathAbbreviator.abbreviate(inside) == "~/some/file.md")
    }
}
