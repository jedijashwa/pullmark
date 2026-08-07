import SwiftUI

/// The scroll-and-highlight half of settings deep links: a pending
/// anchor waits for its tab to appear, the tab scrolls to the row, and
/// the row flashes. One shared instance — Settings is one window.
@MainActor
final class SettingsAnchorFocus: ObservableObject {
    static let shared = SettingsAnchorFocus()

    /// Anchor waiting to be scrolled to by whichever tab owns it.
    @Published var pending: String?
    /// Anchor currently wearing the highlight flash.
    @Published var highlighted: String?

    /// A tab has scrolled to the anchor: flash, then fade.
    func markHighlighted(_ anchor: String) {
        highlighted = anchor
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            if highlighted == anchor { highlighted = nil }
        }
    }
}

/// Marks a settings control as a deep-link landing spot: gives it the
/// scroll id and the highlight flash.
private struct SettingAnchor: ViewModifier {
    let id: String
    @ObservedObject private var focus = SettingsAnchorFocus.shared

    func body(content: Content) -> some View {
        content
            .id(id)
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.accentColor.opacity(focus.highlighted == id ? 0.22 : 0))
                    .padding(-6)
                    .allowsHitTesting(false)
                    .animation(.easeOut(duration: 0.7), value: focus.highlighted)
            )
    }
}

extension View {
    func settingAnchor(_ id: String) -> some View {
        modifier(SettingAnchor(id: id))
    }

    /// A tab's consumption hook: when the pending anchor is one of
    /// `owned`, scroll to it (a beat after appearing, so layout is
    /// ready) and flash it.
    func consumesSettingAnchors(_ owned: Set<String>,
                                proxy: ScrollViewProxy) -> some View {
        onReceive(SettingsAnchorFocus.shared.$pending) { anchor in
            guard let anchor, owned.contains(anchor) else { return }
            SettingsAnchorFocus.shared.pending = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                withAnimation { proxy.scrollTo(anchor, anchor: .center) }
                SettingsAnchorFocus.shared.markHighlighted(anchor)
            }
        }
    }
}
