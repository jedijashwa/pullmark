import Foundation
import Testing
@testable import PullMark

@Suite("Images folder (rich editor §9)")
struct ImagesFolderTests {
    @Test func detectsTheMostReferencedFolder() {
        let files: [(path: String, text: String)] = [
            ("docs/a.md", "![x](images/a.png) and ![y](images/b.png) and ![z](../assets/c.png)"),
            ("docs/deep/b.md", "<img src=\"../images/d.png\"> ![r](https://example.com/r.png)"),
            ("README.md", "![](assets/logo.png)"),
        ]
        #expect(ImagesFolder.detect(files: files) == "docs/images")
        #expect(ImagesFolder.detect(files: [("a.md", "no images here")]) == nil)
    }

    @Test func destinationPrefersOverrideThenDetectedThenAssets() {
        let root = URL(fileURLWithPath: "/repo")
        let doc = URL(fileURLWithPath: "/repo/docs/guide.md")
        #expect(ImagesFolder.destination(document: doc, root: root, override: "media", detected: "docs/images").path
                == "/repo/media")
        #expect(ImagesFolder.destination(document: doc, root: root, override: nil, detected: "docs/images").path
                == "/repo/docs/images")
        #expect(ImagesFolder.destination(document: doc, root: root, override: nil, detected: nil).path
                == "/repo/docs/guide.assets")
        #expect(ImagesFolder.destination(document: doc, root: nil, override: "media", detected: nil).path
                == "/repo/docs/guide.assets")
    }

    @Test func uniqueNamesAndLinks() {
        #expect(ImagesFolder.uniqueName("photo.png", existing: []) == "photo.png")
        #expect(ImagesFolder.uniqueName("photo.png", existing: ["photo.png"]) == "photo-2.png")
        #expect(ImagesFolder.uniqueName("photo.png", existing: ["photo.png", "photo-2.png"]) == "photo-3.png")
        #expect(ImagesFolder.uniqueName("a/b.png", existing: []) == "a-b.png")
        let doc = URL(fileURLWithPath: "/repo/docs/guide.md")
        #expect(ImagesFolder.relativeLink(from: doc, to: URL(fileURLWithPath: "/repo/docs/images/my photo.png"))
                == "images/my%20photo.png")
        #expect(ImagesFolder.relativeLink(from: doc, to: URL(fileURLWithPath: "/repo/assets/c.png"))
                == "../assets/c.png")
        #expect(ImagesFolder.isInside(URL(fileURLWithPath: "/repo/docs/x.png"), root: URL(fileURLWithPath: "/repo")))
        #expect(!ImagesFolder.isInside(URL(fileURLWithPath: "/repository/x.png"), root: URL(fileURLWithPath: "/repo")))
        #expect(ImagesFolder.pastedName(type: "image/jpeg").hasSuffix(".jpg"))
    }
}
