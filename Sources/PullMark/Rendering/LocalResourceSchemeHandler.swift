import WebKit
import UniformTypeIdentifiers

/// Serves files referenced by relative paths in local Markdown (images etc.)
/// under a custom scheme, restricted to the document's resource root. Needed
/// because the rendered page itself lives in a temp directory, so relative
/// file URLs can't reach the document's folder.
final class LocalResourceSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "pullmark-local"

    var rootDirectory: URL?

    /// Maps a `pullmark-local:///relative/path` URL to a file inside `root`,
    /// refusing anything that escapes the root (.. traversal, symlinks out).
    static func resolve(_ url: URL, root: URL) -> URL? {
        let relative = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        guard !relative.isEmpty else { return nil }
        let candidate = root.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        guard candidate.path == rootPath || candidate.path.hasPrefix(rootPath + "/") else { return nil }
        return candidate
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
