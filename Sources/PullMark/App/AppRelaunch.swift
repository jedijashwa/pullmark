import AppKit

/// Quit-and-reopen for settings that only apply at launch (today: the
/// language override). A detached shell outlives the app, waits out
/// the termination, and opens the bundle fresh — the standard trick,
/// since `open` against a still-running instance would just focus it.
enum AppRelaunch {
    static func relaunch() {
        let path = Bundle.main.bundleURL.path
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.6; /usr/bin/open \"$0\"", path]
        try? task.run()
        NSApp.terminate(nil)
    }
}
