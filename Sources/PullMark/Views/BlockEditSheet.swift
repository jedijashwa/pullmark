import SwiftUI

/// A block picked for local editing: 1-based inclusive source lines plus
/// the current text of that range.
struct BlockEditTarget: Identifiable {
    let id = UUID()
    let lineStart: Int
    let lineEnd: Int
    let seed: String
}

/// The local block editor — the document-side sibling of the PR
/// edit-as-suggestion composer, sharing its visual language (neutral field
/// chrome, monospaced editor, ⌘↩ to confirm). `onApply` receives the
/// edited replacement; the caller decides autosave-vs-overlay semantics.
struct BlockEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(DefaultsKeys.autosaveEdits) private var autosave = true

    let fileName: String
    let target: BlockEditTarget
    let onApply: (String) -> Void

    @State private var replacement = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit \(fileName)")
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(target.lineStart == target.lineEnd
                ? "Line \(target.lineStart)"
                : "Lines \(target.lineStart)–\(target.lineEnd)")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextEditor(text: $replacement)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                .frame(minHeight: 150, maxHeight: 340)
                .focused($focused)
            // Fixed slot (opacity, not if) so typing never jumps the layout.
            Text("Clearing all text deletes this block.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .opacity(replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 1 : 0)

            HStack {
                Text(autosave ? "Saves to \(fileName) immediately."
                              : "Saves in the window — ⌘S writes to disk.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onApply(replacement)
                    dismiss()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(replacement == target.seed)
            }
        }
        .padding(20)
        .frame(minWidth: 560)
        .onAppear {
            replacement = target.seed
            focused = true
        }
    }
}
