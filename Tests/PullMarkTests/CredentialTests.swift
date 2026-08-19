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
