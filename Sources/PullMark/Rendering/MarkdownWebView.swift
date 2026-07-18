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

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "bridge")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        // Let the SwiftUI background show through so there is no white flash
        // in dark mode while pages load.
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
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
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}
