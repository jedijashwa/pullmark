import SwiftUI
import WebKit

/// A submission from the in-page inline composer (spec §5): the resolved
/// line range and side, the composed body (suggestion fences included),
/// and whether it joins the pending review (`review`) or posts
/// immediately. `draftKey` is the page's draft key for the source block,
/// echoed back so a failed post can restore the text as a draft.
struct ComposerSubmission {
    let lineStart: Int
    let lineEnd: Int
    let side: String
    let body: String
    let review: Bool
    let draftKey: String
}

/// Word count / reading time of a rendered document, computed in the page.
struct DocumentStats: Equatable {
    let words: Int
    let minutes: Int
}

/// A click on inspectable media (image / mermaid SVG / formula): the page
/// reports what and where; the app presents the native lightbox.
struct LightboxRequest {
    let kind: String
    let name: String
    let src: String
    /// Viewport-relative CSS-px rect of the clicked content.
    let rect: CGRect
    let exportWidth: Double
    let svg: String?
}

struct MarkdownWebView: NSViewRepresentable {
    let html: String
    /// The in-page composer submitted a comment (spec §5).
    var onComposerSubmit: ((ComposerSubmission) -> Void)?
    /// Click-away draft sync from the in-page composers: (draft key, text).
    /// Empty text discards the draft.
    var onComposerDraft: ((String, String) -> Void)?
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
    /// Reply submitted from a thread card's in-page mini-composer:
    /// (root comment id, body, draft key).
    var onThreadReplySubmit: ((Int, String, String) -> Void)?
    /// Resolve/unresolve requested (root comment id, desired state).
    var onThreadResolve: ((Int, Bool) -> Void)?
    /// A reaction chip/picker toggle: (comment id, REST content name,
    /// desired state). The page already flipped optimistically — the
    /// handler reverts via WebViewProxy.revertReaction on failure.
    var onReactionToggle: ((Int, String, Bool) -> Void)?
    /// Save from the in-card edit composer: (comment id, new body, draft
    /// key — echoed back so a failed PATCH can restore the text).
    var onCommentEdit: ((Int, String, String) -> Void)?
    /// Delete chosen from a comment's ⋯ menu. The native destructive
    /// confirm happens app-side before any API call.
    var onCommentDelete: ((Int) -> Void)?
    /// The in-page "N resolved conversations" control was toggled — keeps
    /// the View menu's Show Resolved Conversations item in sync.
    var onResolvedVisibility: ((Bool) -> Void)?
    /// Blame gutter entry clicked: open line history for this 1-based range.
    var onBlameHistory: ((Int, Int) -> Void)?
    /// Word count / reading time computed from the rendered text
    /// (document mode only — diffs never post stats).
    var onStats: ((DocumentStats) -> Void)?
    /// Called after each page finishes loading (navigation committed and the
    /// page scripts have run) — e.g. to drive find-in-page on a fresh page.
    var onPageLoaded: (() -> Void)?
    /// Media clicked for inspection — present the native lightbox.
    var onLightboxRequest: ((LightboxRequest) -> Void)?
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

        /// File drops on the page open the file, exactly like dropping on
        /// the Dock icon. Left alone, WebKit's internal content view claims
        /// the drag and swallows it (SwiftUI's window-level onDrop never
        /// sees drops over the page — which is most of the window). So:
        /// strip drag registration from WebKit's whole subview tree, make
        /// the web view itself the drag destination for file URLs, and
        /// route drops through the same open pipeline as Finder events.
        /// Re-run after each navigation, which rebuilds content views.
        func stripDragRegistration(_ view: NSView? = nil) {
            let target = view ?? self
            target.unregisterDraggedTypes()
            for sub in target.subviews { stripDragRegistration(sub) }
            if target === self {
                super.registerForDraggedTypes([.fileURL])
            }
        }

        private func fileURLs(from info: NSDraggingInfo) -> [URL] {
            (info.draggingPasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            fileURLs(from: sender).isEmpty ? [] : .copy
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            fileURLs(from: sender).isEmpty ? [] : .copy
        }

        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
            !fileURLs(from: sender).isEmpty
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            let urls = fileURLs(from: sender)
            guard !urls.isEmpty else { return false }
            OpenURLRouter.shared.deliver(urls)
            return true
        }

        override func magnify(with event: NSEvent) {
            applyZoom(pageZoom * (1 + event.magnification))
        }

        /// Two-finger double-tap (Safari's smart zoom): toggle between
        /// actual size and the last magnified level.
        override func smartMagnify(with event: NSEvent) {
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
            applyZoom(pageZoom * (1 + event.scrollingDeltaY * 0.005))
        }

        /// The default WKWebView context menu is a browser's (Reload,
        /// Back/Forward, page items) — keep only what makes sense in a
        /// reading app and add our own commands.
        override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
            super.willOpenMenu(menu, with: event)
            let allowed: Set<String> = [
                "WKMenuItemIdentifierCopy",
                "WKMenuItemIdentifierCopyLink",
                "WKMenuItemIdentifierCopyImage",
                "WKMenuItemIdentifierLookUp",
                "WKMenuItemIdentifierTranslate",
                "WKMenuItemIdentifierSearchWeb",
                "WKMenuItemIdentifierShareMenu",
                "WKMenuItemIdentifierSpeechMenu",
            ]
            let hadCopy = menu.items.contains {
                $0.identifier?.rawValue == "WKMenuItemIdentifierCopy"
            }
            menu.items = menu.items.filter { item in
                guard let id = item.identifier?.rawValue else { return false }
                return allowed.contains(id)
            }
            // Our commands ride along when a selection exists (Copy is
            // only offered on selections, so it's the reliable signal).
            if hadCopy {
                let item = NSMenuItem(title: "Copy as Markdown",
                                      action: #selector(copySelectionAsMarkdown),
                                      keyEquivalent: "")
                item.target = self
                if let index = menu.items.firstIndex(where: {
                    $0.identifier?.rawValue == "WKMenuItemIdentifierCopy"
                }) {
                    menu.insertItem(item, at: index + 1)
                } else {
                    menu.addItem(item)
                }
            }
            // Trailing separators left over from the filter look broken.
            while let last = menu.items.last, last.isSeparatorItem {
                menu.removeItem(last)
            }
        }

        @objc private func copySelectionAsMarkdown() {
            guard let document = AppState.keyInstance?.activeDocument else { return }
            document.proxy.selectionSourceLineRange { range in
                let source = MarkdownCopy.source(of: document.markdown, lineRange: range)
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(source, forType: .string)
            }
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
        (webView as? ZoomableWebView)?.stripDragRegistration()
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
            case "composerSubmit":
                guard let lineStart = dict["lineStart"] as? Int,
                      let lineEnd = dict["lineEnd"] as? Int,
                      let side = dict["side"] as? String,
                      let body = dict["body"] as? String,
                      let review = dict["review"] as? Bool
                else { return }
                parent.onComposerSubmit?(ComposerSubmission(
                    lineStart: lineStart, lineEnd: lineEnd, side: side,
                    body: body, review: review,
                    draftKey: dict["draftKey"] as? String ?? ""))
            case "composerDraft":
                if let key = dict["key"] as? String,
                   let text = dict["text"] as? String {
                    parent.onComposerDraft?(key, text)
                }
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
            case "lightboxRequest":
                guard let kind = dict["kind"] as? String,
                      let x = dict["x"] as? Double, let y = dict["y"] as? Double,
                      let w = dict["w"] as? Double, let h = dict["h"] as? Double
                else { return }
                parent.onLightboxRequest?(LightboxRequest(
                    kind: kind,
                    name: dict["name"] as? String ?? "content",
                    src: dict["src"] as? String ?? "",
                    rect: CGRect(x: x, y: y, width: w, height: h),
                    exportWidth: dict["exportWidth"] as? Double ?? 1024,
                    svg: dict["svg"] as? String))
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
            case "threadReplySubmit":
                if let rootID = dict["rootID"] as? Int,
                   let body = dict["body"] as? String {
                    parent.onThreadReplySubmit?(rootID, body,
                                                dict["draftKey"] as? String ?? "reply:\(rootID)")
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
            case "reactionToggle":
                if let commentID = dict["commentID"] as? Int,
                   let content = dict["content"] as? String,
                   let reacted = dict["reacted"] as? Bool {
                    parent.onReactionToggle?(commentID, content, reacted)
                }
            case "commentEdit":
                if let commentID = dict["commentID"] as? Int,
                   let body = dict["body"] as? String {
                    parent.onCommentEdit?(commentID, body,
                                          dict["draftKey"] as? String ?? "edit:\(commentID)")
                }
            case "commentDelete":
                if let commentID = dict["commentID"] as? Int {
                    parent.onCommentDelete?(commentID)
                }
            case "resolvedVisibility":
                if let visible = dict["visible"] as? Bool {
                    parent.onResolvedVisibility?(visible)
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
            // Navigation rebuilds WebKit's content views, re-registering
            // them as drag destinations — strip again so file drops keep
            // falling through to the window's onDrop.
            (webView as? ZoomableWebView)?.stripDragRegistration()
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
