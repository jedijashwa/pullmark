import AppKit
import UniformTypeIdentifiers

/// File-menu export of the currently rendered document: PDF via WebKit's
/// createPDF on the live web view, HTML as a self-contained single file
/// (styles inlined, scripts stripped, app-scheme images embedded). The DOM
/// post-processing itself is pure (HTMLExport); this layer adds the save
/// panel, the bundle reads, and the image byte lookups.
@MainActor
enum DocumentExport {

    static func exportPDF(_ document: ActiveDocument, onError: @escaping (String) -> Void) {
        guard let url = savePanelURL(type: .pdf, suggestedName: document.exportBaseName + ".pdf")
        else { return }
        document.proxy.pdfData { result in
            switch result {
            case .success(let data):
                write(data, to: url, onError: onError)
            case .failure(let error):
                onError("Could not create the PDF: \(error.localizedDescription)")
            }
        }
    }

    static func exportHTML(_ document: ActiveDocument, onError: @escaping (String) -> Void) {
        guard let url = savePanelURL(type: .html, suggestedName: document.exportBaseName + ".html")
        else { return }
        document.proxy.pageDOM { dom in
            guard let dom else {
                onError("Could not read the rendered page.")
                return
            }
            let html = selfContainedHTML(dom: dom, document: document)
            write(Data(html.utf8), to: url, onError: onError)
        }
    }

    /// Assembles the standalone page from the live DOM: bundle stylesheets
    /// are inlined (KaTeX only when the page contains math, with its fonts
    /// embedded so formulas render anywhere), and local/remote images are
    /// embedded when their bytes are on hand.
    static func selfContainedHTML(dom: String, document: ActiveDocument) -> String {
        let mathPresent = dom.contains("class=\"katex")
        return HTMLExport.selfContainedPage(dom: dom, css: { href in
            if href.hasSuffix("katex.min.css"), !mathPresent { return nil }
            // Standardized so the containment checks below compare like
            // paths (symlinked temp/bundle locations would otherwise never
            // prefix-match their standardized descendants).
            guard let base = HTMLBuilder.resourcesBaseURL?.standardizedFileURL else { return nil }
            let cssURL = base.appendingPathComponent(href).standardizedFileURL
            guard cssURL.path.hasPrefix(base.path),
                  let css = try? String(contentsOf: cssURL, encoding: .utf8) else { return nil }
            // KaTeX references its fonts relative to its own directory;
            // embed them so the exported file needs nothing from the bundle.
            let assetBase = cssURL.deletingLastPathComponent()
            return HTMLExport.inliningCSSAssets(css) { reference in
                guard !reference.hasPrefix("data:"), !reference.contains(":") else { return nil }
                let target = assetBase.appendingPathComponent(reference).standardizedFileURL
                guard target.path.hasPrefix(base.path),
                      let data = try? Data(contentsOf: target) else { return nil }
                return (data, mimeType(forExtension: target.pathExtension))
            }
        }, imageData: { src in
            imageBytes(for: src, document: document)
        })
    }

    /// Bytes for a pullmark-local/pullmark-remote image source, using the
    /// same resolution logic as the scheme handlers serving the live page.
    /// Remote images come from the in-memory cache only (already fetched by
    /// the live view); anything unavailable keeps its URL in the export.
    private static func imageBytes(for src: String,
                                   document: ActiveDocument) -> (data: Data, mimeType: String)? {
        guard let url = URL(string: src) else { return nil }
        switch url.scheme {
        case LocalResourceSchemeHandler.scheme:
            guard let root = document.localRoot,
                  let fileURL = LocalResourceSchemeHandler.resolve(url, root: root),
                  let data = try? Data(contentsOf: fileURL) else { return nil }
            return (data, mimeType(forExtension: fileURL.pathExtension))
        case RemoteResourceSchemeHandler.scheme:
            guard let context = document.remoteContext,
                  let path = RemoteResourceSchemeHandler.repoPath(from: url),
                  let data = RemoteResourceSchemeHandler.cachedData(context: context, path: path)
            else { return nil }
            return (data, mimeType(forExtension: (path as NSString).pathExtension))
        default:
            return nil
        }
    }

    private static func mimeType(forExtension ext: String) -> String {
        // UTType has no mime types for font files (KaTeX's woff2/woff/ttf).
        switch ext.lowercased() {
        case "woff2": return "font/woff2"
        case "woff": return "font/woff"
        case "ttf": return "font/ttf"
        default: return UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
        }
    }

    private static func savePanelURL(type: UTType, suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = suggestedName
        return panel.runModal() == .OK ? panel.url : nil
    }

    private static func write(_ data: Data, to url: URL, onError: (String) -> Void) {
        do {
            try data.write(to: url)
        } catch {
            onError("Could not save \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }
}
