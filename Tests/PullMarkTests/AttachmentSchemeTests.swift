import Foundation
import Testing
@testable import PullMark

@Suite struct AttachmentSchemeTests {

    // MARK: - Path validation (the scheme must never proxy arbitrary URLs)

    @Test func acceptsUserAttachmentsForm() {
        let url = URL(string: "pullmark-attachment:///user-attachments/assets/f258cef7-9ca9-47dc-a3e7-d728fd144547")!
        #expect(AttachmentSchemeHandler.attachmentPath(from: url)
                == "user-attachments/assets/f258cef7-9ca9-47dc-a3e7-d728fd144547")
    }

    @Test func acceptsLegacyRepoScopedForm() {
        let url = URL(string: "pullmark-attachment:///gpt-engineer-org/gpt-engineer/assets/4467025/40d0a9a8-82d0-4432-9376-136df0d57c99")!
        #expect(AttachmentSchemeHandler.attachmentPath(from: url)
                == "gpt-engineer-org/gpt-engineer/assets/4467025/40d0a9a8-82d0-4432-9376-136df0d57c99")
    }

    @Test func rejectsArbitraryGitHubPaths() {
        // Anything that isn't exactly an attachment form would ride the
        // user's token to arbitrary github.com endpoints — refuse.
        for path in ["/jedijashwa/pullmark/releases/download/v1/app.zip",
                     "/user-attachments/assets/f258cef7/extra",
                     "/user-attachments/assets/",
                     "/a/b/assets/notdigits/f258cef7-9ca9-47dc-a3e7-d728fd144547",
                     "/a/b/c/assets/1/f258cef7-9ca9-47dc-a3e7-d728fd144547",
                     "/login"] {
            let url = URL(string: "pullmark-attachment://" + path)!
            #expect(AttachmentSchemeHandler.attachmentPath(from: url) == nil, "accepted \(path)")
        }
    }

    @Test func rejectsTraversalSegments() {
        let url = URL(string: "pullmark-attachment:///user-attachments/assets/../../../settings")!
        #expect(AttachmentSchemeHandler.attachmentPath(from: url) == nil)
    }

    // MARK: - Export

    @Test func exportInlinesCachedAttachmentBytes() {
        let html = "<img src=\"pullmark-attachment:///user-attachments/assets/f258cef7-9ca9-47dc-a3e7-d728fd144547\" alt=\"shot\">"
        let out = HTMLExport.inliningImages(html) { src in
            #expect(src.hasPrefix("pullmark-attachment:"))
            return (Data([0x89, 0x50]), "image/png")
        }
        #expect(out.contains("src=\"data:image/png;base64,"))
        #expect(!out.contains("pullmark-attachment:"))
    }

    @Test func exportRestoresOriginalURLForUnfetchedAttachments() {
        // An attachment the live page never managed to fetch must not leave
        // a dead app-scheme reference in the export — restore the original
        // URL so a browser with a GitHub session can still render it.
        let html = "<img src=\"pullmark-attachment:///user-attachments/assets/f258cef7-9ca9-47dc-a3e7-d728fd144547\">"
        let inlined = HTMLExport.inliningImages(html) { _ in nil }
        let out = HTMLExport.restoringAttachmentURLs(inlined)
        #expect(out.contains("src=\"https://github.com/user-attachments/assets/f258cef7-9ca9-47dc-a3e7-d728fd144547\""))
        #expect(!out.contains("pullmark-attachment:"))
    }
}
