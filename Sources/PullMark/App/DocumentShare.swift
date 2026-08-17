import AppKit

/// The document as ONE pasteboard item wearing every useful flavor,
/// richest first: the file itself, the rendered HTML, and the Markdown
/// source as plain text. The share sheet's built-in Copy row writes the
/// picker's items to the pasteboard verbatim — handing it a bare file
/// URL meant pasting into a text field produced the file's NAME (#72).
/// With this item every paste target takes its preferred flavor:
/// Finder the file, rich editors and chat composers the HTML, plain
/// fields the Markdown source. Deliberately no RTF: receivers convert
/// HTML at paste time anyway (verified against TextEdit), and
/// generating RTF up front cost 0.2–1s of main thread per Share click
/// (measured) for nothing.
final class DocumentShareItem: NSObject, NSPasteboardWriting {
    let fileURL: URL?
    let html: String?
    let markdown: String
    /// Share-sheet header identity (via NSPreviewRepresentingActivityItem).
    let title: String

    init(fileURL: URL?, html: String?, markdown: String, title: String) {
        self.fileURL = fileURL
        self.html = html
        self.markdown = markdown
        self.title = title
    }

    /// Flavor order is the declaration order — richest first, so
    /// receivers that honor it (most do) pick the best they support.
    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        var types: [NSPasteboard.PasteboardType] = []
        if fileURL != nil { types.append(.fileURL) }
        if html != nil { types.append(.html) }
        types.append(.string)
        return types
    }

    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        switch type {
        case .fileURL: return fileURL?.absoluteString
        case .html: return html
        case .string: return markdown
        default: return nil
        }
    }
}

/// Builders behind the share sheet: the same multi-flavor item backs
/// the sheet's services and its Copy row, so every route out of the
/// app agrees about what the document "is".
enum DocumentShare {
    /// Assembles the full item from the live page. The HTML flavor
    /// comes from the exporter's self-contained page (so styling and
    /// embedded images match Export as HTML); when the DOM can't be
    /// read the item degrades to file + Markdown, never to nothing.
    @MainActor
    static func buildItem(for document: ActiveDocument, fileURL: URL?,
                          completion: @escaping (DocumentShareItem) -> Void) {
        document.proxy.pageDOM { dom in
            let html = dom.map { DocumentExport.selfContainedHTML(dom: $0, document: document) }
            completion(DocumentShareItem(
                fileURL: fileURL,
                html: html,
                markdown: document.markdown,
                title: fileURL?.lastPathComponent
                    ?? document.exportBaseName + ".md"))
        }
    }

    /// Copy as Markdown (⌥⌘C and the Share menu): the page maps the
    /// selection to covered source lines (whole-block granularity),
    /// Swift slices the original markdown, plain text lands on the
    /// pasteboard. No selection copies the whole document source.
    @MainActor
    static func copyMarkdown(from document: ActiveDocument) {
        document.proxy.selectionSourceLineRange { range in
            let source = MarkdownCopy.source(of: document.markdown, lineRange: range)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(source, forType: .string)
        }
    }

    @MainActor
    static func copy(item: DocumentShareItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }

    /// Presents the system share sheet anchored to a view, holding the
    /// picker (and releasing it after the choice) — NSSharingServicePicker
    /// is not retained by the sheet it shows.
    @MainActor
    static func presentSheet(item: DocumentShareItem, from view: NSView) {
        let icon = item.fileURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSImage(systemSymbolName: "doc.richtext", accessibilityDescription: nil)
            ?? NSImage()
        let wrapped = NSPreviewRepresentingActivityItem(
            item: item, title: item.title, image: nil, icon: icon)
        SharePresenter.shared.present(items: [wrapped], copyItem: item, from: view)
    }

    @MainActor
    static func presentSheet(url: URL, from view: NSView) {
        SharePresenter.shared.present(items: [url], from: view)
    }
}

/// Owns the live picker: something must keep it alive while the sheet
/// is up, and the delegate callback is the release point.
@MainActor
final class SharePresenter: NSObject, NSSharingServicePickerDelegate {
    static let shared = SharePresenter()
    private var picker: NSSharingServicePicker?
    /// The multi-flavor item behind the injected Copy row: the Tahoe
    /// sheet shows no built-in Copy for custom pasteboard items
    /// (verified live, Aug 2026) — so the sheet gets one of ours,
    /// writing the same file + rich + plain flavors as everything else.
    private var copyItem: DocumentShareItem?

    func present(items: [Any], copyItem: DocumentShareItem? = nil, from view: NSView) {
        self.copyItem = copyItem
        let picker = NSSharingServicePicker(items: items)
        picker.delegate = self
        self.picker = picker
        picker.show(relativeTo: .zero, of: view, preferredEdge: .minY)
    }

    nonisolated func sharingServicePicker(
        _ sharingServicePicker: NSSharingServicePicker,
        sharingServicesForItems items: [Any],
        proposedSharingServices proposed: [NSSharingService]
    ) -> [NSSharingService] {
        MainActor.assumeIsolated {
            guard let item = copyItem else { return proposed }
            let icon = NSImage(systemSymbolName: "doc.on.doc",
                               accessibilityDescription: "Copy") ?? NSImage()
            let copy = NSSharingService(title: "Copy", image: icon,
                                        alternateImage: nil) {
                DocumentShare.copy(item: item)
            }
            return [copy] + proposed
        }
    }

    nonisolated func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker,
                                          didChoose service: NSSharingService?) {
        Task { @MainActor in
            // Identity-gated: this cleanup runs a beat after dismissal,
            // by which time a NEW picker may already be up (Share clicked
            // again, any window) — releasing that one would tear down a
            // live sheet.
            guard self.picker === sharingServicePicker else { return }
            self.picker = nil
            self.copyItem = nil
        }
    }
}
