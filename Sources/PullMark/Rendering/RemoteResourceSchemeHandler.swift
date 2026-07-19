import WebKit
import UniformTypeIdentifiers

struct RemoteResourceContext {
    let ref: PullRequestRef
    let commitSHA: String
}

/// Serves repo files (images referenced by PR Markdown) under a custom
/// scheme, fetching them from the GitHub contents API at the PR's commit
/// and caching by repo@sha:path.
final class RemoteResourceSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "pullmark-remote"

    var context: RemoteResourceContext?

    /// Memory-only, bounded; nothing fetched from GitHub touches disk (the
    /// rendered pages themselves live in $TMPDIR, purged by macOS on reboot).
    private static let cache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()
    private var stoppedTasks = Set<ObjectIdentifier>()

    private static func cacheKey(context: RemoteResourceContext, path: String) -> NSString {
        "\(context.ref.owner)/\(context.ref.repo)@\(context.commitSHA):\(path)" as NSString
    }

    /// Bytes already fetched for a repo path at this context's commit, if
    /// any — lets HTML export embed images the live page has already loaded
    /// without re-fetching (best effort: uncached images keep their URLs).
    static func cachedData(context: RemoteResourceContext, path: String) -> Data? {
        cache.object(forKey: cacheKey(context: context, path: path)) as Data?
    }

    /// Repo-relative path from a pullmark-remote:/// URL; nil when empty or
    /// attempting traversal.
    static func repoPath(from url: URL) -> String? {
        let path = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        guard !path.isEmpty,
              !path.split(separator: "/").contains(".."),
              !path.hasPrefix("/")
        else { return nil }
        return path
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              let context,
              let path = Self.repoPath(from: url)
        else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let key = Self.cacheKey(context: context, path: path)
        if let cached = Self.cache.object(forKey: key) {
            complete(urlSchemeTask, url: url, path: path, data: cached as Data)
            return
        }
        let taskID = ObjectIdentifier(urlSchemeTask)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let data = try await GitHubClient.shared.fileData(context.ref, path: path, at: context.commitSHA)
                Self.cache.setObject(data as NSData, forKey: key, cost: data.count)
                guard self.stoppedTasks.remove(taskID) == nil else { return }
                self.complete(urlSchemeTask, url: url, path: path, data: data)
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

    private func complete(_ task: WKURLSchemeTask, url: URL, path: String, data: Data) {
        let mimeType = UTType(filenameExtension: (path as NSString).pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
        let response = URLResponse(url: url, mimeType: mimeType,
                                   expectedContentLength: data.count, textEncodingName: nil)
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }
}
