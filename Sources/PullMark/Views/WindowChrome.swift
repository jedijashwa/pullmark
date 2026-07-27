import SwiftUI

/// Gives the window the standard document-proxy affordances for the
/// selected local file: the draggable file icon in the title bar and the
/// ⌘-click folder-path menu. macOS 14 has a real API for this
/// (`.navigationDocument`) — this AppKit fallback covers macOS 13, where
/// SwiftUI never exposes `NSWindow.representedURL`. Selection is nil for
/// PR content — there is no file on disk to proxy.
/// Titlebar document proxy: `navigationDocument` where it exists, the
/// AppKit accessor below on macOS 13. A nil URL clears the proxy (the
/// macOS 14 branch simply omits the modifier — SwiftUI resets the
/// window's represented document when it disappears).
struct DocumentProxyModifier: ViewModifier {
    let url: URL?

    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            if let url {
                content.navigationDocument(url)
            } else {
                content
            }
        } else {
            content.background(WindowRepresentedURL(url: url))
        }
    }
}

struct WindowRepresentedURL: NSViewRepresentable {
    let url: URL?

    final class AccessorView: NSView {
        var url: URL? {
            didSet { if url != oldValue { apply() } }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        fileprivate func apply() {
            window?.representedURL = url
        }
    }

    func makeNSView(context: Context) -> AccessorView { AccessorView() }

    func updateNSView(_ view: AccessorView, context: Context) {
        view.url = url
        // SwiftUI rewrites the window title on navigation changes, which
        // can clear the represented URL out from under us — re-assert on
        // every update pass, cheaply.
        view.apply()
    }
}
