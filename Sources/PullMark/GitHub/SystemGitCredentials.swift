import Foundation

/// Resolves a GitHub token from credentials already configured on the system,
/// so the app works with private/organization repos without its own login flow.
/// Order: `gh auth token` (GitHub CLI), then `git credential fill` (keychain
/// or any other configured credential helper).
enum SystemGitCredentials {
    /// Where a resolved token came from — named in the Settings status
    /// row ("Connected as X · GitHub CLI") and the setup sheet's ✓ state
    /// (spec: github-connection).
    enum Source: String {
        case githubCLI
        case credentialHelper

        var label: String {
            switch self {
            case .githubCLI: return String(localized: "GitHub CLI")
            case .credentialHelper: return String(localized: "git credential helper")
            }
        }
    }

    /// A signed-out machine on demand: dist trials on a fully-authed
    /// Mac can't otherwise reach the signed-out surfaces (PM_DEMO-style
    /// env hook; spec: github-connection). "1" = signed out (gh
    /// detection stays real, so the sheet shows its sign-in step);
    /// "nogh" = also pretend gh isn't installed (the install step).
    enum TestHookMode {
        case none, signedOut, noCLI
    }

    /// Pure parse so tests can pin it: unknown values are OFF —
    /// a typo'd hook must never silently sign a real user out.
    static func testHookMode(_ raw: String?) -> TestHookMode {
        switch raw {
        case "1": return .signedOut
        case "nogh": return .noCLI
        default: return .none
        }
    }

    private static var hookMode: TestHookMode {
        testHookMode(ProcessInfo.processInfo.environment["PM_NO_CREDENTIALS"])
    }

    static var credentialsDisabled: Bool {
        hookMode != .none
    }

    private static var pretendNoCLI: Bool {
        hookMode == .noCLI
    }

    static func resolveToken(host: String = "github.com") -> (token: String, source: Source)? {
        guard !credentialsDisabled else { return nil }
        if let out = runProcess(["gh", "auth", "token", "--hostname", host]) {
            let token = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty, !token.contains(" ") {
                return (token, .githubCLI)
            }
        }
        let input = "protocol=https\nhost=\(host)\n\n"
        if let out = runProcess(["git", "credential", "fill"], stdin: input,
                                extraEnv: ["GIT_TERMINAL_PROMPT": "0"]),
           let password = parseCredentialPassword(out) {
            return (password, .credentialHelper)
        }
        return nil
    }

    /// Setup-sheet detection: is `gh` reachable on the (extended) PATH
    /// at all? Distinguishes "install it" from "sign in" (the sheet's
    /// two steps).
    static func githubCLIInstalled() -> Bool {
        guard !pretendNoCLI else { return false }
        return runProcess(["which", "gh"])?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    /// Parses `git credential fill` key=value output.
    static func parseCredentialPassword(_ output: String?) -> String? {
        guard let output else { return nil }
        for line in output.components(separatedBy: "\n") {
            if line.hasPrefix("password=") {
                let value = String(line.dropFirst("password=".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    /// GUI apps get a minimal PATH, so extend it with the usual Homebrew and
    /// local bin locations before invoking `gh`/`git`.
    private static func runProcess(_ args: [String], stdin: String? = nil,
                                   extraEnv: [String: String] = [:]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args

        var env = ProcessInfo.processInfo.environment
        let extraPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        env["PATH"] = ((env["PATH"].map { [$0] } ?? []) + extraPaths).joined(separator: ":")
        for (k, v) in extraEnv { env[k] = v }
        process.environment = env

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        // Discard rather than Pipe(): an undrained pipe can fill and
        // deadlock the child if it writes enough to stderr.
        process.standardError = FileHandle.nullDevice

        if let stdin {
            let stdinPipe = Pipe()
            process.standardInput = stdinPipe
            stdinPipe.fileHandleForWriting.write(Data(stdin.utf8))
            stdinPipe.fileHandleForWriting.closeFile()
        }

        do {
            try process.run()
        } catch {
            return nil
        }
        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
