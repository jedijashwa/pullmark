import SwiftUI
import WebKit

struct BridgeMessage {
    let lineStart: Int
    let lineEnd: Int
    let side: String
}

struct MarkdownWebView: NSViewRepresentable {
    let html: String
    var onCommentRequest: ((BridgeMessage) -> Void)?
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
    /// Optional handle for scrolling / find-in-page from SwiftUI.
    var proxy: WebViewProxy?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
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
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        // Let the SwiftUI background show through so there is no white flash
        // in dark mode while pages load.
        webView.setValue(false, forKey: "drawsBackground")
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
                parent.onCommentRequest?(BridgeMessage(lineStart: lineStart, lineEnd: lineEnd, side: side))
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
            case "threadResolve":
                if let rootID = dict["rootID"] as? Int,
                   let resolved = dict["resolved"] as? Bool {
                    parent.onThreadResolve?(rootID, resolved)
                }
            default:
                break
            }
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
                    if ["md", "markdown", "mdown", "mkd", "mdx"].contains((path as NSString).pathExtension.lowercased()) {
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
                    if ["md", "markdown", "mdown", "mkd", "mdx"].contains(fileURL.pathExtension.lowercased()) {
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
