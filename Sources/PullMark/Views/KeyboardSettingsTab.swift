import SwiftUI
import AppKit

/// Settings → Keyboard: every keyboard action in the app, grouped by menu
/// area, each rebindable. Click a shortcut, press the new keys; Esc cancels,
/// Delete removes the binding. Defaults restore per-row or all at once.
struct KeyboardSettingsTab: View {
    @ObservedObject private var shortcuts = ShortcutStore.shared
    /// The action currently listening for a key press, if any.
    @State private var recording: ShortcutAction?
    @State private var message: String?
    @State private var eventMonitor: Any?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                ForEach(ShortcutAction.categories, id: \.self) { category in
                    Section(category) {
                        ForEach(actions(in: category), id: \.self) { action in
                            row(for: action)
                        }
                    }
                }
                Section("Built In") {
                    fixedRow("Inside edit mode", "↓ ↑ walk blocks · ⌫ merges · Esc reverts")
                    fixedRow("In palettes and find", "↓ ↑ select · ↩ open · Esc dismiss")
                    fixedRow("Commit sheet", "⌘↩ commits · Esc cancels")
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if let message {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                } else if recording != nil {
                    Text("Press the new shortcut — Esc cancels, ⌫ removes the binding.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Click a shortcut to change it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Restore Defaults") {
                    stopRecording()
                    shortcuts.resetAll()
                    message = nil
                }
                .disabled(!shortcuts.anyCustomized)
            }
            .padding(12)
        }
        .frame(height: 560)
        .onDisappear { stopRecording() }
    }

    private func actions(in category: String) -> [ShortcutAction] {
        ShortcutAction.allCases.filter { $0.category == category }
    }

    private func row(for action: ShortcutAction) -> some View {
        LabeledContent(action.title) {
            HStack(spacing: 6) {
                if shortcuts.isCustomized(action) {
                    Button {
                        stopRecording()
                        shortcuts.reset(action)
                        message = nil
                    } label: {
                        Image(systemName: "arrow.uturn.backward.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Restore the default"
                        + (action.defaultCombo.map { " (\($0.display))" } ?? " (none)"))
                }
                Button {
                    recording == action ? stopRecording() : startRecording(action)
                } label: {
                    Text(recording == action ? "Press keys…"
                        : shortcuts.combo(for: action)?.display ?? "—")
                        .font(.body.monospaced())
                        .frame(minWidth: 76)
                }
                .buttonStyle(.bordered)
                .tint(recording == action ? .accentColor : nil)
                .help(recording == action
                    ? "Recording — press the new shortcut"
                    : "Click, then press the new shortcut")
            }
        }
    }

    private func fixedRow(_ title: String, _ keys: String) -> some View {
        LabeledContent(title) {
            Text(keys)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func startRecording(_ action: ShortcutAction) {
        stopRecording()
        recording = action
        message = nil
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleKeyDown(event, for: action)
            return nil // swallow it — nothing else may react while recording
        }
    }

    private func handleKeyDown(_ event: NSEvent, for action: ShortcutAction) {
        guard let combo = ShortcutStore.combo(from: event) else { return }
        let bare = !combo.command && !combo.control && !combo.option && !combo.shift
        if bare && combo.key == "escape" {
            stopRecording()
            return
        }
        if bare && (combo.key == "delete" || combo.key == "forwarddelete") {
            stopRecording()
            shortcuts.assign(nil, to: action)
            return
        }
        if let refusal = shortcuts.assign(combo, to: action) {
            message = refusal // keep recording so they can try again
        } else {
            stopRecording()
        }
    }

    private func stopRecording() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        eventMonitor = nil
        recording = nil
    }
}
