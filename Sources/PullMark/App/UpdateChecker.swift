import AppKit
import SwiftUI

// MARK: - Pure logic (unit-tested)

/// Semantic-version comparison for release tags. Pure so it stays testable.
enum SemVer {
    /// "v1.2.3-beta.1+45" → "1.2.3-beta.1+45" (leading v/V stripped).
    static func normalized(_ version: String) -> String {
        var s = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") { s = String(s.dropFirst()) }
        return s
    }

    /// Numeric components; prerelease/build suffixes are ignored
    /// ("1.2.3-beta.1+45" → [1, 2, 3]).
    static func components(_ version: String) -> [Int] {
        var s = normalized(version)
        if let cut = s.firstIndex(where: { $0 == "-" || $0 == "+" }) {
            s = String(s[..<cut])
        }
        return s.split(separator: ".").map { Int($0) ?? 0 }
    }

    /// Numeric, component-wise comparison: 1.2.3 < 1.10.0, 1.2 == 1.2.0.
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let ca = components(a), cb = components(b)
        for i in 0..<max(ca.count, cb.count) {
            let x = i < ca.count ? ca[i] : 0
            let y = i < cb.count ? cb[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        compare(candidate, current) == .orderedDescending
    }
}

/// A GitHub release as returned by the REST API (the fields we use).
struct UpdateRelease: Decodable, Equatable {
    let tagName: String
    let body: String?
    let htmlUrl: String
    let prerelease: Bool?
    let draft: Bool?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case body
        case htmlUrl = "html_url"
        case prerelease
        case draft
    }

    /// Full releases newer than `stored`, up to and including `current`,
    /// newest first. Used for the post-update "What's New" sheet.
    static func between(_ releases: [UpdateRelease],
                        after stored: String,
                        upTo current: String) -> [UpdateRelease] {
        releases
            .filter { $0.draft != true && $0.prerelease != true }
            .filter {
                SemVer.isNewer($0.tagName, than: stored)
                    && !SemVer.isNewer($0.tagName, than: current)
            }
            .sorted { SemVer.compare($0.tagName, $1.tagName) == .orderedDescending }
    }
}

// MARK: - Update checker service

/// Checks GitHub for newer PullMark releases (on launch and every 6 hours)
/// and drives the update banner and the post-update "What's New" sheet.
/// Uses an ephemeral session: nothing fetched is cached to disk.
@MainActor
final class UpdateChecker: ObservableObject {
    /// Newer version available (normalized, no "v"); banner shows while set.
    @Published var availableVersion: String?
    /// Markdown release notes of the available version.
    @Published var availableNotes = ""
    /// GitHub release page of the available version.
    @Published var availableURL: String?
    /// Sheet with the available version's release notes.
    @Published var showReleaseNotes = false
    /// Post-update sheet: concatenated notes since the last-run version.
    @Published var showWhatsNew = false
    @Published var whatsNewMarkdown = ""

    /// "0.0.0" for dev builds (`swift run`), which never prompt.
    let currentVersion: String

    private let session = URLSession(configuration: .ephemeral)
    private var timer: Timer?

    private static let dismissedVersionKey = "pm.dismissedUpdateVersion"
    private static let lastRunVersionKey = "pm.lastRunVersion"
    private static let latestReleaseURL =
        URL(string: "https://api.github.com/repos/jedijashwa/pullmark/releases/latest")!
    private static let releaseListURL =
        URL(string: "https://api.github.com/repos/jedijashwa/pullmark/releases?per_page=20")!

    init(currentVersion: String? = nil) {
        self.currentVersion = currentVersion
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.0.0"
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkAutomatically() }
        }
        Task { @MainActor [weak self] in
            await self?.presentWhatsNewIfUpdated()
            await self?.checkAutomatically()
        }
    }

    deinit {
        timer?.invalidate()
    }

    // MARK: Update banner

    /// Launch/periodic check: shows the banner unless this version was
    /// already dismissed. Silent on any failure.
    func checkAutomatically() async {
        guard currentVersion != "0.0.0" else { return }
        guard let release = try? await fetch(UpdateRelease.self, from: Self.latestReleaseURL) else { return }
        apply(release, ignoringDismissal: false)
    }

    /// Menu-driven check. Returns a user-facing message when there is
    /// nothing to show (up to date, dev build, or failure); nil when the
    /// banner was raised.
    func checkManually() async -> String? {
        guard currentVersion != "0.0.0" else {
            return "This is a development build, so update checks are disabled."
        }
        do {
            let release = try await fetch(UpdateRelease.self, from: Self.latestReleaseURL)
            if SemVer.isNewer(release.tagName, than: currentVersion) {
                apply(release, ignoringDismissal: true)
                return nil
            }
            return "You're up to date — PullMark \(currentVersion) is the latest version."
        } catch {
            return "Could not check for updates: \(error.localizedDescription)"
        }
    }

    private func apply(_ release: UpdateRelease, ignoringDismissal: Bool) {
        guard release.draft != true, release.prerelease != true,
              SemVer.isNewer(release.tagName, than: currentVersion) else { return }
        let version = SemVer.normalized(release.tagName)
        if !ignoringDismissal,
           UserDefaults.standard.string(forKey: Self.dismissedVersionKey) == version {
            return
        }
        availableVersion = version
        availableNotes = release.body ?? ""
        availableURL = release.htmlUrl
    }

    /// Hides the banner and remembers the version so it never re-nags
    /// (a manual check can still bring it back).
    func dismissAvailableUpdate() {
        if let availableVersion {
            UserDefaults.standard.set(availableVersion, forKey: Self.dismissedVersionKey)
        }
        availableVersion = nil
    }

    func copyBrewCommand() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("brew upgrade --cask pullmark", forType: .string)
    }

    // MARK: Post-update "What's New"

    /// If the app was updated since the last run, collects the release notes
    /// of every version between the two and presents them. First-ever launch
    /// just records the version.
    private func presentWhatsNewIfUpdated() async {
        guard currentVersion != "0.0.0" else { return }
        let defaults = UserDefaults.standard
        guard let stored = defaults.string(forKey: Self.lastRunVersionKey) else {
            defaults.set(currentVersion, forKey: Self.lastRunVersionKey)
            return
        }
        guard SemVer.isNewer(currentVersion, than: stored) else {
            if SemVer.compare(stored, currentVersion) != .orderedSame {
                defaults.set(currentVersion, forKey: Self.lastRunVersionKey)
            }
            return
        }
        defaults.set(currentVersion, forKey: Self.lastRunVersionKey)
        guard let releases = try? await fetch([UpdateRelease].self, from: Self.releaseListURL) else { return }
        let relevant = UpdateRelease.between(releases, after: stored, upTo: currentVersion)
        guard !relevant.isEmpty else { return }
        whatsNewMarkdown = relevant.map { release in
            "## PullMark \(SemVer.normalized(release.tagName))\n\n" + (release.body ?? "_No notes._")
        }.joined(separator: "\n\n---\n\n")
        showWhatsNew = true
    }

    // MARK: Networking

    private func fetch<T: Decodable>(_ type: T.Type, from url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw MessageError(message: "GitHub returned HTTP \(http.statusCode).")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
