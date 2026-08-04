import WebKit
import UniformTypeIdentifiers

/// Serves files referenced by relative paths in local Markdown (images etc.)
/// under a custom scheme, restricted to the document's resource root. Needed
/// because the rendered page itself lives in a temp directory, so relative
/// file URLs can't reach the document's folder.
final class LocalResourceSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "pullmark-local"

    var rootDirectory: URL?

    /// Maps a `pullmark-local:///relative/path` URL to a file for
    /// AUTO-LOADED resources (images and the like): containment is
    /// lexical — a `..` escape written in the document is refused, since
    /// the page pulls these in without any user gesture — but a symlink
    /// on disk is followed even when its target lives outside the root
    /// (the user's own folder layout put it there).
    static func resolve(_ url: URL, root: URL) -> URL? {
        let relative = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        guard !relative.isEmpty else { return nil }
        let lexical = root.appendingPathComponent(relative).standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        guard lexical.path == rootPath || lexical.path.hasPrefix(rootPath + "/") else { return nil }
        return lexical.resolvingSymlinksInPath()
    }

    /// The document-authored relative path a clicked link carries. The
    /// page rewrites hrefs with a `pmrel` query parameter holding the raw
    /// path, because URL normalization strips leading `..` segments from
    /// the URL's own path (even percent-encoded ones, per WHATWG rules).
    /// Falls back to the URL path for anything without the parameter.
    static func clickedRelativePath(_ url: URL) -> String? {
        if let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "pmrel" })?.value,
           !raw.isEmpty {
            return raw.hasPrefix("/") ? String(raw.dropFirst()) : raw
        }
        let path = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        return path.isEmpty ? nil : path
    }

    /// Resolution for CLICKED links: a click is the user's own gesture in
    /// their own document, so the path is followed wherever it resolves —
    /// `../` to a sibling folder, symlinks, anywhere on disk. No
    /// containment; only existence decides whether the click succeeds.
    static func resolveClickedLink(_ url: URL, root: URL) -> URL? {
        guard let relative = clickedRelativePath(url) else { return nil }
        return root.appendingPathComponent(relative)
            .standardizedFileURL.resolvingSymlinksInPath()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              let root = rootDirectory,
              let fileURL = Self.resolve(url, root: root),
              let data = try? Data(contentsOf: fileURL)
        else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let mimeType = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
        let response = URLResponse(url: url, mimeType: mimeType,
                                   expectedContentLength: data.count, textEncodingName: nil)
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}
