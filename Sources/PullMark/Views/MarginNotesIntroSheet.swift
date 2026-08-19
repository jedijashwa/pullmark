import SwiftUI

/// What the user reached for when the intro interposed — Keep Using
/// resumes exactly this, no second click.
struct MarginNoteIntroRequest: Identifiable {
    enum Kind {
        /// Menu / toolbar / ⌥⌘M — re-driven through the proxy.
        case native(fileLevel: Bool)
        /// In-page affordance — the page holds the stashed action.
        case page
    }
    let kind: Kind
    let id = UUID()
}

/// The one-time margin-notes intro (spec: margin-notes-graduation),
/// shown the first time a write action reaches for the feature — never
/// on passive viewing. A sheet rather than an alert: it carries a docs
/// link and a copy control. Esc is "not now" — nothing happens and the
/// next write action asks again; the two buttons are the real choice.
struct MarginNotesIntroSheet: View {
    let onTurnOff: () -> Void
    let onKeepUsing: () -> Void
    let onNotNow: () -> Void
    @State private var copiedSnippet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text("Margin Notes")
                    .font(.headline)
                ExperimentalBadge(level: .beta)
            }
            Text("Comment on any local Markdown document the way you'd comment on a PR. Notes save into the file itself as `<!-- note @you: … -->` comments — invisible to every other tool, rendered by PullMark as bubbles pinned to their spot. Deleting a note is how it's resolved.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Text("Margin notes are experimental (beta): the design may still shift between versions, and Settings → Experimental turns them off any time. [How margin notes work](https://pullmark.app/docs/experimental/margin-notes/)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Tell your agent")
                        .font(.callout.weight(.semibold))
                    Spacer()
                    Button(copiedSnippet ? "Copied" : "Copy") {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(MarginNotes.agentInstructions,
                                             forType: .string)
                        copiedSnippet = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            copiedSnippet = false
                        }
                    }
                    .help("Copies instructions for CLAUDE.md / AGENTS.md — how to "
                        + "read margin notes and delete them as they're addressed")
                }
                Text("Notes are written so agents can read and act on them. Paste the snippet into your agent's instructions file (CLAUDE.md, AGENTS.md, …) and \"address the margin notes in this file\" becomes a complete handoff.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.05)))

            HStack {
                Spacer()
                Button("Turn Off") { onTurnOff() }
                Button("Keep Using") { onKeepUsing() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onExitCommand { onNotNow() }
    }
}
