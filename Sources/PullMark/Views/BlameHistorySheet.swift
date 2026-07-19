import SwiftUI

/// A gutter entry was clicked; identifies the run's 1-based source line range.
struct BlameHistoryRequest: Identifiable {
    let id = UUID()
    let lineStart: Int
    let lineEnd: Int
}

/// Sheet listing the chain of commits behind a blame gutter run — true line
/// history for local files, file-level history for PR files (labeled as
/// such). Rows open the commit on GitHub when a URL is known, else copy the
/// full SHA.
struct BlameHistorySheet: View {
    @Environment(\.dismiss) private var dismiss
    let load: () async throws -> HistoryPanelData

    @State private var data: HistoryPanelData?
    @State private var error: String?
    @State private var copiedSHA: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: 480, height: 420)
        .task {
            do { data = try await load() } catch { self.error = error.localizedDescription }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(data?.title ?? "History")
                    .font(.headline)
                if let subtitle = data?.subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        if let error {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 28))
                    .foregroundStyle(.orange)
                Text(error)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let data {
            if data.entries.isEmpty {
                Text(data.note ?? "No commits found.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if let note = data.note {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .listRowSeparator(.hidden)
                    }
                    ForEach(Array(data.entries.enumerated()), id: \.element.id) { index, entry in
                        if index == data.baseStart {
                            baseDivider
                        }
                        row(entry)
                    }
                }
                .listStyle(.inset)
            }
        } else {
            ProgressView("Loading history…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Subtle labeled rule between PR-branch commits and ones already on the
    /// base branch.
    private var baseDivider: some View {
        HStack(spacing: 8) {
            Rectangle().fill(.separator).frame(height: 1)
            Text("on base branch")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
            Rectangle().fill(.separator).frame(height: 1)
        }
        .listRowSeparator(.hidden)
        .padding(.vertical, 2)
    }

    private func row(_ entry: HistoryEntry) -> some View {
        Button {
            activate(entry)
        } label: {
            HStack(spacing: 10) {
                HistoryAvatar(name: entry.author, avatarUrl: entry.avatarUrl)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(entry.author)
                            .fontWeight(.semibold)
                        if let dateLabel = entry.dateLabel {
                            Text(dateLabel)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.callout)
                    Text(entry.headline.isEmpty ? "(no commit message)" : entry.headline)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text(copiedSHA == entry.sha ? "copied" : entry.shortSHA)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(entry.url != nil ? "Open commit on GitHub" : "Copy full SHA")
    }

    private func activate(_ entry: HistoryEntry) {
        if let raw = entry.url, let url = URL(string: raw) {
            NSWorkspace.shared.open(url)
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.sha, forType: .string)
        copiedSHA = entry.sha
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if copiedSHA == entry.sha { copiedSHA = nil }
        }
    }
}

/// Avatar with the same fallback the page uses: remote image when a URL
/// resolved, else a deterministic initials circle.
private struct HistoryAvatar: View {
    let name: String
    let avatarUrl: String?

    var body: some View {
        Group {
            if let raw = avatarUrl, let url = URL(string: raw) {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    initials
                }
            } else {
                initials
            }
        }
        .frame(width: 26, height: 26)
        .clipShape(Circle())
    }

    private var initials: some View {
        // Mirrors blameInitialsEl in app.js (same hash → same hue).
        var hash: UInt32 = 0
        for scalar in name.unicodeScalars {
            hash = hash &* 31 &+ scalar.value
        }
        let parts = name.split(separator: " ")
        let text = parts.isEmpty
            ? "?"
            : String(parts[0].prefix(1)) + (parts.count > 1 ? String(parts[parts.count - 1].prefix(1)) : "")
        return ZStack {
            Circle().fill(Color(hue: Double(hash % 360) / 360, saturation: 0.45, brightness: 0.55))
            Text(text.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
        }
    }
}
