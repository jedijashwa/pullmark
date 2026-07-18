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
}
