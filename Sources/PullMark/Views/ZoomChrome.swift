import SwiftUI
import UniformTypeIdentifiers

/// Fonts for navigation chrome (sidebar rows, outline panel) that follow
/// the document zoom, at the damped `DocumentZoom.chromeScale` rate. Every
/// accessor returns nil (or the original text style) at factor 1.0, so the
/// default look stays pixel-identical to an unscaled build.
struct ChromeFonts {
    let factor: Double

    init(zoom: Double) {
        factor = DocumentZoom.chromeScale(for: zoom)
    }

    private func scaled(_ base: CGFloat, weight: Font.Weight? = nil,
                        or fallback: Font?) -> Font? {
        guard factor != 1 else { return fallback }
        let font = Font.system(size: base * factor)
        return weight.map { font.weight($0) } ?? font
    }

    /// Sidebar row text (the macOS sidebar default is 13pt).
    var row: Font? { scaled(13, or: nil) }
    /// Sidebar section headers (~11pt semibold) — they scale with their
    /// own rows; a 26pt row under an 11pt header would look broken.
    var sectionHeader: Font? { scaled(11, weight: .semibold, or: nil) }
    var callout: Font? { scaled(12, or: .callout) }
    var calloutSemibold: Font? { scaled(12, weight: .semibold, or: .callout.weight(.semibold)) }
    var caption: Font? { scaled(10, or: .caption) }
    var caption2: Font? { scaled(10, or: .caption2) }
    var footnote: Font? { scaled(10, or: .footnote) }
}

/// Invisible view that honors a physical "⌘+" press (which arrives as ⇧⌘=)
/// as Zoom In. The menu item owns ⌘= — the unshifted key — and a menu key
/// equivalent only matches one spelling, while SwiftUI's in-window shortcut
/// buttons never see window key equivalents at all. An NSView in the window
/// hierarchy does: NSWindow offers every key equivalent to the content
/// view's subtree before the menu bar. Lives only in document windows, so
/// Settings (and its shortcut recorder, a local monitor that runs even
/// earlier) is unaffected. Steps aside if the user rebinds Zoom In — a
/// moved shortcut must not leave a ghost of its default behind.
struct ZoomKeyCatcher: NSViewRepresentable {
    final class CatcherView: NSView {
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            let modifiers = event.modifierFlags
                .intersection([.command, .shift, .option, .control])
            // ⇧⌘= is a physical "⌘+" on US layouts; ⌘ alone with a "+"
            // character is the keypad's plus and layouts where + needs
            // no shift (German and friends) — the canonical zoom chord
            // there.
            guard event.type == .keyDown,
                  modifiers == [.command, .shift] || modifiers == [.command],
                  event.charactersIgnoringModifiers == "+",
                  !ShortcutStore.shared.isCustomized(.zoomIn),
                  ownsCombo(shift: modifiers.contains(.shift))
            else { return false }
            let defaults = UserDefaults.standard
            let stored = defaults.object(forKey: DefaultsKeys.zoom) as? Double ?? 1.0
            defaults.set(DocumentZoom.zoomIn(from: DocumentZoom.clamped(stored)),
                         forKey: DefaultsKeys.zoom)
            return true
        }

        /// The alternate must never shadow a shortcut the user recorded:
        /// nothing stops them binding ⇧⌘= (stored as "=" + shift) or a
        /// layout-native ⌘+ (stored as "+") to some other action, and
        /// this catcher runs before the menu bar sees the press.
        private func ownsCombo(shift: Bool) -> Bool {
            let spellings = [KeyCombo(key: "=", command: true, shift: shift),
                             KeyCombo(key: "+", command: true, shift: shift)]
            return !ShortcutAction.allCases.contains { action in
                guard action != .zoomIn,
                      let combo = ShortcutStore.shared.combo(for: action) else { return false }
                return spellings.contains(combo)
            }
        }
    }

    func makeNSView(context: Context) -> CatcherView { CatcherView() }
    func updateNSView(_ nsView: CatcherView, context: Context) {}
}

/// Native control capsule for the page's lightbox, floating bottom-center
/// over the web view — real material, real SF Symbols, native buttons —
/// while the stage (scrim, pan, zoom) stays in the page, where SVG
/// diagrams and formulas natively live. Commands round-trip through
/// `__pmLightbox`; Save As… and Share capture the rendered content via a
/// web-view snapshot of the content rect.
struct LightboxBar: View {
    @ObservedObject var proxy: WebViewProxy

    /// NSSharingServicePicker needs an AppKit anchor view.
    private final class AnchorBox {
        weak var view: NSView?
        var retainedPicker: NSSharingServicePicker?
    }
    private struct AnchorReader: NSViewRepresentable {
        let box: AnchorBox
        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            box.view = view
            return view
        }
        func updateNSView(_ nsView: NSView, context: Context) {}
    }
    @State private var anchor = AnchorBox()

    var body: some View {
        if let percent = proxy.lightboxPercent {
            HStack(spacing: 2) {
                control("minus.magnifyingglass", "Zoom out (-)") {
                    proxy.lightboxCommand("zoomBy(0.8)")
                }
                Text("\(percent)%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44)
                control("plus.magnifyingglass", "Zoom in (+)") {
                    proxy.lightboxCommand("zoomBy(1.25)")
                }
                control("arrow.up.left.and.arrow.down.right", "Fit to window (0)") {
                    proxy.lightboxCommand("fit()")
                }
                divider
                if proxy.lightboxKind == "svg" {
                    // Diagrams have a real format choice: the vector
                    // itself, or a raster for svg-averse destinations.
                    formatMenu("square.and.arrow.down", "Save As…",
                               svgTitle: "Save as SVG…", pngTitle: "Save as PNG…",
                               action: saveSnapshot)
                    formatMenu("square.and.arrow.up", "Share",
                               svgTitle: "Share as SVG", pngTitle: "Share as PNG",
                               action: shareSnapshot)
                        .background(AnchorReader(box: anchor))
                } else {
                    control("square.and.arrow.down", "Save As…") { saveSnapshot(format: nil) }
                    control("square.and.arrow.up", "Share") { shareSnapshot(format: nil) }
                        .background(AnchorReader(box: anchor))
                }
                divider
                control("xmark", "Close (Esc)") {
                    proxy.lightboxCommand("close()")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
            .overlay(
                Capsule().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.22), radius: 14, y: 5)
            .padding(.bottom, 22)
            .transition(.opacity)
            // The web view under the capsule keeps setting the stage's
            // grab cursor from its own mouse tracking — tell the page the
            // pointer is on the bar so it shows an arrow here instead.
            .onHover { over in
                proxy.lightboxCommand("barHover(\(over))")
            }
        }
    }

    private func control(_ symbol: String, _ title: String,
                         action: @escaping () -> Void) -> some View {
        LightboxBarButton(symbol: symbol, title: title, action: action)
    }

    private var divider: some View {
        Divider().frame(height: 16).padding(.horizontal, 3)
    }

    private func formatMenu(_ symbol: String, _ title: String,
                            svgTitle: String, pngTitle: String,
                            action: @escaping (WebViewProxy.LightboxFormat?) -> Void) -> some View {
        Menu {
            Button(svgTitle) { action(.svg) }
            Button(pngTitle) { action(.png) }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(title)
        .accessibilityLabel(title)
    }

    private func saveSnapshot(format: WebViewProxy.LightboxFormat?) {
        proxy.lightboxExport(format: format) { export in
            guard let export else { return }
            let panel = NSSavePanel()
            if let type = UTType(filenameExtension: export.fileExtension) {
                panel.allowedContentTypes = [type]
            }
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = export.name + "." + export.fileExtension
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try? export.data.write(to: url)
        }
    }

    private func shareSnapshot(format: WebViewProxy.LightboxFormat?) {
        proxy.lightboxExport(format: format) { export in
            // A named temp file shares better than raw data (AirDrop and
            // Mail keep the filename); the temp directory keeps it out of
            // anything persistent.
            guard let export, let anchorView = anchor.view else { return }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(export.name + "." + export.fileExtension)
            guard (try? export.data.write(to: url)) != nil else { return }
            let picker = NSSharingServicePicker(items: [url])
            anchor.retainedPicker = picker
            picker.show(relativeTo: anchorView.bounds, of: anchorView,
                        preferredEdge: .minY)
        }
    }
}

/// A capsule-bar control with an explicit hover highlight — borderless
/// buttons give no hover feedback of their own, which reads as dead over
/// a web view.
private struct LightboxBarButton: View {
    let symbol: String
    let title: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 30, height: 26)
                .background(
                    hovered ? Color.primary.opacity(0.12) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 7)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .onHover { hovered = $0 }
        .help(title)
        .accessibilityLabel(title)
    }
}

/// Transient "125%" pill shown at the top of the document area whenever the
/// zoom changes (menu, shortcut, or pinch), the way browsers surface it.
struct ZoomHUD: View {
    @AppStorage(DefaultsKeys.zoom) private var zoom = 1.0
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var visible = false
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        Group {
            if visible {
                Text(DocumentZoom.label(DocumentZoom.clamped(zoom)))
                    .font(.callout.monospacedDigit())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(
                        Capsule().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                    )
                    .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true) // announced app-wide below instead
        .onChange(of: zoom) { newValue in
            let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.1)) { visible = true }
            hideTask?.cancel()
            hideTask = Task {
                try? await Task.sleep(nanoseconds: 1_300_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.35)) { visible = false }
            }
            // VoiceOver can't see a transient pill (and pinch never goes
            // near a labeled menu item) — say where the zoom landed. Key
            // window only: zoom is app-wide and every window has a HUD.
            guard controlActiveState == .key else { return }
            NSAccessibility.post(
                element: NSApp as Any,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: "Zoom \(DocumentZoom.label(DocumentZoom.clamped(newValue)))",
                    .priority: NSAccessibilityPriorityLevel.high.rawValue,
                ])
        }
    }
}
