import AppKit

/// Installs the `pullmark` shell command for non-Homebrew installs (the
/// DMG path): a symlink in /usr/local/bin pointing at the shim shipped
/// inside the app bundle — the VS Code "install 'code' command" pattern.
/// Homebrew users get the same shim via the cask's binary stanza; this
/// covers everyone else from Settings.
enum CLIInstaller {
    static let linkPath = "/usr/local/bin/pullmark"

    /// The shim inside the running app's bundle.
    static var bundledShim: URL? {
        Bundle.main.url(forResource: "pullmark", withExtension: nil)
    }

    enum Status: Equatable {
        /// A `pullmark` on the PATH already resolves (this symlink, the
        /// Homebrew one, or anything else the user set up).
        case installed
        case notInstalled
        /// The dev build has no shim in its bundle to link.
        case unavailable
    }

    static var status: Status {
        guard bundledShim != nil else { return .unavailable }
        let env = ProcessInfo.processInfo.environment["PATH"]
            ?? "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"
        for dir in env.split(separator: ":") {
            let candidate = String(dir) + "/pullmark"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return .installed
            }
        }
        // GUI apps inherit a minimal PATH; check the two conventional
        // prefixes directly so a shell-visible install still reads as such.
        for candidate in [linkPath, "/opt/homebrew/bin/pullmark"] {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return .installed
            }
        }
        return .notInstalled
    }

    /// Symlinks the bundled shim into /usr/local/bin. Tries directly
    /// first; when the directory needs privileges, escalates through the
    /// system's administrator prompt. Returns nil on success, else the
    /// failure to show.
    static func install() -> String? {
        guard let shim = bundledShim else {
            return String(localized: "This build doesn't include the command-line tool.")
        }
        let fm = FileManager.default
        do {
            try? fm.removeItem(atPath: linkPath)
            try fm.createDirectory(atPath: "/usr/local/bin",
                                   withIntermediateDirectories: true)
            try fm.createSymbolicLink(atPath: linkPath,
                                      withDestinationPath: shim.path)
            return nil
        } catch {
            // No permission for /usr/local/bin — ask properly.
            let script = "do shell script \"mkdir -p /usr/local/bin && "
                + "ln -sf '\(shim.path)' '\(linkPath)'\" "
                + "with administrator privileges"
            var errorInfo: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&errorInfo)
            if let errorInfo, errorInfo[NSAppleScript.errorNumber] as? Int != -128 {
                return String(localized: "Couldn't install the command: ")
                    + ((errorInfo[NSAppleScript.errorMessage] as? String)
                        ?? String(localized: "administrator authorization failed."))
            }
            if errorInfo != nil { return nil } // user cancelled — say nothing
            return nil
        }
    }
}
