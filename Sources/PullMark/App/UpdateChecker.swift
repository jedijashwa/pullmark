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

/// A downloadable file attached to a GitHub release.
struct UpdateAsset: Decodable, Equatable {
    let name: String
    let browserDownloadUrl: String

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadUrl = "browser_download_url"
    }
}

/// A GitHub release as returned by the REST API (the fields we use).
struct UpdateRelease: Decodable, Equatable {
    let tagName: String
    let body: String?
    let htmlUrl: String
    let prerelease: Bool?
    let draft: Bool?
    let assets: [UpdateAsset]?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case body
        case htmlUrl = "html_url"
        case prerelease
        case draft
        case assets
    }

    init(tagName: String, body: String?, htmlUrl: String,
         prerelease: Bool?, draft: Bool?, assets: [UpdateAsset]? = nil) {
        self.tagName = tagName
        self.body = body
        self.htmlUrl = htmlUrl
        self.prerelease = prerelease
        self.draft = draft
        self.assets = assets
    }

    /// Download URL of the release's `.zip` asset (the notarized app
    /// archive) — what the in-place self-updater installs.
    var zipAssetURL: String? {
        assets?.first { $0.name.lowercased().hasSuffix(".zip") }?.browserDownloadUrl
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

/// How the update banner's primary action behaves.
enum UpdateMethod: Equatable {
    /// The install is brew-managed: "Update Now" runs `brew upgrade`.
    case brew(brewPath: String)
    /// A real .app outside brew management: "Update Now" downloads the
    /// release zip, verifies its signature, and swaps the bundle in place.
    case selfUpdate
    /// No .app bundle to replace (dev build): "Download" opens the
    /// release page.
    case download
}

/// Pure decision logic and command construction for brew-driven updates.
/// Process execution is injected so tests never actually run brew.
enum BrewUpdate {
    static let caskName = "pullmark"
    /// Apple Silicon Homebrew first, then Intel.
    static let brewCandidatePaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
    /// The user-facing command (fallback text + clipboard).
    static let command = "brew upgrade --cask \(caskName)"

    static var listArguments: [String] { ["list", "--cask", caskName] }
    static var upgradeArguments: [String] { ["upgrade", "--cask", caskName] }

    /// True when the RUNNING bundle is the copy brew manages: the cask's
    /// install target (/Applications/PullMark.app) or a copy inside brew's
    /// own Caskroom. A brew-managed cask elsewhere on the machine must not
    /// claim a bundle running from some other path (e.g. ~/Apps).
    static func isBrewInstalledBundle(bundlePath: String, brewPath: String) -> Bool {
        let path = (bundlePath as NSString).standardizingPath
        if path == "/Applications/PullMark.app" { return true }
        let brewPrefix = ((brewPath as NSString).deletingLastPathComponent
            as NSString).deletingLastPathComponent
        return path.hasPrefix("\(brewPrefix)/Caskroom/\(caskName)/")
    }

    /// Decision tiers, checked against the RUNNING bundle:
    /// - the bundle is brew's install target and `brew list --cask pullmark`
    ///   succeeds → brew-managed ("Update Now" runs brew);
    /// - otherwise a real .app → self-update (download + verify + swap);
    /// - not an .app at all (dev build) → download (open the release page).
    /// `runner` returns true when the command exits 0.
    static func detectMethod(bundlePath: String,
                             fileExists: (String) -> Bool,
                             runner: (String, [String]) -> Bool) -> UpdateMethod {
        let fallback: UpdateMethod = bundlePath.hasSuffix(".app") ? .selfUpdate : .download
        guard let brew = brewCandidatePaths.first(where: fileExists),
              isBrewInstalledBundle(bundlePath: bundlePath, brewPath: brew) else {
            return fallback
        }
        return runner(brew, listArguments) ? .brew(brewPath: brew) : fallback
    }

    /// Path to relaunch after a brew upgrade: the running .app bundle, or the
    /// canonical install location for non-bundle (dev) builds.
    static func relaunchAppPath(bundlePath: String) -> String {
        bundlePath.hasSuffix(".app") ? bundlePath : "/Applications/PullMark.app"
    }

    /// Shell command spawned detached before terminating, so the new version
    /// starts once this process has exited.
    static func relaunchShellCommand(appPath: String) -> String {
        "sleep 1; open -a \"\(appPath)\""
    }

    /// Real runner: executes a command and reports success. Blocks — call
    /// off the main thread.
    static func run(_ launchPath: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// Runs `brew upgrade --cask pullmark`; nil on success, a short
    /// user-facing error otherwise. Blocks — call off the main thread.
    static func runUpgrade(brewPath: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: brewPath)
        process.arguments = upgradeArguments
        let stderr = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        do { try process.run() } catch {
            return "Could not run brew: \(error.localizedDescription)"
        }
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus == 0 { return nil }
        let lastLine = String(data: errorData, encoding: .utf8)?
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last(where: { !$0.isEmpty })
        return lastLine.map { String($0.prefix(120)) }
            ?? "brew exited with status \(process.terminationStatus)"
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
    /// Download URL of the available version's .zip asset (self-update).
    @Published var availableZipURL: String?
    /// Sheet with the available version's release notes.
    @Published var showReleaseNotes = false
    /// Post-update sheet: concatenated notes since the last-run version.
    @Published var showWhatsNew = false
    @Published var whatsNewMarkdown = ""
    /// How the banner's primary action behaves; nil while still probing brew.
    @Published var updateMethod: UpdateMethod?
    /// In-banner update lifecycle; `updating`'s text is the progress phase
    /// shown in the banner ("Updating…", "Downloading…", "Verifying…", …).
    enum UpdateRun: Equatable { case idle, updating(String), failed(String) }
    @Published var updateRun: UpdateRun = .idle

    var isUpdating: Bool {
        if case .updating = updateRun { return true }
        return false
    }

    /// "0.0.0" for dev builds (`swift run`), which never prompt.
    let currentVersion: String

    private let session = URLSession(configuration: .ephemeral)
    private let defaults: UserDefaults
    private var timer: Timer?

    private static let dismissedVersionKey = DefaultsKeys.dismissedUpdateVersion
    private static let lastRunVersionKey = DefaultsKeys.lastRunVersion
    private static let latestReleaseURL =
        URL(string: "https://api.github.com/repos/jedijashwa/pullmark/releases/latest")!
    private static let releaseListURL =
        URL(string: "https://api.github.com/repos/jedijashwa/pullmark/releases?per_page=20")!

    init(currentVersion: String? = nil, defaults: UserDefaults = .standard) {
        self.currentVersion = currentVersion
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.0.0"
        self.defaults = defaults
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

    /// Raises the banner for a qualifying release. Internal (not private)
    /// so the dismissal rules stay unit-testable without the network.
    func apply(_ release: UpdateRelease, ignoringDismissal: Bool) {
        guard release.draft != true, release.prerelease != true,
              SemVer.isNewer(release.tagName, than: currentVersion) else { return }
        let version = SemVer.normalized(release.tagName)
        if !ignoringDismissal,
           defaults.string(forKey: Self.dismissedVersionKey) == version {
            return
        }
        availableVersion = version
        availableNotes = release.body ?? ""
        availableURL = release.htmlUrl
        availableZipURL = release.zipAssetURL
    }

    /// Hides the banner and remembers the version so it never re-nags
    /// (a manual check can still bring it back).
    func dismissAvailableUpdate() {
        if let availableVersion {
            defaults.set(availableVersion, forKey: Self.dismissedVersionKey)
        }
        availableVersion = nil
        availableNotes = ""
        availableURL = nil
        availableZipURL = nil
        updateRun = .idle
    }

    func copyBrewCommand() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(BrewUpdate.command, forType: .string)
    }

    // MARK: Update Now

    /// Called when the banner appears: probes brew off the main thread to
    /// decide between brew upgrade, in-place self-update, and "Download".
    func detectUpdateMethodIfNeeded() {
        guard updateMethod == nil else { return }
        let bundlePath = Bundle.main.bundlePath
        Task.detached(priority: .utility) { [weak self] in
            let method = BrewUpdate.detectMethod(
                bundlePath: bundlePath,
                fileExists: { FileManager.default.isExecutableFile(atPath: $0) },
                runner: BrewUpdate.run
            )
            // Rebound to a `let` so the MainActor closure captures an
            // immutable reference (weak `self` is a var — a Swift 6 error).
            guard let self else { return }
            await MainActor.run { self.updateMethod = method }
        }
    }

    /// Primary banner action: brew-managed installs upgrade via brew;
    /// other real .app installs self-update in place; dev builds open
    /// the release page.
    func updateNow() {
        switch updateMethod {
        case .brew(let brewPath):
            runBrewUpgrade(brewPath: brewPath)
        case .selfUpdate:
            runSelfUpdate()
        case .download, nil:
            openReleasePage()
        }
    }

    /// Opens the GitHub release page — the manual-update fallback.
    func openReleasePage() {
        if let availableURL, let url = URL(string: availableURL) {
            NSWorkspace.shared.open(url)
        }
    }

    private func runBrewUpgrade(brewPath: String) {
        guard !isUpdating else { return }
        updateRun = .updating("Updating…")
        Task.detached(priority: .userInitiated) { [weak self] in
            let failure = BrewUpdate.runUpgrade(brewPath: brewPath)
            guard let self else { return }
            await MainActor.run {
                if let failure {
                    self.updateRun = .failed(failure)
                } else {
                    self.relaunchAfterUpdate()
                }
            }
        }
    }

    // MARK: In-place self-update (non-brew .app installs)

    /// Downloads the release zip to $TMPDIR (purgeable), unpacks it, verifies
    /// the signature (seal intact, Team ID matches, Gatekeeper accepts), and
    /// swaps the running bundle. Any failure aborts, cleans the temp dir,
    /// surfaces the error in the banner, and opens the release page so the
    /// user can still update by hand.
    private func runSelfUpdate() {
        guard !isUpdating else { return }
        guard let zipString = availableZipURL, let zipURL = URL(string: zipString) else {
            openReleasePage()  // release has no zip asset: nothing to install
            return
        }
        updateRun = .updating("Downloading…")
        let targetPath = Bundle.main.bundlePath
        Task { [weak self] in
            await self?.performSelfUpdate(zipURL: zipURL, targetPath: targetPath)
        }
    }

    private func performSelfUpdate(zipURL: URL, targetPath: String) async {
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory
            .appendingPathComponent("PullMark-update-\(UUID().uuidString)", isDirectory: true)
        func fail(_ message: String) {
            try? fm.removeItem(at: workDir)
            updateRun = .failed(message)
            openReleasePage()
        }
        do {
            try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
            var request = URLRequest(url: zipURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (downloaded, response) = try await session.download(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                fail("download failed (HTTP \(http.statusCode))")
                return
            }
            let zipFile = workDir.appendingPathComponent("PullMark.zip")
            try fm.moveItem(at: downloaded, to: zipFile)

            updateRun = .updating("Verifying…")
            let unpackDir = workDir.appendingPathComponent("unpacked", isDirectory: true)
            let verified: Result<String, MessageError> =
                await Task.detached(priority: .userInitiated) {
                    let unpack = SelfUpdate.run(SelfUpdate.unpackCommand(
                        zipPath: zipFile.path, destination: unpackDir.path))
                    guard unpack.status == 0 else {
                        return .failure(MessageError(message: "could not unpack the downloaded archive"))
                    }
                    guard let app = SelfUpdate.findApp(in: unpackDir) else {
                        return .failure(MessageError(message: "the downloaded archive contains no app"))
                    }
                    if let reason = SelfUpdate.verify(appPath: app.path, runner: SelfUpdate.run) {
                        return .failure(MessageError(message: reason))
                    }
                    return .success(app.path)
                }.value
            let newAppPath: String
            switch verified {
            case .failure(let error): fail(error.message); return
            case .success(let path): newAppPath = path
            }

            updateRun = .updating("Installing…")
            try await Task.detached(priority: .userInitiated) {
                try SelfUpdate.install(newApp: URL(fileURLWithPath: newAppPath),
                                       over: URL(fileURLWithPath: targetPath))
            }.value
            try? fm.removeItem(at: workDir)
            relaunchAfterUpdate()
        } catch {
            fail(error.localizedDescription)
        }
    }

    /// Spawns a detached relauncher and quits so brew's freshly installed
    /// version starts clean.
    private func relaunchAfterUpdate() {
        let appPath = BrewUpdate.relaunchAppPath(bundlePath: Bundle.main.bundlePath)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", BrewUpdate.relaunchShellCommand(appPath: appPath)]
        try? process.run()
        NSApp.terminate(nil)
    }

    // MARK: Post-update "What's New"

    /// If the app was updated since the last run, collects the release notes
    /// of every version between the two and presents them. First-ever launch
    /// just records the version.
    private func presentWhatsNewIfUpdated() async {
        guard currentVersion != "0.0.0" else { return }
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
