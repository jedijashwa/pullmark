import SwiftUI
import AppKit

/// Settings → Keyboard: every keyboard action in the app, grouped by the
/// menu it lives in, each rebindable. Select a row and press Return (or
/// click its shortcut) to record; Esc cancels, ⌫ removes the binding.
/// Fully operable from the keyboard — this pane above all others.
struct KeyboardSettingsTab: View {
    @ObservedObject private var shortcuts = ShortcutStore.shared
    /// The action currently listening for a key press, if any.
    @State private var recording: ShortcutAction?
    @State private var refusal: ShortcutStore.Refusal?
    /// Modifiers held right now, echoed live so the recorder feels awake.
    @State private var liveModifiers: KeyCombo?
    @State private var confirmingReset = false
    @State private var keyMonitor: Any?
    @State private var flagsMonitor: Any?
    @FocusState private var focusedRow: ShortcutAction?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    // Spelled out, not glyphs: ⌫ and ⎋ are unrecognizable
                    // to plenty of people in running prose.
                    Text("Click a shortcut, or select a row and press Return, then type "
                        + "the new keys. Press Delete to remove a shortcut, Esc to cancel.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(ShortcutAction.categories, id: \.self) { category in
                    Section(category) {
                        ForEach(actions(in: category), id: \.self) { action in
                            row(for: action)
                        }
                    }
                }
                Section {
                    ForEach(Self.builtIns, id: \.label) { entry in
                        LabeledContent(entry.label) {
                            Text(entry.keys)
                                .font(.body.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Built-In Keys")
                } footer: {
                    Text("These keys are fixed and can't be changed.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .formStyle(.grouped)

            HStack {
                Text(recording == nil
                     ? "\(ShortcutAction.allCases.count) actions"
                     : "Recording — press the new shortcut.")
                    .font(.callout)
                    .foregroundStyle(recording == nil ? .secondary : .primary)
                Spacer()
                Button("Restore Defaults…") { confirmingReset = true }
                    .disabled(!shortcuts.anyCustomized)
            }
            .padding(12)
            .background(.bar)
        }
        .frame(height: 560)
        .onDisappear { stopRecording() }
        // A local monitor swallows every key in the process — never leave
        // one armed once this pane stops being the user's focus.
        .onReceive(NotificationCenter.default.publisher(
            for: NSWindow.didResignKeyNotification)) { _ in stopRecording() }
        .confirmationDialog("Restore all keyboard shortcuts to their defaults?",
                            isPresented: $confirmingReset) {
            Button("Restore Defaults", role: .destructive) {
                stopRecording()
                shortcuts.resetAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your custom shortcuts will be removed. This can't be undone.")
        }
    }

    /// Return/Space records and ⌫ clears on a focused row. `onKeyPress`
    /// arrived in macOS 14; on 13 the row's own button still takes Space
    /// once focus reaches it.
    private struct RowKeys: ViewModifier {
        let onRecord: () -> Void
        let onClear: () -> Void

        func body(content: Content) -> some View {
            if #available(macOS 14.0, *) {
                content
                    .onKeyPress(.return) { onRecord(); return .handled }
                    .onKeyPress(.space) { onRecord(); return .handled }
                    .onKeyPress(.delete) { onClear(); return .handled }
            } else {
                content
            }
        }
    }

    private static let builtIns: [(label: String, keys: String)] = [
        ("Edit mode: move between blocks", "↑ ↓"),
        ("Edit mode: merge with previous block", "⌫"),
        ("Edit mode: discard this block's edits", "⎋"),
        ("Palettes: move through results", "↑ ↓"),
        ("Palettes: open the selection", "↩"),
        ("Sheets and palettes: dismiss", "⎋"),
        ("Commit sheet: commit", "⌘↩"),
    ]

    private func actions(in category: String) -> [ShortcutAction] {
        ShortcutAction.allCases.filter { $0.category == category }
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(for action: ShortcutAction) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            LabeledContent(action.title) { recorder(for: action) }
            if recording == action, let refusal {
                refusalNotice(refusal, for: action)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { startRecording(action) }
        // Rows, not the buttons inside them, are the focus unit: buttons
        // only join the tab loop when Full Keyboard Access is on.
        .focusable()
        .focused($focusedRow, equals: action)
        .modifier(RowKeys(onRecord: { startRecording(action) },
                          onClear: { shortcuts.assign(nil, to: action) }))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(action.title) shortcut")
        .accessibilityValue(shortcuts.combo(for: action)?.spoken ?? "None")
        .accessibilityHint("Press Return, then type the new key combination. "
            + "Delete removes it, Escape cancels.")
    }

    private func recorder(for action: ShortcutAction) -> some View {
        HStack(spacing: 6) {
            Button { startRecording(action) } label: {
                comboLabel(for: action)
                    .frame(width: 104)
            }
            .buttonStyle(.bordered)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(-2)
                    .opacity(recording == action ? 1 : 0))
            .help(recording == action
                ? "Recording — press the new shortcut"
                : "Click, then press the new shortcut")
            .accessibilityHidden(true) // the row carries the label

            // Always present so the shortcut column stays flush; only
            // interactive once the row differs from its default.
            Button {
                stopRecording()
                shortcuts.reset(action)
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.borderless)
            .frame(width: 16)
            .opacity(shortcuts.isCustomized(action) ? 1 : 0)
            .allowsHitTesting(shortcuts.isCustomized(action))
            .accessibilityHidden(!shortcuts.isCustomized(action))
            .accessibilityLabel("Restore the default shortcut for \(action.title)")
            .help("Restore the default"
                + (action.defaultCombo.map { " (\($0.display))" } ?? " (none)"))
        }
    }

    @ViewBuilder
    private func comboLabel(for action: ShortcutAction) -> some View {
        if recording == action {
            // Echo modifiers as they go down: without this the control sits
            // inert while the user holds ⌃⌥⇧ and looks broken.
            Text(liveModifiers.map { $0.display + "…" } ?? "Press keys…")
                .font(.body.monospaced())
                .foregroundStyle(.secondary)
        } else if let combo = shortcuts.combo(for: action) {
            Text(combo.display)
                .font(.body.monospaced())
        } else {
            Text("None")
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func refusalNotice(_ refusal: ShortcutStore.Refusal,
                               for action: ShortcutAction) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(refusal.message)
                .fixedSize(horizontal: false, vertical: true)
            if case .taken(let combo, _) = refusal {
                Button("Use Anyway") {
                    shortcuts.assign(combo, to: action, stealing: true)
                    stopRecording()
                }
                .controlSize(.small)
            }
        }
        .font(.callout)
    }

    // MARK: - Recording

    private func startRecording(_ action: ShortcutAction) {
        stopRecording()
        recording = action
        focusedRow = action
        refusal = nil
        liveModifiers = nil
        let window = NSApp.keyWindow
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Only capture keys aimed at the Settings window this recording
            // started in — otherwise an armed row eats the whole app's keys.
            guard event.window === window else { return event }
            handleKeyDown(event, for: action)
            return nil
        }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            guard event.window === window else { return event }
            let flags = event.modifierFlags
            let held = KeyCombo(key: "",
                                command: flags.contains(.command),
                                shift: flags.contains(.shift),
                                option: flags.contains(.option),
                                control: flags.contains(.control))
            let any = held.command || held.shift || held.option || held.control
            liveModifiers = any ? held : nil
            return event
        }
        announce("Recording. Press the new shortcut.")
    }

    private func handleKeyDown(_ event: NSEvent, for action: ShortcutAction) {
        guard let combo = ShortcutStore.combo(from: event) else { return }
        let bare = !combo.command && !combo.control && !combo.option && !combo.shift
        if bare && combo.key == "escape" {
            stopRecording()
            return
        }
        if bare && (combo.key == "delete" || combo.key == "forwarddelete") {
            shortcuts.assign(nil, to: action)
            stopRecording()
            announce("\(action.title) shortcut removed.")
            return
        }
        if let refused = shortcuts.assign(combo, to: action) {
            refusal = refused // stay armed so they can just try again
            liveModifiers = nil
            NSSound.beep()
            announce(refused.message)
        } else {
            stopRecording()
            announce("\(action.title) set to \(combo.spoken).")
        }
    }

    private func stopRecording() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        keyMonitor = nil
        flagsMonitor = nil
        recording = nil
        refusal = nil
        liveModifiers = nil
    }

    private func announce(_ message: String) {
        guard let window = NSApp.keyWindow else { return }
        NSAccessibility.post(element: window, notification: .announcementRequested,
                             userInfo: [.announcement: message,
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}
