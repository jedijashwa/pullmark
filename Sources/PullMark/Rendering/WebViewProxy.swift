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

    /// The query currently highlighted by find-in-page, if any. Tracked so
    /// the find can be re-applied after the page reloads underneath it
    /// (e.g. blame annotations arriving re-renders the whole page, which
    /// wipes the highlight marks).
    private(set) var activeFindQuery: String?

    func scrollToAnchor(_ id: String) {
        let js = "document.getElementById(\(HTMLBuilder.jsStringLiteral(id)))"
            + "?.scrollIntoView({behavior: \"smooth\", block: \"start\"});"
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
        webView.evaluateJavaScript(
            "Math.max(document.documentElement.scrollHeight, document.body.scrollHeight)"
        ) { result, _ in
            let configuration = WKPDFConfiguration()
            let height = (result as? NSNumber).map { CGFloat(truncating: $0) } ?? 0
            if height > 0 {
                configuration.rect = CGRect(x: 0, y: 0, width: webView.bounds.width, height: height)
            }
            webView.createPDF(configuration: configuration) { pdfResult in
                completion(pdfResult)
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
