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

    /// The native inspector is covering this page: stop advertising the
    /// zoom-in cursor (the web view keeps driving the pointer from its
    /// own tracking even under native overlays).
    func setInspecting(_ inspecting: Bool) {
        webView?.evaluateJavaScript(
            "document.documentElement.classList.toggle('pm-inspecting', \(inspecting));",
            completionHandler: nil)
    }

    /// The inspector's content frame (view points): the page shows the
    /// grab hand exactly there. nil clears the region.
    func setInspectRegion(_ rect: CGRect?) {
        guard let webView else { return }
        guard let rect else {
            webView.evaluateJavaScript(
                "window.__pmInspectRegion && __pmInspectRegion(null);",
                completionHandler: nil)
            return
        }
        let zoom = max(webView.pageZoom, 0.01)
        webView.evaluateJavaScript(
            "window.__pmInspectRegion && __pmInspectRegion("
            + "\(rect.minX / zoom),\(rect.minY / zoom),"
            + "\(rect.width / zoom),\(rect.height / zoom));",
            completionHandler: nil)
    }

    /// The pointer is over the inspector's own chrome — arrow, not grab.
    func setInspectUIHover(_ over: Bool) {
        webView?.evaluateJavaScript(
            "window.__pmInspectHoverUI && __pmInspectHoverUI(\(over));",
            completionHandler: nil)
    }

    /// Resource context for lightbox image exports, mirrored from the
    /// hosting MarkdownWebView so original image bytes can be resolved.
    var exportLocalRoot: URL?
    var exportRemoteContext: RemoteResourceContext?

    /// Snapshot of a viewport-relative CSS-px rect, re-rendered at
    /// `exportWidth` so vector-ish content (formulas) stays sharp.
    func snapshotRect(_ cssRect: CGRect, exportWidth: Double,
                      completion: @escaping (NSImage?) -> Void) {
        guard let webView, cssRect.width > 1, cssRect.height > 1 else {
            return completion(nil)
        }
        let zoom = webView.pageZoom
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(x: cssRect.minX * zoom, y: cssRect.minY * zoom,
                                    width: cssRect.width * zoom,
                                    height: cssRect.height * zoom)
            .intersection(webView.bounds)
        guard !configuration.rect.isEmpty else { return completion(nil) }
        configuration.snapshotWidth = NSNumber(
            value: min(max(exportWidth, Double(configuration.rect.width)), 4096))
        webView.takeSnapshot(with: configuration) { image, _ in
            completion(image)
        }
    }

    /// File extension for an exported image: the source path's own, or —
    /// for data: URIs, which have no path — the declared media type.
    static func imageExtension(for src: String) -> String {
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
    func originalImageBytes(src: String) -> Data? {
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
                let stored = UserDefaults.pullmark.object(forKey: DefaultsKeys.zoom) as? Double ?? 1.0
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

    /// Applies a content-width change to the loaded page in place — pure
    /// CSS reflow, so the reader's rough position survives (a reload would
    /// land at the top).
    func setContentWidth(_ dataValue: String?) {
        let js: String
        if let dataValue {
            js = "document.documentElement.dataset.width = '\(dataValue)';"
        } else {
            js = "delete document.documentElement.dataset.width;"
        }
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    /// Applies a line-numbers toggle to the loaded page in place — the
    /// page reserves/releases its gutter and rebuilds the labels without
    /// a reload.
    func setLineNumbers(_ enabled: Bool) {
        webView?.evaluateJavaScript(
            "window.__pmSetLineNumbers && __pmSetLineNumbers(\(enabled));",
            completionHandler: nil)
    }

    /// Scrolls the loaded page to a review thread's card, expanding and
    /// flashing it — the overview's View in File jump (spec:
    /// pr-review-discussion).
    func revealThread(rootID: Int) {
        webView?.evaluateJavaScript(
            "window.__pmRevealThread && __pmRevealThread(\(rootID));",
            completionHandler: nil)
    }

    func setRemoteLinkPolicy(_ policy: String) {
        // Rawvalue strings only ("ask"/"pullmark"/"browser") — safe to inline.
        webView?.evaluateJavaScript(
            "window.__pmSetRemoteLinkPolicy && __pmSetRemoteLinkPolicy('\(policy)');",
            completionHandler: nil)
    }

    /// The source line of the topmost block visible in the viewport — the
    /// anchor for keeping the reader's place across an edit-mode flip.
    func firstVisibleLine(_ completion: @escaping (Int?) -> Void) {
        guard let webView else { return completion(nil) }
        webView.evaluateJavaScript(
            "window.__pmFirstVisibleLine && window.__pmFirstVisibleLine();"
        ) { value, _ in completion(value as? Int) }
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

    /// Pushes persisted composer drafts into the page (keyed by the page's
    /// own draft keys) so click-away drafts survive reloads and relaunches.
    /// JSON-encoded through jsonLiteral — draft text is user content and
    /// must never reach the evaluated string unescaped.
    func setComposerDrafts(_ drafts: [String: String]) {
        guard !drafts.isEmpty else { return }
        webView?.evaluateJavaScript(
            "window.__pmSetComposerDrafts && __pmSetComposerDrafts(\(HTMLBuilder.jsonLiteral(drafts)));",
            completionHandler: nil)
    }

    /// Reverts an optimistic reaction flip after the API write failed.
    /// `content` came from the page (every evaluateJavaScript interpolation
    /// is an injection surface): it must name a known reaction, and it goes
    /// through jsStringLiteral besides.
    func revertReaction(commentID: Int, content: String, attempted: Bool) {
        guard ReactionKind(rawValue: content) != nil else { return }
        webView?.evaluateJavaScript(
            "window.__pmReactionRevert && __pmReactionRevert(\(commentID), "
            + "\(HTMLBuilder.jsStringLiteral(content)), \(attempted));",
            completionHandler: nil)
    }

    /// Opens the margin-note composer: file-level at the top of the
    /// document, otherwise on the block nearest the top of the viewport.
    func openNoteComposer(fileLevel: Bool) {
        webView?.evaluateJavaScript(
            "window.__pmOpenNoteComposer && __pmOpenNoteComposer(\(fileLevel));",
            completionHandler: nil)
    }

    /// Arms the first-use margin-notes intro on the loaded page: while
    /// pending, the page's write affordances post noteIntroRequested
    /// instead of acting (spec: margin-notes-graduation). Injected after
    /// each page load rather than carried in the page payload, so the
    /// seen-flip never re-renders the document.
    func setNoteIntroPending(_ pending: Bool) {
        webView?.evaluateJavaScript(
            "window.__pmSetNoteIntroPending && __pmSetNoteIntroPending(\(pending));",
            completionHandler: nil)
    }

    /// Resolves a posted noteIntroRequested: true runs the action the
    /// user originally clicked (and disarms the intro); false — Esc,
    /// "not now" — drops it and leaves the intro armed for next time.
    func resolveNoteIntro(proceed: Bool) {
        webView?.evaluateJavaScript(
            "window.__pmNoteIntroResolved && __pmNoteIntroResolved(\(proceed));",
            completionHandler: nil)
    }

    /// Mirrors View ▸ Show Resolved Conversations into the page (Result-
    /// view thread markers). In-place — no reload, the reader's position
    /// survives; pages without markers ignore it.
    func setResolvedConversationsVisible(_ visible: Bool) {
        webView?.evaluateJavaScript(
            "window.__pmSetResolvedShown && __pmSetResolvedShown(\(visible));",
            completionHandler: nil)
    }

    /// One expanded Result-view thread cluster, keyed by its block's
    /// data-pm-lines range, with the open kinds (published/pending cards
    /// expand independently — the split badges).
    struct OpenThreadAnchor: Codable, Equatable {
        let anchor: String
        let threads: Bool
        let pending: Bool
    }

    /// Anchors of the expanded thread clusters — captured just before a
    /// model-driven re-render so handlePageLoaded can put the open cards
    /// back (the scroll fraction alone keeps the reader's place, not the
    /// card they had open). Pages without markers answer with [].
    func openThreadAnchors(_ completion: @escaping ([OpenThreadAnchor]) -> Void) {
        guard let webView else { return completion([]) }
        webView.evaluateJavaScript(
            "window.__pmOpenThreadAnchors ? JSON.stringify(__pmOpenThreadAnchors()) : \"[]\""
        ) { value, _ in
            guard let json = value as? String,
                  let data = json.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([OpenThreadAnchor].self, from: data)
            else { return completion([]) }
            completion(decoded)
        }
    }

    /// Re-applies captured open clusters to the freshly loaded page. The
    /// anchor keys round-tripped through the page (every evaluateJavaScript
    /// interpolation is an injection surface): only the generated
    /// "start-end" shape passes, and the payload is JSON-encoded besides.
    func restoreOpenThreadAnchors(_ anchors: [OpenThreadAnchor]) {
        let safe = anchors.filter {
            $0.anchor.range(of: "^[0-9]+-[0-9]+$", options: .regularExpression) != nil
        }
        guard !safe.isEmpty,
              let data = try? JSONEncoder().encode(safe),
              let json = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript(
            "window.__pmRestoreOpenThreadAnchors && __pmRestoreOpenThreadAnchors(\(json));",
            completionHandler: nil)
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
        // Paper is the document only: review annotations (thread markers,
        // highlights, cards) hide for the duration of the print.
        setExporting(webView, true)
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
                if let webView = self?.webView { self?.setExporting(webView, false) }
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
        // __pmJumpTo pins the destination as the active section for the
        // glide's duration — the outline must not flash every heading
        // the animation passes.
        let smooth = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? "false" : "true"
        let js = "window.__pmJumpTo && __pmJumpTo(\(HTMLBuilder.jsStringLiteral(id)), \(smooth));"
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
        // export would bake enlarged text into the file. Review annotations
        // hide first (exports are the document only), and the height is
        // measured after that relayout.
        setExporting(webView, true)
        atActualSize(webView) { [weak self] done in
            webView.evaluateJavaScript(
                "Math.max(document.documentElement.scrollHeight, document.body.scrollHeight)"
            ) { result, _ in
                let configuration = WKPDFConfiguration()
                let height = (result as? NSNumber).map { CGFloat(truncating: $0) } ?? 0
                if height > 0 {
                    configuration.rect = CGRect(x: 0, y: 0, width: webView.bounds.width, height: height)
                }
                webView.createPDF(configuration: configuration) { pdfResult in
                    self?.setExporting(webView, false)
                    done()
                    completion(pdfResult)
                }
            }
        }
    }

    /// Flips the page's export mode: review annotations (thread markers,
    /// highlights, inline cards, the resolved control) hide while set —
    /// exports and prints are the document only (spec).
    private func setExporting(_ webView: WKWebView, _ exporting: Bool) {
        webView.evaluateJavaScript(
            "document.documentElement.classList.toggle('pm-exporting', \(exporting));",
            completionHandler: nil)
    }

    /// Serialized DOM of the rendered page in its current state (after the
    /// page scripts ran), without the doctype. Prefers the page's export
    /// serializer, which strips review annotations — exported HTML is the
    /// document only, with no thread text in the markup.
    func pageDOM(completion: @escaping (String?) -> Void) {
        guard let webView else {
            completion(nil)
            return
        }
        webView.evaluateJavaScript(
            "window.__pmExportDOM ? window.__pmExportDOM() : document.documentElement.outerHTML"
        ) { result, _ in
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
