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

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    /// WKWebView that ignores the mouse entirely (theme preview cards).
    private final class PassthroughWebView: WKWebView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
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
            ? WKWebView(frame: .zero, configuration: configuration)
            : PassthroughWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        // Let the SwiftUI background show through so there is no white flash
        // in dark mode while pages load. There is still no supported macOS
        // API for this; the KVC is guarded so a future WebKit that drops the
        // property degrades to a white flash instead of an NSUnknownKey
        // crash, and the supported under-page color covers overscroll.
        if webView.responds(to: Selector(("setDrawsBackground:"))) {
            webView.setValue(false, forKey: "drawsBackground")
        }
        webView.underPageBackgroundColor = .clear
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.schemeHandler.rootDirectory = localResourceRoot
        context.coordinator.remoteHandler.context = remoteContext
        proxy?.webView = webView
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
