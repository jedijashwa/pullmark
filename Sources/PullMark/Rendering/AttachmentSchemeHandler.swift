import WebKit

/// Serves GitHub attachment images — `github.com/user-attachments/assets/…`
/// and the older repo-scoped `…/assets/…` form — under a custom scheme,
/// fetching them with the user's token so private attachments render
/// (spec: github-user-attachments). app.js rewrites matching <img> URLs
/// to this scheme at render time.
final class AttachmentSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "pullmark-attachment"

    final class CachedAttachment {
        let data: Data
        let mimeType: String?
        init(data: Data, mimeType: String?) {
            self.data = data
            self.mimeType = mimeType
        }
    }

    /// Memory-only, bounded; nothing fetched from GitHub touches disk.
    /// Keyed by the attachment path and shared across web views — the
    /// same screenshot appears in overview, discussion, and re-renders —
    /// so the presigned-URL expiry (~5 min) never matters after the
    /// first fetch.
    private static let cache: NSCache<NSString, CachedAttachment> = {
        let cache = NSCache<NSString, CachedAttachment>()
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()
    private var stoppedTasks = Set<ObjectIdentifier>()

    /// The attachment path under github.com, or nil when the URL isn't
    /// exactly one of the two attachment forms — the scheme must never
    /// become a general github.com proxy riding the user's token.
    static func attachmentPath(from url: URL) -> String? {
        let path = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        let uuid = "[0-9a-fA-F][0-9a-fA-F-]{18,58}"
        let name = "[A-Za-z0-9_.\\-]+"
        let pattern = "^(user-attachments/assets/\(uuid)|\(name)/\(name)/assets/[0-9]+/\(uuid))$"
        return path.range(of: pattern, options: .regularExpression) != nil ? path : nil
    }

    /// Bytes already fetched for an attachment path, if any — HTML export
    /// and the lightbox reuse what the live page already loaded.
    static func cachedAttachment(path: String) -> CachedAttachment? {
        cache.object(forKey: path as NSString)
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              let path = Self.attachmentPath(from: url)
        else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        if let cached = Self.cache.object(forKey: path as NSString) {
            complete(urlSchemeTask, url: url, cached: cached)
            return
        }
        let taskID = ObjectIdentifier(urlSchemeTask)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let fetched = try await GitHubClient.shared.attachmentData(path: path)
                let cached = CachedAttachment(data: fetched.data, mimeType: fetched.mimeType)
                Self.cache.setObject(cached, forKey: path as NSString, cost: fetched.data.count)
                guard self.stoppedTasks.remove(taskID) == nil else { return }
                self.complete(urlSchemeTask, url: url, cached: cached)
            } catch {
                if self.stoppedTasks.remove(taskID) == nil {
                    urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
                }
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        stoppedTasks.insert(ObjectIdentifier(urlSchemeTask))
    }

    private func complete(_ task: WKURLSchemeTask, url: URL, cached: CachedAttachment) {
        let response = URLResponse(url: url, mimeType: cached.mimeType ?? "application/octet-stream",
                                   expectedContentLength: cached.data.count, textEncodingName: nil)
        task.didReceive(response)
        task.didReceive(cached.data)
        task.didFinish()
    }
}
