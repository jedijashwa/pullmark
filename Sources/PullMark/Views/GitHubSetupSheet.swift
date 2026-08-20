import SwiftUI

/// The GitHub access walkthrough (spec: github-connection): detects the
/// machine's actual state and shows only the step that matters —
/// install the CLI, sign in, or a connected ✓. Commands are COPIED,
/// never run: `gh auth login` is interactive, happens in the user's own
/// terminal, and PullMark never sees a password.
struct GitHubSetupSheet: View {
    @ObservedObject private var connection = GitHubClient.shared.connection
    @Environment(\.dismiss) private var dismiss
    /// Nil while the first detection runs; then whether `gh` is on PATH.
    @State private var cliInstalled: Bool?
    @State private var checking = false
    @State private var copiedCommand: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("GitHub Access")
                .font(.headline)
            Text("PullMark borrows the GitHub credentials your own tools already have — the GitHub CLI or a git credential helper. It has no login of its own, stores nothing, and never sees a password.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            stepContent

            HStack {
                Button(checking ? String(localized: "Checking…") : String(localized: "Check Again")) { check() }
                    .disabled(checking)
                    .help("Re-read credentials from the GitHub CLI and git credential helpers")
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { check() }
        .onExitCommand { dismiss() }
    }

    @ViewBuilder
    private var stepContent: some View {
        if connection.isConnected {
            connectedContent
        } else if cliInstalled == nil {
            // First detection only — later rechecks keep the last step
            // rendered (the button narrates progress) so the sheet's
            // height doesn't bounce (design-review catch).
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking this Mac's credentials…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
        } else if cliInstalled == false {
            VStack(alignment: .leading, spacing: 10) {
                Text("Set up the GitHub CLI")
                    .font(.callout.weight(.semibold))
                commandRow(number: "1", label: "Install it:", command: "brew install gh")
                commandRow(number: "2", label: "Sign in:", command: "gh auth login")
                Text("Not a Homebrew user? [Download the CLI from cli.github.com](https://cli.github.com), then sign in the same way.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                helperFootnote
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("Sign in to GitHub")
                    .font(.callout.weight(.semibold))
                Text("The GitHub CLI is installed but signed out. Run this in your terminal — it opens a browser to sign in:")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                commandRow(number: nil, label: nil, command: "gh auth login")
                helperFootnote
            }
        }
    }

    private var connectedContent: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(connectedLine)
                    .font(.callout.weight(.semibold))
                Text("Private repositories, commenting, and reviewing are ready.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }

    private var connectedLine: String {
        guard case .connected(let login, let source) = connection.status else {
            return String(localized: "Connected")
        }
        let who = login.map { "Connected as \($0)" } ?? "Connected"
        return "\(who) · \(source.label)"
    }

    private var helperFootnote: some View {
        Text("Already use a git credential helper (macOS keychain, Git Credential Manager)? PullMark finds it automatically — Check Again will confirm.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A copyable terminal command: quiet mono box + Copy, the same
    /// flash pattern as the agent-snippet buttons.
    private func commandRow(number: String?, label: String?, command: String) -> some View {
        HStack(spacing: 8) {
            if let number {
                Text(number + ".")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            if let label {
                Text(label)
                    .font(.callout)
            }
            Text(command)
                .font(.body.monospaced())
                .textSelection(.enabled)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5)
                    .fill(Color.primary.opacity(0.06)))
            Spacer()
            Button(copiedCommand == command ? "Copied" : "Copy") {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(command, forType: .string)
                copiedCommand = command
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    if copiedCommand == command { copiedCommand = nil }
                }
            }
            // Two visually identical Copy buttons per step — VoiceOver
            // needs to say which command each one takes.
            .accessibilityLabel(copiedCommand == command
                ? "Copied \(command)" : "Copy \(command)")
            .help("Copy \(command) to the clipboard")
        }
    }

    /// Detection + client recheck, both off-main; the sheet re-renders
    /// from the observed connection when they land.
    private func check() {
        checking = true
        Task {
            let installed = await Task.detached(priority: .userInitiated) {
                SystemGitCredentials.githubCLIInstalled()
            }.value
            await GitHubClient.shared.recheck()
            cliInstalled = installed
            checking = false
        }
    }
}
