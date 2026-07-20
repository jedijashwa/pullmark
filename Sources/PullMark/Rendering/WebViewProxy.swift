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
    func printDocument() {
        guard let webView, let window = webView.window else { return }
        let info = NSPrintInfo.shared
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.topMargin = 36; info.bottomMargin = 36
        info.leftMargin = 36; info.rightMargin = 36
        let operation = webView.printOperation(with: info)
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        // WKWebView's print view starts zero-sized; without this the panel
        // previews an empty page.
        operation.view?.frame = webView.bounds
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

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
