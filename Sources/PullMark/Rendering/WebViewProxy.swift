import WebKit

struct OutlineItem: Identifiable, Equatable {
    let level: Int
    let text: String
    let id: String
}

/// Lets SwiftUI views drive the underlying WKWebView (scroll to a heading,
/// run find-in-page) without owning it.
@MainActor
final class WebViewProxy: ObservableObject {
    weak var webView: WKWebView?

    /// The page's lightbox state: nil when closed, else the current zoom
    /// percentage (bridge-reported). Drives the native control capsule.
    @Published var lightboxPercent: Int?
    /// What the open lightbox shows ("img" / "svg" / "katex") — diagrams
    /// get a format choice on Save/Share.
    var lightboxKind: String?

    /// Drives the page's lightbox (`__pmLightbox.<call>`).
    func lightboxCommand(_ call: String) {
        webView?.evaluateJavaScript(
            "window.__pmLightbox && window.__pmLightbox.\(call);",
            completionHandler: nil)
    }

    /// Resource context for lightbox image exports, mirrored from the
    /// hosting MarkdownWebView so original image bytes can be resolved.
    var exportLocalRoot: URL?
    var exportRemoteContext: RemoteResourceContext?

    private struct LightboxContent: Decodable {
        let x: Double, y: Double, w: Double, h: Double
        let name: String
        let kind: String
        let src: String
        let exportWidth: Double
        let svg: String?
    }

    /// What the lightbox export produces: a vector SVG for diagrams
    /// (crisp at any size), original bytes for images when resolvable,
    /// or a boosted-resolution snapshot otherwise.
    struct LightboxExport {
        let name: String
        let fileExtension: String
        let data: Data
    }

    /// Requested export format for content that has a choice (diagrams);
    /// nil picks the natural format per kind.
    enum LightboxFormat {
        case svg, png
    }

    /// Captures the lightbox's rendered content for Save As…/Share.
    /// A PNG of a diagram renders through the page (CoreSVG can't draw
    /// mermaid's HTML labels): briefly fit the content so none of it is
    /// clipped by the viewport, snapshot at boosted width, restore.
    func lightboxExport(format: LightboxFormat? = nil,
                        completion: @escaping (LightboxExport?) -> Void) {
        if format == .png, lightboxKind == "svg", let percent = lightboxPercent {
            lightboxCommand("fit()")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.captureExport(format: .png) { export in
                    self?.lightboxCommand("setPercent(\(percent))")
                    completion(export)
                }
            }
            return
        }
        captureExport(format: format, completion: completion)
    }

    private func captureExport(format: LightboxFormat?,
                               completion: @escaping (LightboxExport?) -> Void) {
        guard let webView else { return completion(nil) }
        webView.evaluateJavaScript(
            "window.__pmLightbox && __pmLightbox.contentRect() "
            + "? JSON.stringify(__pmLightbox.contentRect()) : null"
        ) { [weak self] result, _ in
            guard let self,
                  let json = result as? String,
                  let info = try? JSONDecoder().decode(LightboxContent.self,
                                                       from: Data(json.utf8)),
                  info.w > 1, info.h > 1 else { return completion(nil) }
            // Diagrams: the vector itself, so huge charts export losslessly.
            if info.kind == "svg", format != .png,
               let svg = info.svg, !svg.isEmpty {
                return completion(LightboxExport(name: info.name,
                                                 fileExtension: "svg",
                                                 data: Data(svg.utf8)))
            }
            // Images: the original bytes when the source is on hand
            // (natural resolution beats any screen capture).
            if info.kind == "img", let data = self.originalImageBytes(src: info.src) {
                return completion(LightboxExport(name: info.name,
                                                 fileExtension: Self.imageExtension(for: info.src),
                                                 data: data))
            }
            // Fallback: snapshot the content rect, re-rendered wider than
            // on-screen so formulas and web images stay sharp. Known
            // limit: content panned/zoomed past the viewport exports only
            // its visible portion (the rect is clipped to bounds) — hit
            // fit before exporting oversized unresolvable images.
            let zoom = webView.pageZoom
            let configuration = WKSnapshotConfiguration()
            configuration.rect = CGRect(x: info.x * zoom, y: info.y * zoom,
                                        width: info.w * zoom, height: info.h * zoom)
                .intersection(webView.bounds)
            guard !configuration.rect.isEmpty else { return completion(nil) }
            configuration.snapshotWidth = NSNumber(
                value: min(max(info.exportWidth, Double(configuration.rect.width)), 4096))
            webView.takeSnapshot(with: configuration) { image, _ in
                guard let image,
                      let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:])
                else { return completion(nil) }
                completion(LightboxExport(name: info.name,
                                          fileExtension: "png", data: png))
            }
        }
    }

    /// File extension for an exported image: the source path's own, or —
    /// for data: URIs, which have no path — the declared media type.
    private static func imageExtension(for src: String) -> String {
        if src.hasPrefix("data:") {
            let mediaType = src.dropFirst("data:".count)
                .prefix { $0 != ";" && $0 != "," }
            switch mediaType {
            case "image/jpeg": return "jpg"
            case "image/gif": return "gif"
            case "image/webp": return "webp"
            case "image/svg+xml": return "svg"
            default: return "png"
            }
        }
        let ext = (src.split(separator: "?").first
            .map { (String($0) as NSString).pathExtension.lowercased() })
            .flatMap { $0.isEmpty ? nil : $0 }
        return ext ?? "png"
    }

    /// Original bytes for a lightboxed image, resolved the same way the
    /// scheme handlers serve the live page (plus inline data: URIs).
    private func originalImageBytes(src: String) -> Data? {
        guard let url = URL(string: src) else { return nil }
        switch url.scheme {
        case LocalResourceSchemeHandler.scheme:
            guard let root = exportLocalRoot,
                  let fileURL = LocalResourceSchemeHandler.resolve(url, root: root)
            else { return nil }
            return try? Data(contentsOf: fileURL)
        case RemoteResourceSchemeHandler.scheme:
            guard let context = exportRemoteContext,
                  let path = RemoteResourceSchemeHandler.repoPath(from: url)
            else { return nil }
            return RemoteResourceSchemeHandler.cachedData(context: context, path: path)
        case "data":
            // data:[<mediatype>][;base64],<payload>
            let string = url.absoluteString
            guard let comma = string.firstIndex(of: ",") else { return nil }
            let payload = String(string[string.index(after: comma)...])
            if string[..<comma].contains(";base64") {
                return Data(base64Encoded: payload)
            }
            return payload.removingPercentEncoding.map { Data($0.utf8) }
        case "file":
            return try? Data(contentsOf: url)
        default:
            return nil
        }
    }

    /// True while print/PDF capture holds the view at 100% zoom —
    /// MarkdownWebView.updateNSView leaves pageZoom alone while set, so a
    /// SwiftUI update can't re-zoom the view in the middle of a capture.
    private(set) var zoomHold = false

    /// Runs `capture` with the view at actual size and puts the window
    /// zoom back afterwards (from the *current* stored value — the user
    /// may have zoomed elsewhere meanwhile). The JavaScript no-op
    /// round-trips through the web process after it re-lays-out, so the
    /// capture sees the 100% layout.
    private func atActualSize(_ webView: WKWebView,
                              capture: @escaping (_ done: @escaping () -> Void) -> Void) {
        zoomHold = true
        webView.pageZoom = 1
        webView.evaluateJavaScript("1") { [weak self] _, _ in
            capture {
                let stored = UserDefaults.standard.object(forKey: DefaultsKeys.zoom) as? Double ?? 1.0
                webView.pageZoom = DocumentZoom.clamped(stored)
                self?.zoomHold = false
            }
        }
    }

    /// Entering edit mode: reveal the selection's block (or the first)
    /// so ⌘E lands ready to type.
    func revealFocused() {
        webView?.evaluateJavaScript(
            "window.__pmRevealFocused && window.__pmRevealFocused();",
            completionHandler: nil)
    }

    /// Commits any open in-place reveal synchronously — called before
    /// state flips that re-render the page (a draft must not die with it).
    func commitInlineEdit() {
        webView?.evaluateJavaScript(
            "window.__pmCommitNow && window.__pmCommitNow();",
            completionHandler: nil)
    }

    /// Continues arrow-key editing navigation after a commit reload.
    func revealAtLine(_ signedLine: Int) {
        webView?.evaluateJavaScript(
            "window.__pmRevealAtLine && window.__pmRevealAtLine(\(signedLine));",
            completionHandler: nil)
    }

    /// Releases a stuck in-place editor after Swift refuses/fails a save —
    /// an unchanged document never re-renders, so the page can't recover
    /// on its own.
    func cancelInlineEdit() {
        webView?.evaluateJavaScript(
            "window.__pmCancelInlineEdit && window.__pmCancelInlineEdit();",
            completionHandler: nil)
    }

    /// Teaches the page the (rebindable) edit-mode toggle combo, so pressing
    /// it inside an open block editor still commits and exits — the web view
    /// owns key events while a reveal has focus, so SwiftUI never sees them.
    func setEditToggleKey(_ combo: KeyCombo?) {
        let json: String
        if let combo, let data = try? JSONEncoder().encode(
            EditToggleKey(key: combo.key, meta: combo.command, ctrl: combo.control,
                          alt: combo.option, shift: combo.shift)),
           let encoded = String(data: data, encoding: .utf8) {
            json = encoded
        } else {
            json = "null"
        }
        webView?.evaluateJavaScript(
            "window.__pmSetEditToggleKey && window.__pmSetEditToggleKey(\(json));",
            completionHandler: nil)
    }

    private struct EditToggleKey: Encodable {
        let key: String
        let meta: Bool
        let ctrl: Bool
        let alt: Bool
        let shift: Bool
    }

    /// Current scroll position as a 0–1 fraction of the scrollable height.
    func scrollFraction(_ completion: @escaping (Double?) -> Void) {
        guard let webView else { return completion(nil) }
        webView.evaluateJavaScript(
            "window.scrollY / Math.max(1, document.body.scrollHeight - window.innerHeight)"
        ) { value, _ in completion(value as? Double) }
    }

    /// Restores a saved fraction (no-op near the top — jumping to 0.00x
    /// would just fight the natural default).
    func restoreScrollFraction(_ fraction: Double) {
        guard fraction > 0.02 else { return }
        webView?.evaluateJavaScript(
            "window.scrollTo(0, \(fraction) * Math.max(0, document.body.scrollHeight - window.innerHeight));",
            completionHandler: nil)
    }

    /// ⌘P: prints the rendered document through the standard panel.
    /// At actual size, like PDF export — paper doesn't inherit the
    /// window's zoom.
    func printDocument() {
        guard let webView, let window = webView.window else { return }
        atActualSize(webView) { [weak self] done in
            let info = NSPrintInfo.shared
            info.horizontalPagination = .fit
            info.verticalPagination = .automatic
            info.topMargin = 36; info.bottomMargin = 36
            info.leftMargin = 36; info.rightMargin = 36
            let operation = webView.printOperation(with: info)
            operation.showsPrintPanel = true
            operation.showsProgressPanel = true
            // WKWebView's print view starts zero-sized; without this the
            // panel previews an empty page.
            operation.view?.frame = webView.bounds
            // The sheet returns control immediately; the zoom comes back
            // when the panel is done (printed or cancelled).
            let restorer = PrintRestorer {
                self?.printRestorer = nil
                done()
            }
            self?.printRestorer = restorer
            operation.runModal(for: window, delegate: restorer,
                               didRun: #selector(PrintRestorer.printOperationDidRun(_:success:contextInfo:)),
                               contextInfo: nil)
        }
    }

    /// Keeps the print sheet's did-run target alive until it fires.
    private var printRestorer: PrintRestorer?

    private final class PrintRestorer: NSObject {
        let onDone: () -> Void
        init(onDone: @escaping () -> Void) { self.onDone = onDone }

        @objc func printOperationDidRun(_ operation: NSPrintOperation, success: Bool,
                                        contextInfo: UnsafeMutableRawPointer?) {
            onDone()
        }
    }

    /// The query currently highlighted by find-in-page, if any. Tracked so
    /// the find can be re-applied after the page reloads underneath it
    /// (e.g. blame annotations arriving re-renders the whole page, which
    /// wipes the highlight marks).
    private(set) var activeFindQuery: String?

    func scrollToAnchor(_ id: String) {
        // Jump instead of glide when the user asked the system for less
        // motion (the behavior parameter ignores prefers-reduced-motion).
        let behavior = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? "auto" : "smooth"
        let js = "document.getElementById(\(HTMLBuilder.jsStringLiteral(id)))"
            + "?.scrollIntoView({behavior: \"\(behavior)\", block: \"start\"});"
        webView?.evaluateJavaScript(js)
    }

    /// PDF of the whole rendered document. WKPDFConfiguration.rect is set to
    /// the full content height so long documents export completely — as one
    /// continuous page, since WebKit's createPDF does not paginate.
    func pdfData(completion: @escaping (Result<Data, Error>) -> Void) {
        guard let webView else {
            completion(.failure(MessageError(message: "No rendered document to export.")))
            return
        }
        // Export at actual size regardless of the window's zoom — a zoomed
        // export would bake enlarged text into the file.
        atActualSize(webView) { done in
            webView.evaluateJavaScript(
                "Math.max(document.documentElement.scrollHeight, document.body.scrollHeight)"
            ) { result, _ in
                let configuration = WKPDFConfiguration()
                let height = (result as? NSNumber).map { CGFloat(truncating: $0) } ?? 0
                if height > 0 {
                    configuration.rect = CGRect(x: 0, y: 0, width: webView.bounds.width, height: height)
                }
                webView.createPDF(configuration: configuration) { pdfResult in
                    done()
                    completion(pdfResult)
                }
            }
        }
    }

    /// Serialized DOM of the rendered page in its current state (after the
    /// page scripts ran), without the doctype.
    func pageDOM(completion: @escaping (String?) -> Void) {
        guard let webView else {
            completion(nil)
            return
        }
        webView.evaluateJavaScript("document.documentElement.outerHTML") { result, _ in
            completion(result as? String)
        }
    }

    /// 1-based inclusive source line range covered by the current selection
    /// (whole-block granularity, from the data-pm-lines annotations), or nil
    /// when nothing usable is selected — the caller then copies the whole
    /// document source.
    func selectionSourceLineRange(completion: @escaping ((start: Int, end: Int)?) -> Void) {
        guard let webView else {
            completion(nil)
            return
        }
        let js = "window.__pmSelectionLines ? window.__pmSelectionLines() : null"
        webView.evaluateJavaScript(js) { result, _ in
            let pair = (result as? [Any])?.compactMap { ($0 as? NSNumber)?.intValue } ?? []
            completion(pair.count == 2 ? (pair[0], pair[1]) : nil)
        }
    }

    /// action: "set" (with query), "next", "prev", or "clear".
    func find(_ action: String, query: String? = nil,
              completion: @escaping (Int, Int) -> Void) {
        let js: String
        if action == "set", let query {
            activeFindQuery = query.isEmpty ? nil : query
            js = "__pmFind.set(\(HTMLBuilder.jsStringLiteral(query)))"
        } else {
            if action == "clear" { activeFindQuery = nil }
            js = "__pmFind.\(action)()"
        }
        guard let webView else {
            completion(0, 0)
            return
        }
        webView.evaluateJavaScript(js) { result, _ in
            let pair = (result as? [Any])?.compactMap { ($0 as? NSNumber)?.intValue } ?? []
            completion(pair.first ?? 0, pair.count > 1 ? pair[1] : 0)
        }
    }
}
