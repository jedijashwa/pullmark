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
    /// Popover/panel body text (the macOS body default is 13pt).
    var body: Font? { scaled(13, or: nil) }
    /// Popover/panel headers (13pt semibold, the .headline default).
    var headline: Font? { scaled(13, weight: .semibold, or: .headline) }
    var callout: Font? { scaled(12, or: .callout) }
    var calloutSemibold: Font? { scaled(12, weight: .semibold, or: .callout.weight(.semibold)) }
    var caption: Font? { scaled(10, or: .caption) }
    var captionBold: Font? { scaled(10, weight: .bold, or: .caption.bold()) }
    var caption2: Font? { scaled(10, or: .caption2) }
    var caption2Bold: Font? { scaled(10, weight: .bold, or: .caption2.bold()) }
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
            let defaults = UserDefaults.pullmark
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

/// Transient "125%" pill shown at the top of the document area whenever the
/// zoom changes (menu, shortcut, or pinch), the way browsers surface it.
struct ZoomHUD: View {
    @AppStorage(DefaultsKeys.zoom, store: UserDefaults.pullmark) private var zoom = 1.0
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
