import AppKit
import SwiftUI

/// A sidebar title that turns into a text field while its entry renames
/// (spec: pinned-and-session-reopen §2). Finder's rules: Return
/// commits, Escape cancels, losing focus commits too, and an emptied
/// field clears the alias (the commit closure normalizes).
struct RenamableTitle: View {
    @EnvironmentObject private var state: AppState
    /// The `renamingEntry` key this title answers to.
    let id: String
    let title: String
    /// The entry's own name — the field's placeholder, and what an empty
    /// commit falls back to.
    let name: String
    let font: Font?
    let commit: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        if state.renamingEntry == id {
            TextField(name, text: $draft)
                .textFieldStyle(.plain)
                .font(font)
                .focused($focused)
                .onAppear {
                    draft = title
                    // The row's field exists a beat before the List lets
                    // it take focus.
                    DispatchQueue.main.async { focused = true }
                }
                .onSubmit { finish(commit: true) }
                .onExitCommand { finish(commit: false) }
                .onChange(of: focused) { isFocused in
                    if !isFocused { finish(commit: true) }
                }
                // Finder commits on any click outside the field. FocusState
                // only reports focus moving to another focusable view; a
                // click on the document, the toolbar, or empty sidebar takes
                // the field's first-responder status without flipping the
                // binding (verified live: the rename stuck until Return).
                .background(RenameBlurMonitor { finish(commit: true) })
        } else {
            Text(title)
                .lineLimit(1)
                .font(font)
        }
    }

    private func finish(commit shouldCommit: Bool) {
        guard state.renamingEntry == id else { return }
        if shouldCommit { commit(draft) }
        state.renamingEntry = nil
    }
}

/// Commits an in-progress rename on any mouse-down outside the field —
/// Finder's rule — regardless of where SwiftUI's focus goes. A local
/// monitor sees every click before dispatch; the click itself proceeds
/// untouched, so a click on a row both commits and selects.
private struct RenameBlurMonitor: NSViewRepresentable {
    let onClickOutside: () -> Void

    final class Coordinator {
        var monitor: Any?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let outside = onClickOutside
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak view] event in
            guard let view else { return event }
            var inside = false
            if let window = view.window, event.window === window {
                inside = view.bounds.contains(view.convert(event.locationInWindow, from: nil))
            }
            if !inside {
                DispatchQueue.main.async { outside() }
            }
            return event
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor {
            NSEvent.removeMonitor(monitor)
            coordinator.monitor = nil
        }
    }
}

/// Return on a selected root or pinned file starts renaming (spec §2) —
/// only while the sidebar's outline is first responder, so Return in a
/// document, a text field, or a sheet stays theirs. A local monitor,
/// like MouseNavMonitor: a plain Return is no key equivalent, so the
/// view-tree route never sees it.
struct RenameKeyMonitor: NSViewRepresentable {
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
        coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak view, weak coordinator] event in
            guard let view, let state = coordinator?.state,
                  event.window === view.window,
                  event.keyCode == 36 || event.keyCode == 76,   // Return, keypad Enter
                  event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                  view.window?.firstResponder is NSOutlineView,
                  state.renamingEntry == nil,
                  let target = Self.renameTarget(for: state)
            else { return event }
            state.renamingEntry = target
            return nil
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.state = state
    }

    /// The rename key for the selection, if it's a renamable row: a
    /// pinned root or file renames its pin, a Locations root itself.
    static func renameTarget(for state: AppState) -> String? {
        switch state.selection {
        case .folder(let root):
            return state.pins.first { $0.kind == .folder && $0.url == root }?.id ?? "root:" + root.path
        case .pinnedFile(let id):
            return id
        default:
            return nil
        }
    }
}

/// The crash-recovery offer (spec §6): a slim non-modal banner at the
/// top of the window — nothing was lost yet, so it never blocks — gone
/// once acted on, or once anything is opened.
struct RestoreOfferBanner: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        if state.restoreOffer {
            HStack(spacing: 10) {
                Image(systemName: "arrow.counterclockwise.circle")
                Text("PullMark didn't quit normally. Restore the previous session?")
                    .lineLimit(1)
                Spacer()
                Button("Not Now") { state.declineRestoreOffer() }
                Button("Restore") { state.acceptRestoreOffer() }
                    .buttonStyle(.borderedProminent)
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.orange.opacity(0.15))
        }
    }
}
