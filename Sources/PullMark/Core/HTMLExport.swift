import Foundation

/// Pure post-processing that turns the serialized DOM of a live rendered
/// page into a self-contained single-file HTML document: scripts and the
/// CSP meta are stripped (static output executes nothing), stylesheet links
/// are replaced with inline <style> blocks, and app-scheme images are
/// embedded as data: URIs. Callers supply the bytes via closures so this
/// stays unit-testable without a bundle or network.
enum HTMLExport {

    // MARK: - Regex plumbing

    /// Regex replace where the replacement is computed per match from the
    /// capture groups (groups[0] is the whole match); returning nil keeps
    /// the match unchanged.
    private static func replace(_ pattern: String, in text: String,
                                with transform: ([String]) -> String?) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return text }
        let ns = text as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            var groups: [String] = []
            for index in 0..<match.numberOfRanges {
                let range = match.range(at: index)
                groups.append(range.location == NSNotFound ? "" : ns.substring(with: range))
            }
            result += transform(groups) ?? groups[0]
            last = match.range.location + match.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    /// Value of a double-quoted attribute inside a serialized tag, if present.
    static func attribute(_ name: String, in tag: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: "\\b\(name)\\s*=\\s*\"([^\"]*)\"", options: [.caseInsensitive]
        ) else { return nil }
        let ns = tag as NSString
        guard let match = regex.firstMatch(in: tag, range: NSRange(location: 0, length: ns.length))
        else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    // MARK: - Passes

    /// Removes every <script> element — the bundled renderers, and the JSON
    /// payload tag. Safe as a regex because HTMLBuilder.jsonLiteral escapes
    /// "<", so no payload can contain a premature "</script>".
    static func strippingScripts(_ html: String) -> String {
        replace("<script\\b[^>]*>.*?</script>\\n?", in: html) { _ in "" }
    }

    /// Removes the Content-Security-Policy meta tag (static output loads no
    /// scripts, and the policy's custom schemes mean nothing outside the app).
    static func strippingCSPMeta(_ html: String) -> String {
        replace("<meta\\s[^>]*http-equiv=\"Content-Security-Policy\"[^>]*>\\n?", in: html) { _ in "" }
    }

    /// Replaces each stylesheet <link> with an inline <style> holding the
    /// CSS returned for its href (media queries preserved). Links whose CSS
    /// is unavailable — or deliberately skipped, like KaTeX when the page
    /// has no math — are removed rather than left as dead references.
    static func inliningStylesheets(_ html: String, css: (String) -> String?) -> String {
        replace("<link\\b[^>]*rel=\"stylesheet\"[^>]*>\\n?", in: html) { groups in
            guard let href = attribute("href", in: groups[0]),
                  let sheet = css(href) else { return "" }
            let media = attribute("media", in: groups[0]).map { " media=\"\($0)\"" } ?? ""
            return "<style\(media)>\n\(sheet)\n</style>\n"
        }
    }

    /// Rewrites url(...) references inside CSS (KaTeX's font files) to data:
    /// URIs; references the resolver cannot satisfy are left untouched.
    static func inliningCSSAssets(_ css: String, data: (String) -> (data: Data, mimeType: String)?) -> String {
        replace("url\\((['\"]?)([^)'\"]+)\\1\\)", in: css) { groups in
            guard let asset = data(groups[2]) else { return nil }
            return "url(\"\(dataURI(asset.data, mimeType: asset.mimeType))\")"
        }
    }

    /// Rewrites pullmark-local:/// and pullmark-remote:/// image sources to
    /// data: URIs when the bytes are available; images the resolver cannot
    /// satisfy — and ordinary https images — keep their URLs.
    static func inliningImages(_ html: String, data: (String) -> (data: Data, mimeType: String)?) -> String {
        replace("src=\"((?:pullmark-local|pullmark-remote):[^\"]*)\"", in: html) { groups in
            guard let image = data(groups[1]) else { return nil }
            return "src=\"\(dataURI(image.data, mimeType: image.mimeType))\""
        }
    }

    static func dataURI(_ data: Data, mimeType: String) -> String {
        "data:\(mimeType);base64,\(data.base64EncodedString())"
    }

    // MARK: - Pipeline

    /// The full export pipeline. `dom` is document.documentElement.outerHTML
    /// of the live page (no doctype — one is prepended so browsers stay out
    /// of quirks mode).
    static func selfContainedPage(dom: String,
                                  css: (String) -> String?,
                                  imageData: (String) -> (data: Data, mimeType: String)?) -> String {
        var html = strippingScripts(dom)
        html = strippingCSPMeta(html)
        html = inliningStylesheets(html, css: css)
        html = inliningImages(html, data: imageData)
        if !html.lowercased().hasPrefix("<!doctype") {
            html = "<!DOCTYPE html>\n" + html
        }
        return html
    }
}
