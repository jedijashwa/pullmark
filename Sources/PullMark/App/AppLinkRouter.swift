import AppKit
import Foundation

/// One landing spot for pullmark:// URLs however they arrive — the
/// SwiftUI scene's onOpenURL (which handlesExternalEvents(["*"]) makes
/// the usual path) or the app delegate's open-URLs callback. Both may
/// fire for one click, so identical URLs within a beat are handled once.
@MainActor
enum AppLinkRouter {
    private static var lastURL: URL?
    private static var lastAt = Date.distantPast

    static func handle(_ url: URL) {
        guard url.scheme == "pullmark" else { return }
        let now = Date()
        if url == lastURL, now.timeIntervalSince(lastAt) < 1 { return }
        lastURL = url
        lastAt = now
        if let target = AppLinks.settingsTarget(url) {
            SettingsOpener.open(tab: target.tab, anchor: target.anchor)
        } else if let compare = AppLinks.compareTarget(url) {
            AppState.deliverCompareOpen(file: compare.file, request: compare.request)
        } else {
            presentUnsupported(url)
        }
    }

    /// A deep link this build doesn't know — usually a website link to a
    /// feature from a newer version (or one that has since moved). Never
    /// a silent no-op: offer the update check, a pre-filled bug report
    /// carrying the link, or nothing.
    private static func presentUnsupported(_ url: URL) {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let alert = NSAlert()
        alert.messageText = String(localized: "That link needs a different version of PullMark")
        alert.informativeText = String(localized: "This version (\(version)) doesn't know ")
            + "\(url.absoluteString) — it may point at a feature from a newer "
            + "release, or one that has moved. Checking for updates usually "
            + "resolves it."
        alert.addButton(withTitle: String(localized: "Check for Updates…"))
        alert.addButton(withTitle: String(localized: "Report an Issue…"))
        alert.addButton(withTitle: String(localized: "Close"))
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            UpdateChecker.shared?.checkManuallyPresentingResult()
        case .alertSecondButtonReturn:
            let macOS = BugReport.macOSVersionString(
                ProcessInfo.processInfo.operatingSystemVersion)
            if let issue = BugReport.url(
                version: version, macOSVersion: macOS,
                title: "Unsupported link: \(url.absoluteString)",
                whatHappened: "Clicked a link that this version doesn't support: "
                    + url.absoluteString) {
                NSWorkspace.shared.open(issue)
            }
        default:
            break
        }
    }
}
