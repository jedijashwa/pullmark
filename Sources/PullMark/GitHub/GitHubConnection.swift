import Foundation

/// The pure rules behind auth healing (spec: github-connection),
/// extracted so tests can pin them (adversarial-review catch).
enum GitHubAuthRules {
    /// One subprocess re-probe per burst: true when the debounce
    /// window has passed since the last automatic re-resolution.
    static func shouldReprobe(now: Date, last: Date,
                              interval: TimeInterval = 30) -> Bool {
        now.timeIntervalSince(last) > interval
    }

    /// Auth-shaped failures get setup affordances: 401 always; 404
    /// only while signed out (GitHub answers 404 for private-without-
    /// auth, and a signed-out 404 is far more likely "private" than
    /// "typo"). Rate-limit 403s are never auth-shaped.
    static func isAuthShaped(status: Int, signedOut: Bool) -> Bool {
        status == 401 || (status == 404 && signedOut)
    }
}

/// Observable GitHub connection state (spec: github-connection) — what
/// the Settings status row, the setup sheet, and the PR overview's
/// signed-out cue render. The client owns the truth and reports here;
/// nothing else writes it.
@MainActor
final class GitHubConnection: ObservableObject {
    enum Status: Equatable {
        /// Resolution hasn't run yet (or Check Again is running).
        case checking
        /// A token resolved. `login` fills in once the viewer identity
        /// fetch lands — the row reads "Connected · GitHub CLI" until
        /// then, never a wrong name.
        case connected(login: String?, source: SystemGitCredentials.Source)
        case notConnected
    }

    @Published private(set) var status: Status = .checking
    /// The last SETTLED verdict was not-connected — held true through
    /// .checking passes so sticky surfaces (the Settings alert) don't
    /// blink out on every Check Again, and only a real connect clears
    /// it. Model-level because view-local state on conditional content
    /// never mounts its observers (a view whose body is empty gets no
    /// onAppear/onChange).
    @Published private(set) var settledNotConnected = false

    var isConnected: Bool {
        if case .connected = status { return true }
        return false
    }

    func beginChecking() {
        status = .checking
    }

    func report(hasToken: Bool, login: String?,
                source: SystemGitCredentials.Source?) {
        if hasToken, let source {
            status = .connected(login: login, source: source)
            settledNotConnected = false
        } else {
            status = .notConnected
            settledNotConnected = true
        }
    }

    /// Demo fixtures are authored as a signed-in world — the row shows
    /// the fiction and signed-out surfaces never appear over it.
    func reportDemoFiction() {
        status = .connected(login: DemoSession.viewerLogin, source: .githubCLI)
        settledNotConnected = false
    }
}
