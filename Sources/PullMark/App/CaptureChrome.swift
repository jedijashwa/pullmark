import AppKit
import ObjectiveC
import WebKit

/// Screenshot-generator hook (`-pm.captureChrome 1`, argument domain
/// only): windows draw ACTIVE chrome — colored traffic lights, accent
/// selection — while the app stays backgrounded. The generator captures
/// many instances in parallel without ever stealing focus, and the
/// pixels come out identical to a frontmost window's.
///
/// AppKit and SwiftUI consult isKeyWindow / isMainWindow /
/// NSApp.isActive when drawing window chrome and resolving
/// controlActiveState; there is no supported per-window "appear
/// active" switch on macOS 13, so the getters are swizzled to return
/// true. Capture instances are driven purely through AX and
/// pid-targeted events and never see real user input, so the lie has
/// no one to confuse. Never set this flag on a normal run.
enum CaptureChrome {
    static var isActive: Bool {
        UserDefaults.standard.bool(forKey: "pm.captureChrome")
    }

    static func installIfRequested() {
        guard isActive else { return }
        forceTrue(NSWindow.self, #selector(getter: NSWindow.isKeyWindow))
        forceTrue(NSWindow.self, #selector(getter: NSWindow.isMainWindow))
        forceTrue(NSApplication.self, #selector(getter: NSApplication.isActive))
        // Selection color: row views draw the accent only when
        // "emphasized" (their table in the key responder chain) —
        // force it so sidebar selection captures blue, not gray.
        forceTrue(NSTableRowView.self, #selector(getter: NSTableRowView.isEmphasized))
        // A never-activated app has no key window, so AppKit DROPS posted
        // keyboard events (and menu key equivalents). Nominate one: the
        // most recently created visible window that can take key status —
        // panels (Open Quickly, Open) appear after the main window and
        // win while they're up, which is exactly the routing a user's
        // focus would produce.
        let keyWindowGetter = #selector(getter: NSApplication.keyWindow)
        if let method = class_getInstanceMethod(NSApplication.self, keyWindowGetter) {
            let nominate: @convention(block) (AnyObject) -> NSWindow? = { _ in
                // orderedWindows is front-to-back z-order: an open panel
                // (Open Quickly, Open) floats above the main window and
                // wins, exactly as real focus would.
                NSApp.orderedWindows.first { $0.isVisible && $0.canBecomeKey }
                    ?? NSApp.windows.last { $0.isVisible && $0.canBecomeKey }
            }
            method_setImplementation(method, imp_implementationWithBlock(nominate))
        }
        // The getters alone aren't enough for SwiftUI: controlActiveState
        // caches "inactive" at window creation and only re-reads on the
        // become-key/main notifications, which a background window never
        // gets. Post them REPEATEDLY (every timer tick, every window):
        // toolbars rebuild on surface switches and freshly created item
        // views read activity state at creation — a one-shot blessing
        // left later toolbars drawing inactive (caught in a blame-scene
        // capture). Also seed a first responder: key events dispatch to
        // it, and a background window never ran the makeKey path.
        let blessAll = {
            for window in NSApp.windows where window.isVisible {
                if window.firstResponder === window,
                   let responder = window.initialFirstResponder ?? window.contentView {
                    window.makeFirstResponder(responder)
                }
                NotificationCenter.default.post(
                    name: NSWindow.didBecomeMainNotification, object: window)
                NotificationCenter.default.post(
                    name: NSWindow.didBecomeKeyNotification, object: window)
            }
        }
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in blessAll() }
    }

    private static func forceTrue(_ cls: AnyClass, _ selector: Selector) {
        guard let method = class_getInstanceMethod(cls, selector) else { return }
        let alwaysTrue: @convention(block) (AnyObject) -> Bool = { _ in true }
        method_setImplementation(method, imp_implementationWithBlock(alwaysTrue))
    }

    /// pullmark://capture/… — the generator's drive channel for the few
    /// page interactions no accessibility or keyboard path can reach.
    /// Routed only when the capture flag is set (see AppLinkRouter).
    @MainActor
    static func handleCaptureURL(_ url: URL) {
        guard url.path == "/reveal",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let lineText = components.queryItems?.first(where: { $0.name == "line" })?.value,
              let line = Int(lineText)
        else { return }
        let webView = NSApp.orderedWindows.lazy
            .compactMap { $0.contentView.flatMap(findWebView) }
            .first
        webView?.evaluateJavaScript(
            "window.__pmRevealBlock && __pmRevealBlock(\(line));",
            completionHandler: nil)
    }

    private static func findWebView(in view: NSView) -> WKWebView? {
        if let webView = view as? WKWebView { return webView }
        for subview in view.subviews {
            if let found = findWebView(in: subview) { return found }
        }
        return nil
    }
}
