import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Pure logic (unit-tested)

/// Decision logic for the "default Markdown app" Settings row and the
/// "no longer your default" banner. Launch Services drops the `.md` binding
/// when the app bundle is replaced on disk (brew upgrades delete + recreate
/// it), so PullMark remembers that the user claimed the default and offers to
/// reclaim it when the binding points elsewhere. Kept pure so it stays
/// unit-testable.
enum DefaultMarkdownApp {
    /// The UTType `.md` files conform to; every Markdown handler binds to it.
    static var contentType: UTType? { UTType("net.daringfireball.markdown") }

    /// Whether to offer reclaiming the default (the loss banner and the
    /// re-claim button): only when running from a real .app bundle (never
    /// `swift run` — a dev binary must not grab the binding), the user
    /// previously made PullMark the default, and Launch Services now resolves
    /// the handler to a different app — or to none at all.
    static func shouldOffer(claimed: Bool,
                            currentHandlerURL: URL?,
                            bundleURL: URL,
                            isAppBundle: Bool) -> Bool {
        guard isAppBundle, claimed else { return false }
        guard let currentHandlerURL else { return true }
        return currentHandlerURL.standardizedFileURL.path
            != bundleURL.standardizedFileURL.path
    }
}

// MARK: - Live state

/// Observes the system's current Markdown handler and claims/reclaims the
/// default via NSWorkspace. Shared between the Settings row and the loss
/// banner so both react to the same state.
@MainActor
final class DefaultAppManager: ObservableObject {
    /// Where Launch Services currently resolves the Markdown handler.
    @Published private(set) var currentHandlerURL: URL?
    /// Mirrors `DefaultsKeys.claimedDefaultHandler` (published so views react).
    @Published private(set) var claimed: Bool
    /// User-facing failure from the last claim attempt.
    @Published var lastError: String?
    /// A claim request is in flight.
    @Published private(set) var claiming = false

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        claimed = defaults.bool(forKey: DefaultsKeys.claimedDefaultHandler)
        refresh()
    }

    /// True when running from a .app bundle (false under `swift run`).
    var isAppBundle: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    var isPullMarkDefault: Bool {
        currentHandlerURL?.standardizedFileURL.path
            == Bundle.main.bundleURL.standardizedFileURL.path
    }

    /// Drives the "no longer your default" banner.
    var showLossBanner: Bool {
        DefaultMarkdownApp.shouldOffer(claimed: claimed,
                                       currentHandlerURL: currentHandlerURL,
                                       bundleURL: Bundle.main.bundleURL,
                                       isAppBundle: isAppBundle)
    }

    /// Display name of the current handler ("PullMark", "Xcode", …).
    var currentHandlerName: String? {
        guard let url = currentHandlerURL else { return nil }
        let bundle = Bundle(url: url)
        return bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? FileManager.default.displayName(atPath: url.path)
    }

    /// Finder icon of the current handler.
    var currentHandlerIcon: NSImage? {
        currentHandlerURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    /// Re-resolves the current handler from Launch Services.
    func refresh() {
        guard let type = DefaultMarkdownApp.contentType else { return }
        currentHandlerURL = NSWorkspace.shared.urlForApplication(toOpen: type)
    }

    /// Makes this bundle the Markdown default and, on success, remembers that
    /// the user claimed it (so a later loss raises the banner).
    func makeDefault() {
        guard isAppBundle, let type = DefaultMarkdownApp.contentType, !claiming else { return }
        claiming = true
        lastError = nil
        NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL,
                                                 toOpen: type) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                self.claiming = false
                if let error {
                    self.lastError = error.localizedDescription
                } else {
                    self.setClaimed(true)
                }
                self.refresh()
            }
        }
    }

    /// Dismissing the loss banner clears the claim, so it never nags again
    /// until the user makes PullMark the default another time.
    func dismissLossBanner() {
        setClaimed(false)
    }

    private func setClaimed(_ value: Bool) {
        claimed = value
        defaults.set(value, forKey: DefaultsKeys.claimedDefaultHandler)
    }
}
