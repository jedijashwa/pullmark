import AppKit
import ObjectiveC

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
        // The getters alone aren't enough for SwiftUI: controlActiveState
        // caches "inactive" at window creation and only re-reads on the
        // become-key/main notifications, which a background window never
        // gets. Post them once per window as windows appear — observers
        // then re-read through the swizzled getters and land on active.
        let blessed = NSHashTable<NSWindow>.weakObjects()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didUpdateNotification, object: nil, queue: .main
        ) { _ in
            for window in NSApp.windows where !blessed.contains(window) {
                blessed.add(window)
                NotificationCenter.default.post(
                    name: NSWindow.didBecomeMainNotification, object: window)
                NotificationCenter.default.post(
                    name: NSWindow.didBecomeKeyNotification, object: window)
            }
        }
    }

    private static func forceTrue(_ cls: AnyClass, _ selector: Selector) {
        guard let method = class_getInstanceMethod(cls, selector) else { return }
        let alwaysTrue: @convention(block) (AnyObject) -> Bool = { _ in true }
        method_setImplementation(method, imp_implementationWithBlock(alwaysTrue))
    }
}
