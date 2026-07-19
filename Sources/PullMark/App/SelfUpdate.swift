import Foundation

// MARK: - Self-update engine (non-brew installs)

/// An external command the self-update pipeline wants to run.
/// Construction is pure so tests can assert on the exact invocation.
struct SelfUpdateCommand: Equatable {
    let executable: String
    let arguments: [String]
}

/// Outcome of running a `SelfUpdateCommand`.
struct SelfUpdateCommandResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

/// Downloads, verifies, and installs a new PullMark.app in place for installs
/// that brew doesn't manage. All decision logic (command construction, output
/// parsing, verification gating) is pure; the `Process` runner is injected so
/// tests never shell out.
enum SelfUpdate {
    /// Apple Developer Team ID every downloaded update must be signed by.
    static let expectedTeamID = "35F47G5Y6D"

    // MARK: Command construction (pure)

    static func unpackCommand(zipPath: String, destination: String) -> SelfUpdateCommand {
        SelfUpdateCommand(executable: "/usr/bin/ditto",
                          arguments: ["-xk", zipPath, destination])
    }

    /// Gate 1: the signature is intact over the whole bundle.
    static func verifyCommand(appPath: String) -> SelfUpdateCommand {
        SelfUpdateCommand(executable: "/usr/bin/codesign",
                          arguments: ["--verify", "--deep", "--strict", appPath])
    }

    /// Gate 2 input: signing details (TeamIdentifier lives in this output).
    static func infoCommand(appPath: String) -> SelfUpdateCommand {
        SelfUpdateCommand(executable: "/usr/bin/codesign",
                          arguments: ["-dvv", appPath])
    }

    /// Gate 3: Gatekeeper assessment (requires notarization for downloads).
    /// Note: spctl lives in /usr/sbin, unlike codesign and ditto.
    static func notarizationCommand(appPath: String) -> SelfUpdateCommand {
        SelfUpdateCommand(executable: "/usr/sbin/spctl",
                          arguments: ["-a", "-t", "exec", appPath])
    }

    // MARK: Parsing (pure)

    /// Extracts `TeamIdentifier=XXXXXXXXXX` from `codesign -dvv` output
    /// (codesign prints details to stderr). Ad-hoc signatures report
    /// "not set", which counts as no identity.
    static func teamIdentifier(fromCodesignInfo output: String) -> String? {
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("TeamIdentifier=") else { continue }
            let value = String(trimmed.dropFirst("TeamIdentifier=".count))
            return (value.isEmpty || value == "not set") ? nil : value
        }
        return nil
    }

    /// Runs the three verification gates against an unpacked app. Returns nil
    /// when the app is safe to install, otherwise a short user-facing reason.
    /// Anything less than full success — broken seal, missing or wrong Team ID,
    /// Gatekeeper rejection — aborts the update.
    static func verify(appPath: String,
                       expectedTeamID: String = SelfUpdate.expectedTeamID,
                       runner: (SelfUpdateCommand) -> SelfUpdateCommandResult) -> String? {
        guard runner(verifyCommand(appPath: appPath)).status == 0 else {
            return "the download's code signature is invalid"
        }
        let info = runner(infoCommand(appPath: appPath))
        let details = info.stderr + "\n" + info.stdout
        guard info.status == 0,
              let team = teamIdentifier(fromCodesignInfo: details) else {
            return "could not read the download's signing identity"
        }
        guard team == expectedTeamID else {
            return "the download is signed by an unexpected team (\(team))"
        }
        guard runner(notarizationCommand(appPath: appPath)).status == 0 else {
            return "Gatekeeper rejected the download (notarization check failed)"
        }
        return nil
    }

    /// The single `.app` bundle inside an extraction directory.
    static func findApp(in directory: URL,
                        fileManager: FileManager = .default) -> URL? {
        let entries = (try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return entries.first { $0.pathExtension == "app" }
    }

    // MARK: Install (rename dance — never leaves a half-app)

    /// Replaces `target` with `newApp`: the new bundle is first copied next to
    /// the target (same volume, so the final step is an atomic rename), the old
    /// bundle is renamed aside, and the staged copy renamed into place. If that
    /// last rename fails the old bundle is restored, so a failure can never
    /// leave a half-installed app.
    static func install(newApp: URL, over target: URL,
                        fileManager fm: FileManager = .default) throws {
        let dir = target.deletingLastPathComponent()
        let token = UUID().uuidString
        let staged = dir.appendingPathComponent(".\(target.lastPathComponent).new-\(token)")
        let old = dir.appendingPathComponent(".\(target.lastPathComponent).old-\(token)")
        try fm.copyItem(at: newApp, to: staged)
        do {
            try fm.moveItem(at: target, to: old)
        } catch {
            try? fm.removeItem(at: staged)
            throw error
        }
        do {
            try fm.moveItem(at: staged, to: target)
        } catch {
            try? fm.moveItem(at: old, to: target)  // put the old version back
            try? fm.removeItem(at: staged)
            throw error
        }
        try? fm.removeItem(at: old)
    }

    // MARK: Real runner

    /// Executes a command and captures its output. Blocks — call off the
    /// main thread.
    static func run(_ command: SelfUpdateCommand) -> SelfUpdateCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch {
            return SelfUpdateCommandResult(status: -1, stdout: "",
                                           stderr: error.localizedDescription)
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return SelfUpdateCommandResult(
            status: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }
}
