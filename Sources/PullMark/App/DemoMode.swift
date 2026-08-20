import Foundation

/// The committed demo mode: `PM_DEMO=1` launches the app into a fully
/// populated fictional session (see DemoSession) — entirely offline, with
/// nothing persisted. Screenshots that leave this machine (site, README)
/// must never show real document names, repo paths, PR titles, or the
/// maintainer's account; this fixture is what release screenshots are
/// taken from.
///
/// Without the variable the gate is a single cached environment check —
/// zero behavior change, zero cost.
enum DemoMode {
    /// One env check, resolved once at first use.
    static let active = isActive(environment: ProcessInfo.processInfo.environment)

    /// Testable core of the gate: exactly `PM_DEMO=1` activates it.
    static func isActive(environment: [String: String]) -> Bool {
        environment["PM_DEMO"] == "1"
    }

    /// The isolated defaults domain demo launches read and write — never
    /// the app's real `app.pullmark.PullMark` domain.
    /// Per-process: the screenshot generator runs MANY demo instances in
    /// parallel, each wiping its suite at startup — with a shared name,
    /// every launch nuked every other instance's live state (@AppStorage
    /// observed the wipe and reset blame mid-scene). Demo state is
    /// throwaway by definition, so nothing is lost by never sharing it.
    static let defaultsSuiteName = "app.pullmark.PullMark.demo.\(ProcessInfo.processInfo.processIdentifier)"
}

extension UserDefaults {
    /// THE persistence seam. Every defaults read and write in the app —
    /// `UserDefaults.pullmark` call sites and `@AppStorage(_, store:)`
    /// properties alike — goes through this instead of `.standard`.
    ///
    /// Normal launches: this IS `.standard`, byte-for-byte the previous
    /// behavior. Demo launches: an isolated suite, wiped at startup, so
    /// (a) demo state (session snapshot, recents, pending queues, drafts,
    /// reading positions, inbox bookkeeping) can never leak into the real
    /// domain, and (b) nothing real (recent file names, live PR refs)
    /// can leak into demo screenshots. The suite's own plist is emptied
    /// on every demo launch, so nothing persists between demo runs either.
    static let pullmark: UserDefaults = {
        guard DemoMode.active else { return .standard }
        // Janitor: per-pid suites (see defaultsSuiteName) would leave a
        // plist per past demo instance — clear the ones whose owner is
        // gone. kill(pid, 0) probes liveness without signaling, so
        // parallel LIVE instances are never touched.
        let preferences = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences")
        let prefix = "app.pullmark.PullMark.demo."
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: preferences.path) {
            for entry in entries where entry.hasPrefix(prefix) && entry.hasSuffix(".plist") {
                let stem = String(entry.dropFirst(prefix.count).dropLast(".plist".count))
                if let pid = Int32(stem), kill(pid, 0) != 0 {
                    UserDefaults().removePersistentDomain(forName: String(entry.dropLast(".plist".count)))
                }
            }
        }
        let name = DemoMode.defaultsSuiteName
        guard let suite = UserDefaults(suiteName: name) else { return .standard }
        suite.removePersistentDomain(forName: name)
        return suite
    }()
}
