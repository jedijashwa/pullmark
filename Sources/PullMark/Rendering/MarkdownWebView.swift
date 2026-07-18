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

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "bridge")
        configuration.setURLSchemeHandler(context.coordinator.schemeHandler,
                                          forURLScheme: LocalResourceSchemeHandler.scheme)
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

        init(_ parent: MarkdownWebView) {
            self.parent = parent
        }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == "bridge",
                  let dict = message.body as? [String: Any],
                  dict["type"] as? String == "comment",
                  let lineStart = dict["lineStart"] as? Int,
                  let lineEnd = dict["lineEnd"] as? Int,
                  let side = dict["side"] as? String
            else { return }
            parent.onCommentRequest?(BridgeMessage(lineStart: lineStart, lineEnd: lineEnd, side: side))
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard navigationAction.navigationType == .linkActivated,
                  let url = navigationAction.request.url else {
                decisionHandler(.allow)
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
