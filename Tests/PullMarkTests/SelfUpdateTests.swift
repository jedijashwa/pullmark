import Foundation
import Testing
@testable import PullMark

/// Real (abridged) `codesign -dvv` output for a Developer ID-signed,
/// notarized PullMark.app — codesign prints these details to stderr.
private let developerIDInfo = """
Executable=/tmp/x/PullMark.app/Contents/MacOS/PullMark
Identifier=app.pullmark.PullMark
Format=app bundle with Mach-O thin (arm64)
CodeDirectory v=20500 size=6817 flags=0x10000(runtime) hashes=206+3 location=embedded
Signature size=9049
Authority=Developer ID Application: Josh Riesenbach (35F47G5Y6D)
Authority=Developer ID Certification Authority
Authority=Apple Root CA
Timestamp=Jul 19, 2026 at 11:05:55 AM
Notarization Ticket=stapled
Info.plist entries=14
TeamIdentifier=35F47G5Y6D
Runtime Version=26.5.0
Sealed Resources version=2 rules=13 files=12
Internal requirements count=1 size=184
"""

@Suite struct SelfUpdateParsingTests {
    @Test func extractsTeamIdentifierFromCodesignOutput() {
        #expect(SelfUpdate.teamIdentifier(fromCodesignInfo: developerIDInfo) == "35F47G5Y6D")
    }

    @Test func adHocSignatureHasNoTeamIdentifier() {
        // Ad-hoc signed bundles (SIGN_IDENTITY=-) report "not set".
        let adHoc = """
        Executable=/tmp/x/PullMark.app/Contents/MacOS/PullMark
        Identifier=app.pullmark.PullMark
        Signature=adhoc
        TeamIdentifier=not set
        """
        #expect(SelfUpdate.teamIdentifier(fromCodesignInfo: adHoc) == nil)
        #expect(SelfUpdate.teamIdentifier(fromCodesignInfo: "") == nil)
        #expect(SelfUpdate.teamIdentifier(fromCodesignInfo: "no such line") == nil)
    }

    @Test func expectedTeamIDIsThePullMarkTeam() {
        #expect(SelfUpdate.expectedTeamID == "35F47G5Y6D")
    }

    @Test func commandConstruction() {
        #expect(SelfUpdate.unpackCommand(zipPath: "/t/a.zip", destination: "/t/out")
            == SelfUpdateCommand(executable: "/usr/bin/ditto",
                                 arguments: ["-xk", "/t/a.zip", "/t/out"]))
        #expect(SelfUpdate.verifyCommand(appPath: "/t/A.app")
            == SelfUpdateCommand(executable: "/usr/bin/codesign",
                                 arguments: ["--verify", "--deep", "--strict", "/t/A.app"]))
        #expect(SelfUpdate.infoCommand(appPath: "/t/A.app")
            == SelfUpdateCommand(executable: "/usr/bin/codesign",
                                 arguments: ["-dvv", "/t/A.app"]))
        // spctl lives in /usr/sbin — /usr/bin/spctl does not exist.
        #expect(SelfUpdate.notarizationCommand(appPath: "/t/A.app")
            == SelfUpdateCommand(executable: "/usr/sbin/spctl",
                                 arguments: ["-a", "-t", "exec", "/t/A.app"]))
    }
}

@Suite struct SelfUpdateVerifyTests {
    private func result(_ status: Int32, stderr: String = "") -> SelfUpdateCommandResult {
        SelfUpdateCommandResult(status: status, stdout: "", stderr: stderr)
    }

    @Test func allGatesPassing() {
        var executed: [SelfUpdateCommand] = []
        let failure = SelfUpdate.verify(appPath: "/t/A.app") { command in
            executed.append(command)
            if command.arguments.first == "-dvv" {
                return result(0, stderr: developerIDInfo)
            }
            return result(0)
        }
        #expect(failure == nil)
        #expect(executed == [
            SelfUpdate.verifyCommand(appPath: "/t/A.app"),
            SelfUpdate.infoCommand(appPath: "/t/A.app"),
            SelfUpdate.notarizationCommand(appPath: "/t/A.app"),
        ])
    }

    @Test func brokenSignatureAbortsBeforeAnyOtherCheck() {
        var executed: [SelfUpdateCommand] = []
        let failure = SelfUpdate.verify(appPath: "/t/A.app") { command in
            executed.append(command)
            return result(1, stderr: "code signature invalid")
        }
        #expect(failure == "the download's code signature is invalid")
        #expect(executed.count == 1)  // stops at the first gate
    }

    @Test func wrongTeamIDIsRejected() {
        let failure = SelfUpdate.verify(appPath: "/t/A.app") { command in
            if command.arguments.first == "-dvv" {
                return result(0, stderr: "TeamIdentifier=EVIL123456")
            }
            return result(0)
        }
        #expect(failure == "the download is signed by an unexpected team (EVIL123456)")
    }

    @Test func adHocSignatureIsRejectedForMissingTeamID() {
        let failure = SelfUpdate.verify(appPath: "/t/A.app") { command in
            if command.arguments.first == "-dvv" {
                return result(0, stderr: "TeamIdentifier=not set")
            }
            return result(0)
        }
        #expect(failure == "could not read the download's signing identity")
    }

    @Test func gatekeeperRejectionFailsTheLastGate() {
        let failure = SelfUpdate.verify(appPath: "/t/A.app") { command in
            if command.executable == "/usr/sbin/spctl" {
                return result(3, stderr: "rejected")
            }
            if command.arguments.first == "-dvv" {
                return result(0, stderr: developerIDInfo)
            }
            return result(0)
        }
        #expect(failure == "Gatekeeper rejected the download (notarization check failed)")
    }
}

@Suite struct SelfUpdateInstallTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pm-selfupdate-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Creates a fake .app bundle whose identity is readable from a marker file.
    private func makeApp(named name: String, marker: String, in dir: URL) throws -> URL {
        let app = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try marker.write(to: app.appendingPathComponent("Contents/marker"),
                         atomically: true, encoding: .utf8)
        return app
    }

    @Test func findAppLocatesTheBundleInAnExtractionDirectory() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(SelfUpdate.findApp(in: dir) == nil)
        try "junk".write(to: dir.appendingPathComponent("README.txt"),
                         atomically: true, encoding: .utf8)
        _ = try makeApp(named: "PullMark.app", marker: "new", in: dir)
        // Compare the component, not full URLs: contentsOfDirectory resolves
        // /var → /private/var and adds directory trailing slashes.
        #expect(SelfUpdate.findApp(in: dir)?.lastPathComponent == "PullMark.app")
    }

    @Test func installReplacesTheTargetAndLeavesNoDebris() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: source) }

        let target = try makeApp(named: "PullMark.app", marker: "old", in: dir)
        let newApp = try makeApp(named: "PullMark.app", marker: "new", in: source)
        try SelfUpdate.install(newApp: newApp, over: target)

        let marker = try String(contentsOf: target.appendingPathComponent("Contents/marker"))
        #expect(marker == "new")
        // No staging/backup leftovers next to the target.
        let entries = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(entries == ["PullMark.app"])
        // The unpacked source copy is untouched (install copies, then renames).
        #expect(FileManager.default.fileExists(atPath: newApp.path))
    }

    @Test func failedStagingLeavesTheTargetInPlace() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = try makeApp(named: "PullMark.app", marker: "old", in: dir)

        // Source doesn't exist → the initial copy fails before the target
        // is ever touched.
        let missing = dir.appendingPathComponent("nope/PullMark.app")
        #expect(throws: (any Error).self) {
            try SelfUpdate.install(newApp: missing, over: target)
        }
        let marker = try String(contentsOf: target.appendingPathComponent("Contents/marker"))
        #expect(marker == "old")
        let entries = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(entries == ["PullMark.app"])
    }
}
