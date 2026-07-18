import Foundation

/// Resolves a GitHub token from credentials already configured on the system,
/// so the app works with private/organization repos without its own login flow.
/// Order: `gh auth token` (GitHub CLI), then `git credential fill` (keychain
/// or any other configured credential helper).
enum SystemGitCredentials {
    static func resolveToken(host: String = "github.com") -> String? {
        if let out = runProcess(["gh", "auth", "token", "--hostname", host]) {
            let token = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty, !token.contains(" ") {
                return token
            }
        }
        let input = "protocol=https\nhost=\(host)\n\n"
        if let out = runProcess(["git", "credential", "fill"], stdin: input,
                                extraEnv: ["GIT_TERMINAL_PROMPT": "0"]) {
            return parseCredentialPassword(out)
        }
        return nil
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
        process.standardError = Pipe()

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
