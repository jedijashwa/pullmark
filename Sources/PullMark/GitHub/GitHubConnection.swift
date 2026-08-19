import Foundation

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
        } else {
            status = .notConnected
        }
    }

    /// Demo fixtures are authored as a signed-in world — the row shows
    /// the fiction and signed-out surfaces never appear over it.
    func reportDemoFiction() {
        status = .connected(login: DemoSession.viewerLogin, source: .githubCLI)
    }
}
