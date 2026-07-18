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

    func scrollToAnchor(_ id: String) {
        let js = "document.getElementById(\(HTMLBuilder.jsStringLiteral(id)))"
            + "?.scrollIntoView({behavior: \"smooth\", block: \"start\"});"
        webView?.evaluateJavaScript(js)
    }

    /// action: "set" (with query), "next", "prev", or "clear".
    func find(_ action: String, query: String? = nil,
              completion: @escaping (Int, Int) -> Void) {
        let js: String
        if action == "set", let query {
            js = "__pmFind.set(\(HTMLBuilder.jsStringLiteral(query)))"
        } else {
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
