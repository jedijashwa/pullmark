import SwiftUI
import AppKit

/// The paired back/forward toolbar buttons (spec: back-forward-navigation
/// §5). AppKit-backed because one control answers three gestures — click
/// navigates, press-and-hold (Safari's ~0.35 s) or right-click pops the
/// trail as a menu — and the menu must be built fresh at pop time
/// (MenuAnchorBox's lesson: SwiftUI toolbar Menus cache stale rows).
struct NavHistoryControl: View {
    @ObservedObject var state: AppState
    @ObservedObject private var shortcuts = ShortcutStore.shared

    var body: some View {
        HStack(spacing: 2) {
            NavHistoryButton(
                state: state, direction: -1,
                symbol: "chevron.backward", label: "Back",
                enabled: state.canGoBack,
                help: "Show the previous document\(shortcuts.hint(.goBack))"
                    + " — click and hold to see history")
            NavHistoryButton(
                state: state, direction: 1,
                symbol: "chevron.forward", label: "Forward",
                enabled: state.canGoForward,
                help: "Show the next document\(shortcuts.hint(.goForward))"
                    + " — click and hold to see history")
        }
    }
}

/// One direction's button. `direction` is the travel sign: a click moves
/// one step, menu row N moves N+1 steps.
private struct NavHistoryButton: NSViewRepresentable {
    let state: AppState
    let direction: Int
    let symbol: String
    let label: String
    let enabled: Bool
    let help: String

    final class Coordinator {
        // NSMenuItem targets are weak — the presenter must outlive every
        // menu this button ever pops.
        let presenter = MenuActionPresenter()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> HoldMenuNavButton {
        let button = HoldMenuNavButton()
        button.bezelStyle = .texturedRounded
        // The AppKit toolbar idiom Safari's own nav buttons use: bordered,
        // but the bezel appears only under the pointer.
        button.showsBorderOnlyWhileMouseInside = true
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(textStyle: .body, scale: .large))
        button.imagePosition = .imageOnly
        button.setAccessibilityLabel(label)
        configure(button, coordinator: context.coordinator)
        return button
    }

    func updateNSView(_ button: HoldMenuNavButton, context: Context) {
        configure(button, coordinator: context.coordinator)
    }

    private func configure(_ button: HoldMenuNavButton, coordinator: Coordinator) {
        let state = state
        let direction = direction
        button.isEnabled = enabled
        button.toolTip = help
        button.clickAction = { state.travelHistory(direction) }
        button.menuBuilder = { [weak coordinator] in
            guard let coordinator else { return nil }
            return Self.historyMenu(state: state, direction: direction,
                                    presenter: coordinator.presenter)
        }
    }

    /// The trail on this button's side, nearest first, built from live
    /// state at pop time. Dead entries are listed like any other — the
    /// menu is how "what was that doc" gets answered — and choosing one
    /// lands on the unavailable view (spec §4.1).
    static func historyMenu(state: AppState, direction: Int,
                            presenter: MenuActionPresenter) -> NSMenu? {
        let entries = direction < 0 ? state.navHistory.backEntries
                                    : state.navHistory.forwardEntries
        guard !entries.isEmpty else { return nil }
        let menu = NSMenu()
        presenter.actions = []
        for (index, entry) in entries.prefix(20).enumerated() {
            let item = NSMenuItem(title: middleTruncated(entry.title),
                                  action: #selector(MenuActionPresenter.fire(_:)),
                                  keyEquivalent: "")
            item.target = presenter
            item.tag = index
            item.image = NSImage(systemSymbolName: entry.systemImage,
                                 accessibilityDescription: nil)
            presenter.actions.append { state.travelHistory(direction * (index + 1)) }
            menu.addItem(item)
        }
        return menu
    }

    /// Menu rows shouldn't stretch the menu to a pathological width —
    /// middle-truncate the rare long title (spec §12).
    static func middleTruncated(_ title: String, limit: Int = 60) -> String {
        guard title.count > limit else { return title }
        let half = (limit - 1) / 2
        return title.prefix(half) + "…" + title.suffix(half)
    }
}

/// Buttons 4/5 on multi-button mice go back/forward (spec §7), scoped
/// to this view's window — every browser's mapping. A local monitor
/// sees the event first; handled presses are consumed, everything else
/// (including the buttons when their side of the trail is empty)
/// passes through untouched.
struct MouseNavMonitor: NSViewRepresentable {
    let state: AppState

    final class Coordinator {
        var monitor: Any?
        var state: AppState?
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let coordinator = context.coordinator
        coordinator.state = state
        coordinator.monitor = NSEvent.addLocalMonitorForEvents(
            matching: .otherMouseUp
        ) { [weak view, weak coordinator] event in
            guard let view, let state = coordinator?.state,
                  event.window === view.window else { return event }
            switch event.buttonNumber {
            case 3 where state.canGoBack:
                state.goBack()
                return nil
            case 4 where state.canGoForward:
                state.goForward()
                return nil
            default:
                return event
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.state = state
    }
}

/// An NSButton that distinguishes click from press-and-hold, and pops
/// its history menu for both hold and right-click. Runs its own event
/// tracking: `nextEvent(matching:until:…)` with a 0.35 s deadline —
/// a timer wouldn't fire inside NSButton's native tracking loop.
final class HoldMenuNavButton: NSButton {
    var clickAction: () -> Void = {}
    var menuBuilder: () -> NSMenu? = { nil }

    // The custom mouseDown below never reaches NSButton's action
    // machinery, but accessibility's AXPress does (performClick) — an
    // unwired button is invisible to VoiceOver and the drive scripts.
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        target = self
        action = #selector(fireClick)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    @objc private func fireClick() { clickAction() }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        highlight(true)
        defer { highlight(false) }
        let deadline = Date(timeIntervalSinceNow: 0.35)
        while true {
            guard let next = window?.nextEvent(
                matching: [.leftMouseUp, .leftMouseDragged],
                until: deadline, inMode: .eventTracking, dequeue: true) else {
                // Held past the threshold: the press becomes the menu.
                popHistoryMenu()
                return
            }
            if next.type == .leftMouseUp {
                if bounds.contains(convert(next.locationInWindow, from: nil)) {
                    clickAction()
                }
                return
            }
            // Drags stay in the loop — slipping off the button just
            // cancels on release outside, like any button.
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        popHistoryMenu()
    }

    private func popHistoryMenu() {
        guard let menu = menuBuilder(), !menu.items.isEmpty else { return }
        // Below the button's bottom edge (this view is in a flipped
        // hierarchy), so a press-and-hold release over the button lands
        // outside the menu and leaves it open — the browser feel.
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 6), in: self)
    }
}
