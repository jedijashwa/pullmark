import SwiftUI

struct CommitRequest: Identifiable {
    let id = UUID()
    let root: URL
}

/// File → Commit Changes…: stage-and-commit for the active file's repo,
/// without leaving the reading room. On main/master it first offers to
/// create a branch (with a per-repo "don't ask again").
struct CommitSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    let root: URL

    @State private var branch: String?
    @State private var changed: [LocalGit.ChangedFile] = []
    @State private var branchCreated = false
    @State private var selected: Set<String> = []
    @State private var message = ""
    @State private var newBranchName = ""
    @State private var useNewBranch = true
    @State private var skipMainPrompt = false
    @State private var committing = false
    @State private var error: String?
    @FocusState private var messageFocused: Bool

    private var onMainline: Bool { branch == "main" || branch == "master" }

    private var mainPromptNeeded: Bool {
        let allowed = UserDefaults.standard.stringArray(forKey: DefaultsKeys.commitToMainAllowed) ?? []
        return onMainline && !allowed.contains(root.path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Commit Changes")
                    .font(.headline)
                if let branch {
                    Label(branch, systemImage: "arrow.triangle.branch")
                        .font(.caption.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
            }
            Text(PathAbbreviator.abbreviate(root.path))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if changed.isEmpty {
                Text("No changes to commit.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                List {
                    ForEach(changed, id: \.path) { file in
                        Toggle(isOn: binding(for: file.path)) {
                            HStack {
                                Text(file.path)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Text(Self.statusLabel(file.status))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(minHeight: 90, maxHeight: 180)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))

                TextField("", text: $message,
                          prompt: Text("Commit message"), axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.roundedBorder)
                    .focused($messageFocused)

                if mainPromptNeeded {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("You're on \(branch ?? "main").", systemImage: "exclamationmark.triangle")
                            .font(.callout)
                        Picker("", selection: $useNewBranch) {
                            Text("Commit to a new branch").tag(true)
                            Text("Commit to \(branch ?? "main")").tag(false)
                        }
                        .pickerStyle(.radioGroup)
                        .labelsHidden()
                        if useNewBranch {
                            TextField("", text: $newBranchName,
                                      prompt: Text("Branch name"))
                                .textFieldStyle(.roundedBorder)
                        } else {
                            Toggle("Don't ask again for this repository", isOn: $skipMainPrompt)
                                .font(.caption)
                        }
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                }
            }

            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(commitButtonTitle) { commit() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!submittable || committing)
                ProgressView()
                    .controlSize(.small)
                    .opacity(committing ? 1 : 0)
            }
        }
        .padding(20)
        .frame(minWidth: 540)
        .onAppear(perform: load)
    }

    /// Porcelain codes in words — "??" reads like a rendering bug to
    /// anyone who doesn't live in git.
    static func statusLabel(_ code: String) -> String {
        switch code.trimmingCharacters(in: .whitespaces) {
        case "M", "MM", "AM": return "Modified"
        case "A": return "Added"
        case "D": return "Deleted"
        case "R": return "Renamed"
        case "??": return "Untracked"
        default: return "Changed"
        }
    }

    private var branchingNow: Bool {
        mainPromptNeeded && useNewBranch
    }

    private var commitButtonTitle: String {
        branchingNow ? "Create Branch & Commit" : "Commit"
    }

    private var submittable: Bool {
        guard !selected.isEmpty,
              !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if branchingNow, newBranchName.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        return true
    }

    private func binding(for path: String) -> Binding<Bool> {
        Binding(get: { selected.contains(path) },
                set: { on in if on { selected.insert(path) } else { selected.remove(path) } })
    }

    private func load() {
        let root = root
        Task.detached(priority: .userInitiated) {
            let branch = LocalGit.currentBranch(in: root)
            let changed = LocalGit.changedFiles(in: root)
            await MainActor.run {
                self.branch = branch
                self.changed = changed
                // Markdown files preselected — the ones PullMark edits.
                self.selected = Set(changed.map(\.path).filter {
                    MarkdownFileType.matches(($0 as NSString).pathExtension)
                })
                if self.selected.isEmpty { self.selected = Set(changed.map(\.path)) }
                self.messageFocused = true
            }
        }
    }

    private func commit() {
        committing = true
        error = nil
        let root = root
        // Stage everything each selected entry needs — a rename's old path
        // included, or its deletion half never lands.
        let paths = changed.filter { selected.contains($0.path) }.flatMap(\.stagePaths)
        let displayCount = selected.count
        let commitMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let branchName = branchingNow && !branchCreated
            ? newBranchName.trimmingCharacters(in: .whitespaces) : ""
        // Only a deliberate commit-to-main can waive future prompts — the
        // checkbox is meaningless (and hidden) when branching.
        let remember = skipMainPrompt && !branchingNow && mainPromptNeeded
        Task.detached(priority: .userInitiated) {
            var failure: String?
            var createdBranch = false
            if !branchName.isEmpty {
                failure = LocalGit.createBranch(branchName, in: root)
                createdBranch = failure == nil
            }
            if failure == nil {
                failure = LocalGit.commit(paths: paths, message: commitMessage, in: root)
            }
            await MainActor.run {
                committing = false
                if createdBranch {
                    // HEAD moved even if the commit then failed: reflect it
                    // so a retry commits here instead of re-running
                    // checkout -b into an "already exists" wedge.
                    self.branch = branchName
                    self.branchCreated = true
                }
                if let failure {
                    self.error = createdBranch && !branchName.isEmpty
                        ? "Now on branch “\(branchName)” — the commit itself failed: \(failure)"
                        : failure
                    return
                }
                if remember {
                    var allowed = UserDefaults.standard
                        .stringArray(forKey: DefaultsKeys.commitToMainAllowed) ?? []
                    if !allowed.contains(root.path) { allowed.append(root.path) }
                    UserDefaults.standard.set(allowed, forKey: DefaultsKeys.commitToMainAllowed)
                }
                state.lastNotice = "Committed \(displayCount) file\(displayCount == 1 ? "" : "s")"
                    + (branchName.isEmpty ? "." : " on new branch “\(branchName)”.")
                dismiss()
            }
        }
    }
}
