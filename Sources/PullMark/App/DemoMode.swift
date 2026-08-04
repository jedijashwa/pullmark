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
    static let defaultsSuiteName = "app.pullmark.PullMark.demo"
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
        let name = DemoMode.defaultsSuiteName
        guard let suite = UserDefaults(suiteName: name) else { return .standard }
        suite.removePersistentDomain(forName: name)
        return suite
    }()
}
