import SwiftUI

/// The Compare menu's "Compare Revisions…" sheet: freeze both sides of
/// the diff — the file at one ref against another — or leave the new
/// side empty to keep the live working file there. The fields take
/// anything Git resolves; the in-field chevron menus fill in the knowns.
/// (SwiftUI Menu is safe here: the content is captured at sheet
/// construction and can't go stale while it's up.)
struct CompareRevisionsSheet: View {
    let commits: [LocalGit.Commit]
    let branches: [String]
    let remoteBranches: [String]
    let tags: [String]
    /// (old, new) — a nil new side means "the working file".
    let onCompare: (String, String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var oldRef = "HEAD"
    @State private var newRef = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Compare Revisions")
                .font(.headline)
            Text("Anything Git can resolve works: a branch, a tag, or a commit. Leave the new side empty to compare the working file.")
                .font(.callout)
                .foregroundStyle(.secondary)
            refRow(title: "Old side", text: $oldRef,
                   placeholder: "branch, tag, or commit")
            refRow(title: "New side", text: $newRef,
                   placeholder: "the working file")
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Compare") {
                    let old = oldRef.trimmingCharacters(in: .whitespaces)
                    let new = newRef.trimmingCharacters(in: .whitespaces)
                    dismiss()
                    onCompare(old, new.isEmpty ? nil : new)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(oldRef.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    /// A ref field with the fill-menu folded INSIDE its right edge (the
    /// combo-box idiom) — menuIndicator(.hidden) because the chevron IS
    /// the label; the default indicator would draw a second one.
    private func refRow(title: String, text: Binding<String>,
                        placeholder: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .frame(width: 66, alignment: .trailing)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .overlay(alignment: .trailing) {
                    Menu {
                        knownRefs(into: text)
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 18)
                    .padding(.trailing, 3)
                    .help("Fill in a known branch, tag, or commit")
                }
        }
    }

    @ViewBuilder
    private func knownRefs(into text: Binding<String>) -> some View {
        if !branches.isEmpty {
            Section("Branches") {
                ForEach(branches, id: \.self) { branch in
                    Button(branch) { text.wrappedValue = branch }
                }
            }
        }
        if !tags.isEmpty {
            Section("Tags") {
                ForEach(tags, id: \.self) { tag in
                    Button(tag) { text.wrappedValue = tag }
                }
            }
        }
        if !remoteBranches.isEmpty {
            Section("Remote Branches") {
                ForEach(remoteBranches, id: \.self) { branch in
                    Button(branch) { text.wrappedValue = branch }
                }
            }
        }
        if !commits.isEmpty {
            Section("History") {
                ForEach(commits) { commit in
                    // The SHORT sha: Git resolves it fine and the
                    // comparison banner stays readable.
                    Button("\(commit.shortSHA) · \(commit.subject)") {
                        text.wrappedValue = commit.shortSHA
                    }
                }
            }
        }
    }
}
