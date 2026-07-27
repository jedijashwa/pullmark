import SwiftUI
import WebKit

struct BridgeMessage {
    let lineStart: Int
    let lineEnd: Int
    let side: String
    /// The pencil button: open the composer in edit-as-suggestion mode.
    var edit = false
}

/// Word count / reading time of a rendered document, computed in the page.
struct DocumentStats: Equatable {
    let words: Int
    let minutes: Int
}

struct MarkdownWebView: NSViewRepresentable {
    let html: String
    var onCommentRequest: ((BridgeMessage) -> Void)?
    /// In-place block editing commit: (lineStart, lineEnd, seed the editor
    /// started from, replacement) — 1-based inclusive source lines.
    var onEditLocal: ((Int, Int, String, String) -> Void)?
    /// An in-place editor opened (true) or closed (false) — re-renders are
    /// deferred while one is open so the draft can't be destroyed.
    var onEditingState: ((Bool) -> Void)?
    /// Arrow navigation committed an edit: after the reload, re-open the
    /// reveal at this line (negative = caret at end).
    var onNextReveal: ((Int) -> Void)?
    /// ⌘E pressed inside a reveal — the focused text field beats the
    /// toolbar toggle's key equivalent, so the page forwards it.
    var onToggleEditMode: (() -> Void)?
    /// Directory that relative resources (images, linked files) in the
    /// rendered Markdown may be loaded from. Local documents only.
    var localResourceRoot: URL?
    /// Called when the user clicks a relative link to another local file.
    var onOpenLocalFile: ((URL) -> Void)?
    /// Repo + commit that repo-relative resources resolve against. PR files only.
    var remoteContext: RemoteResourceContext?
    /// Called when the user clicks a repo-relative link to a Markdown file;
    /// receives the repo path (opened in-app at the PR's commit).
    var onOpenRemoteFile: ((String) -> Void)?
    /// Receives the document's heading outline after each render.
    var onOutline: (([OutlineItem]) -> Void)?
    /// Scroll-spy: the heading id currently at the top of the viewport.
    var onActiveSection: ((String) -> Void)?
    /// Reply requested on an existing review thread (root comment id).
    var onThreadReply: ((Int) -> Void)?
    /// Resolve/unresolve requested (root comment id, desired state).
    var onThreadResolve: ((Int, Bool) -> Void)?
    /// Blame gutter entry clicked: open line history for this 1-based range.
    var onBlameHistory: ((Int, Int) -> Void)?
    /// Word count / reading time computed from the rendered text
    /// (document mode only — diffs never post stats).
    var onStats: ((DocumentStats) -> Void)?
    /// Called after each page finishes loading (navigation committed and the
    /// page scripts have run) — e.g. to drive find-in-page on a fresh page.
    var onPageLoaded: (() -> Void)?
    /// Optional handle for scrolling / find-in-page from SwiftUI.
    var proxy: WebViewProxy?
    /// False for the Settings theme-preview cards: the web view refuses all
    /// mouse events (AppKit-level, since WKWebView sits above SwiftUI's hit
    /// testing) so clicks fall through to the enclosing card.
    var interactive: Bool = true
    /// Document magnification (View → Zoom). Non-interactive views (theme
    /// preview cards) stay at actual size — they are already miniatures.
    @AppStorage(DefaultsKeys.zoom) private var zoom = 1.0

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    /// WKWebView that ignores the mouse entirely (theme preview cards).
    private final class PassthroughWebView: WKWebView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    /// WKWebView that turns the pinch gesture (and ⌘-scroll, the browser
    /// convention) into pageZoom — reflowing browser zoom, matching the
    /// menu commands — instead of WebKit's own scale-the-canvas
    /// magnification. Every step persists immediately: the stored value
    /// and the live view never diverge, so updateNSView's sync can't
    /// snap the zoom back mid-gesture, other windows follow live, and
    /// the HUD counts along.
    private final class ZoomableWebView: WKWebView {
        /// Where smart magnify returns to after toggling down to 100%.
        /// Shared across web views — it is one reading preference, like
        /// the zoom itself.
        private static var lastSmartZoom: CGFloat = 1.5

        /// The page's lightbox is open (bridge-reported): zoom gestures
        /// belong to it, not the document — WKWebView never delivers
        /// pinches to the page, so they are forwarded as script calls.
        var lightboxActive = false

        private func forwardToLightbox(_ call: String) {
            evaluateJavaScript("window.__pmLightbox && window.__pmLightbox.\(call);",
                               completionHandler: nil)
        }

        override func magnify(with event: NSEvent) {
            if lightboxActive {
                forwardToLightbox("zoomBy(\(1 + event.magnification))")
                return
            }
            applyZoom(pageZoom * (1 + event.magnification))
        }

        /// Two-finger double-tap (Safari's smart zoom): toggle between
        /// actual size and the last magnified level.
        override func smartMagnify(with event: NSEvent) {
            if lightboxActive {
                forwardToLightbox("toggle()")
                return
            }
            if DocumentZoom.isActualSize(Double(pageZoom)) {
                applyZoom(Self.lastSmartZoom)
            } else {
                // Remember only meaningful magnification — a zoomed-out
                // or hair-above-100% level would turn the toggle into a
                // zoom-out (or a visible no-op). From those, the return
                // trip keeps the previous magnified level.
                if pageZoom >= 1.1 { Self.lastSmartZoom = pageZoom }
                applyZoom(1.0)
            }
        }

        override func scrollWheel(with event: NSEvent) {
            guard event.modifierFlags.contains(.command) else {
                super.scrollWheel(with: event)
                return
            }
            if lightboxActive {
                forwardToLightbox("zoomBy(\(1 + event.scrollingDeltaY * 0.005))")
                return
            }
            applyZoom(pageZoom * (1 + event.scrollingDeltaY * 0.005))
        }

        /// Edge detector for the limit haptic: true while the last request
        /// overshot the range, so the tick fires once per arrival at a
        /// limit and re-arms as soon as the gesture pulls back inside.
        private var atLimit = false

        private func applyZoom(_ value: CGFloat) {
            let clamped = DocumentZoom.clamped(value)
            let hitLimit = clamped != value
            // A quiet tick when a gesture runs into the end of the range —
            // otherwise a pinch past 300% just feels ignored.
            if hitLimit, !atLimit {
                NSHapticFeedbackManager.defaultPerformer
                    .perform(.alignment, performanceTime: .default)
            }
            atLimit = hitLimit
            pageZoom = clamped
            UserDefaults.standard.set(Double(clamped), forKey: DefaultsKeys.zoom)
        }
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // No persistent website data: rendered content is regenerated on
        // demand and must not outlive a reboot (or even the session).
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(context.coordinator, name: "bridge")
        configuration.setURLSchemeHandler(context.coordinator.schemeHandler,
                                          forURLScheme: LocalResourceSchemeHandler.scheme)
        configuration.setURLSchemeHandler(context.coordinator.remoteHandler,
                                          forURLScheme: RemoteResourceSchemeHandler.scheme)
        let webView = interactive
            ? ZoomableWebView(frame: .zero, configuration: configuration)
            : PassthroughWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        // Let the SwiftUI background show through so there is no white flash
        // in dark mode while pages load. There is still no supported macOS
        // API for this; the KVC is guarded so a future WebKit that drops the
        // property degrades to a white flash instead of an NSUnknownKey
        // crash, and the supported under-page color covers overscroll.
        // Modern WebKit renamed the setter to _setDrawsBackground: (KVC's
        // setter search still finds it) — the old selector-only guard made
        // this whole call a silent no-op, which WAS the dark-mode flash.
        if webView.responds(to: Selector(("setDrawsBackground:")))
            || webView.responds(to: Selector(("_setDrawsBackground:"))) {
            webView.setValue(false, forKey: "drawsBackground")
        }
        webView.underPageBackgroundColor = .clear
        if interactive {
            webView.pageZoom = DocumentZoom.clamped(zoom)
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        // Not while an export/print holds the view at 100% — a SwiftUI
        // update landing between its async hops (the save panel closing
        // causes one) would re-zoom the view mid-capture.
        if interactive, proxy?.zoomHold != true {
            let target = DocumentZoom.clamped(zoom)
            if abs(webView.pageZoom - target) > 0.0005 {
                webView.pageZoom = target
            }
        }
        context.coordinator.schemeHandler.rootDirectory = localResourceRoot
        context.coordinator.remoteHandler.context = remoteContext
        proxy?.webView = webView
        // Lightbox exports resolve original image bytes with the same
        // context the scheme handlers use.
        proxy?.exportLocalRoot = localResourceRoot
        proxy?.exportRemoteContext = remoteContext
        if context.coordinator.lastHTML != html {
            context.coordinator.lastHTML = html
            RenderPageStore.removePage(context.coordinator.lastPageURL)
            if let pageURL = RenderPageStore.writePage(html) {
                context.coordinator.lastPageURL = pageURL
                // The new page starts with no lightbox — a stale flag
                // would strand zoom gestures in a dead forwarder.
                (webView as? ZoomableWebView)?.lightboxActive = false
                proxy?.lightboxPercent = nil
                webView.loadFileURL(pageURL, allowingReadAccessTo: RenderPageStore.directory)
            }
        }
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "bridge")
        RenderPageStore.removePage(coordinator.lastPageURL)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: MarkdownWebView
        var lastHTML: String?
        var lastPageURL: URL?
        let schemeHandler = LocalResourceSchemeHandler()
        let remoteHandler = RemoteResourceSchemeHandler()

        init(_ parent: MarkdownWebView) {
            self.parent = parent
        }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == "bridge",
                  let dict = message.body as? [String: Any] else { return }
            switch dict["type"] as? String {
            case "comment":
                guard let lineStart = dict["lineStart"] as? Int,
                      let lineEnd = dict["lineEnd"] as? Int,
                      let side = dict["side"] as? String
                else { return }
                parent.onCommentRequest?(BridgeMessage(lineStart: lineStart, lineEnd: lineEnd, side: side,
                                                       edit: dict["edit"] as? Bool ?? false))
            case "editLocal":
                guard let lineStart = dict["lineStart"] as? Int,
                      let lineEnd = dict["lineEnd"] as? Int,
                      let replacement = dict["replacement"] as? String,
                      let seed = dict["seed"] as? String
                else { return }
                parent.onEditLocal?(lineStart, lineEnd, seed, replacement)
                if let next = dict["nextRevealLine"] as? Int {
                    parent.onNextReveal?(next)
                }
            case "editingState":
                if let active = dict["active"] as? Bool {
                    parent.onEditingState?(active)
                }
            case "toggleEditMode":
                parent.onToggleEditMode?()
            case "lightbox":
                if let active = dict["active"] as? Bool {
                    (message.webView as? ZoomableWebView)?.lightboxActive = active
                    // Kind first: the bar reads it when percent's publish
                    // triggers its first render.
                    parent.proxy?.lightboxKind = active ? dict["kind"] as? String : nil
                    parent.proxy?.lightboxPercent = active
                        ? (dict["percent"] as? Int ?? 100) : nil
                }
            case "outline":
                guard let raw = dict["items"] as? [[String: Any]] else { return }
                let items = raw.compactMap { item -> OutlineItem? in
                    guard let level = item["level"] as? Int,
                          let text = item["text"] as? String,
                          let id = item["id"] as? String
                    else { return nil }
                    return OutlineItem(level: level, text: text, id: id)
                }
                parent.onOutline?(items)
            case "activeSection":
                if let id = dict["id"] as? String {
                    parent.onActiveSection?(id)
                }
            case "threadReply":
                if let rootID = dict["rootID"] as? Int {
                    parent.onThreadReply?(rootID)
                }
            case "copySHA":
                // Blame chip without a known commit URL: copy the full SHA.
                if let sha = dict["sha"] as? String {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(sha, forType: .string)
                }
            case "blameHistory":
                if let start = dict["lineStart"] as? Int,
                   let end = dict["lineEnd"] as? Int {
                    parent.onBlameHistory?(start, end)
                }
            case "stats":
                if let words = dict["words"] as? Int,
                   let minutes = dict["minutes"] as? Int {
                    parent.onStats?(DocumentStats(words: words, minutes: minutes))
                }
            case "threadResolve":
                if let rootID = dict["rootID"] as? Int,
                   let resolved = dict["resolved"] as? Bool {
                    parent.onThreadResolve?(rootID, resolved)
                }
            default:
                break
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Several web views loading at once (Settings theme previews)
            // occasionally leave one blank until it is clicked — WebKit
            // skips the first composited frame for an occluded/busy view.
            // Marking the view dirty after navigation forces that frame.
            DispatchQueue.main.async { webView.needsDisplay = true }
            // The updateNSView reset can be undone by a straggling
            // "lightbox open" message from the OLD page still in the
            // main-queue pipeline; navigation completion is ordered after
            // those, so this reset is the authoritative one.
            (webView as? ZoomableWebView)?.lightboxActive = false
            parent.proxy?.lightboxPercent = nil
            parent.onPageLoaded?()
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard navigationAction.navigationType == .linkActivated,
                  let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            // In-page anchor links scroll within the rendered document.
            if url.isFileURL, url.fragment != nil, url.path == webView.url?.path {
                decisionHandler(.allow)
                return
            }
            if url.scheme == RemoteResourceSchemeHandler.scheme {
                if let path = RemoteResourceSchemeHandler.repoPath(from: url),
                   let context = remoteHandler.context {
                    if MarkdownFileType.matches((path as NSString).pathExtension) {
                        parent.onOpenRemoteFile?(path)
                    } else if let blobURL = URL(string: "https://github.com/\(context.ref.owner)/\(context.ref.repo)/blob/\(context.commitSHA)/\(path)") {
                        NSWorkspace.shared.open(blobURL)
                    }
                }
                decisionHandler(.cancel)
                return
            }
            if url.scheme == LocalResourceSchemeHandler.scheme {
                if let root = schemeHandler.rootDirectory,
                   let fileURL = LocalResourceSchemeHandler.resolve(url, root: root) {
                    if MarkdownFileType.matches(fileURL.pathExtension) {
                        parent.onOpenLocalFile?(fileURL)
                    } else {
                        NSWorkspace.shared.open(fileURL)
                    }
                }
                decisionHandler(.cancel)
                return
            }
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        }
    }
}
