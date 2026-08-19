import Foundation
import Testing
@testable import PullMark

@Suite struct CredentialTests {
    @Test func parsesPasswordFromCredentialFillOutput() {
        let output = "protocol=https\nhost=github.com\nusername=me\npassword=gho_secret123\n"
        #expect(SystemGitCredentials.parseCredentialPassword(output) == "gho_secret123")
    }

    @Test func missingPasswordReturnsNil() {
        #expect(SystemGitCredentials.parseCredentialPassword("protocol=https\nhost=github.com\n") == nil)
        #expect(SystemGitCredentials.parseCredentialPassword("password=\n") == nil)
        #expect(SystemGitCredentials.parseCredentialPassword(nil) == nil)
    }

    @Test func sourceLabelsNameTheTools() {
        // The Settings row prints these verbatim — "Connected as X ·
        // GitHub CLI" (spec: github-connection).
        #expect(SystemGitCredentials.Source.githubCLI.label == "GitHub CLI")
        #expect(SystemGitCredentials.Source.credentialHelper.label == "git credential helper")
    }

    @Test func testHookParsesOnlyItsTwoValues() {
        #expect(SystemGitCredentials.testHookMode("1") == .signedOut)
        #expect(SystemGitCredentials.testHookMode("nogh") == .noCLI)
        // Anything else is OFF — a typo'd hook must never silently
        // sign a real user out.
        #expect(SystemGitCredentials.testHookMode(nil) == .none)
        #expect(SystemGitCredentials.testHookMode("") == .none)
        #expect(SystemGitCredentials.testHookMode("0") == .none)
        #expect(SystemGitCredentials.testHookMode("true") == .none)
    }
}

/// The pure rules behind auth healing — the debounce window and the
/// auth-shape classification that gates setup affordances and
/// automatic re-resolution (spec: github-connection).
@Suite struct GitHubAuthRulesTests {
    @Test func debounceWindowBoundaries() {
        let last = Date(timeIntervalSince1970: 1_000)
        #expect(!GitHubAuthRules.shouldReprobe(
            now: last.addingTimeInterval(29), last: last))
        #expect(!GitHubAuthRules.shouldReprobe(
            now: last.addingTimeInterval(30), last: last))
        #expect(GitHubAuthRules.shouldReprobe(
            now: last.addingTimeInterval(31), last: last))
        // The reset value: distantPast always allows a probe.
        #expect(GitHubAuthRules.shouldReprobe(now: last, last: .distantPast))
    }

    @Test func authShapeTruthTable() {
        // 401 is auth-shaped regardless of connection state.
        #expect(GitHubAuthRules.isAuthShaped(status: 401, signedOut: true))
        #expect(GitHubAuthRules.isAuthShaped(status: 401, signedOut: false))
        // 404 only while signed out — GitHub answers 404 for
        // private-without-auth; connected 404s are typos/deletions.
        #expect(GitHubAuthRules.isAuthShaped(status: 404, signedOut: true))
        #expect(!GitHubAuthRules.isAuthShaped(status: 404, signedOut: false))
        // Rate-limit 403s must NEVER trigger subprocess re-resolution.
        #expect(!GitHubAuthRules.isAuthShaped(status: 403, signedOut: true))
        #expect(!GitHubAuthRules.isAuthShaped(status: 403, signedOut: false))
        #expect(!GitHubAuthRules.isAuthShaped(status: 500, signedOut: true))
    }
}

/// The observable the Settings row, setup sheet, and signed-out cue all
/// render from — its transitions are the contract.
@Suite @MainActor struct GitHubConnectionTests {
    @Test func tokenWithSourceReportsConnected() {
        let connection = GitHubConnection()
        connection.report(hasToken: true, login: "octo", source: .githubCLI)
        #expect(connection.status == .connected(login: "octo", source: .githubCLI))
        #expect(connection.isConnected)
    }

    @Test func loginArrivesLater() {
        // First resolution knows the source but not yet the viewer —
        // the row upgrades in place, never shows a wrong name.
        let connection = GitHubConnection()
        connection.report(hasToken: true, login: nil, source: .credentialHelper)
        #expect(connection.status == .connected(login: nil, source: .credentialHelper))
        connection.report(hasToken: true, login: "octo", source: .credentialHelper)
        #expect(connection.status == .connected(login: "octo", source: .credentialHelper))
    }

    @Test func noTokenReportsNotConnected() {
        let connection = GitHubConnection()
        connection.report(hasToken: false, login: nil, source: nil)
        #expect(connection.status == .notConnected)
        #expect(!connection.isConnected)
    }

    @Test func checkingIsATransientState() {
        let connection = GitHubConnection()
        connection.report(hasToken: false, login: nil, source: nil)
        connection.beginChecking()
        #expect(connection.status == .checking)
        #expect(!connection.isConnected)
    }

    @Test func demoFictionReadsSignedIn() {
        // Fixtures are authored as a signed-in world: the cue must never
        // appear over demo content, and the row shows the demo viewer.
        let connection = GitHubConnection()
        connection.reportDemoFiction()
        #expect(connection.isConnected)
        #expect(connection.status == .connected(login: DemoSession.viewerLogin,
                                                source: .githubCLI))
    }
}
