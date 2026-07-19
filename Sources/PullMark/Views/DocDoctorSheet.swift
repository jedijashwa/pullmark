import SwiftUI

struct DoctorRequest: Identifiable {
    let id = UUID()
    let root: URL
}

/// Folder-wide docs lint, rendered: broken links, missing images, dead
/// anchors, orphan pages — click an issue to open the file with the
/// offending target highlighted.
struct DocDoctorSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    let root: URL

    @State private var issues: [DocDoctor.Issue]?
    @State private var checkedCount = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "stethoscope")
                    .foregroundStyle(.secondary)
                Text("Doc Doctor")
                    .font(.headline)
                Spacer()
                Text(PathAbbreviator.abbreviate(root.path))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if let issues {
                if issues.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.seal")
                            .font(.system(size: 30))
                            .foregroundStyle(.green)
                        Text("No issues in \(checkedCount) Markdown file\(checkedCount == 1 ? "" : "s").")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 220)
                } else {
                    List {
                        ForEach(groupedFiles, id: \.self) { file in
                            Section(file) {
                                ForEach(issues.filter { $0.file == file }) { issue in
                                    Button { open(issue) } label: {
                                        HStack(spacing: 8) {
                                            Image(systemName: icon(for: issue.kind))
                                                .foregroundStyle(.orange)
                                                .frame(width: 16)
                                            Text(issue.kind.rawValue)
                                                .foregroundStyle(.secondary)
                                            Text(issue.target)
                                                .font(.body.monospaced())
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                            Spacer()
                                            if let line = issue.line {
                                                Text("line \(line)")
                                                    .font(.caption)
                                                    .foregroundStyle(.tertiary)
                                            }
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .frame(minHeight: 220, maxHeight: 380)
                    Text("\(issues.count) issue\(issues.count == 1 ? "" : "s") across "
                        + "\(groupedFiles.count) file\(groupedFiles.count == 1 ? "" : "s") — "
                        + "click one to open it with the target highlighted.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking links, anchors, and images…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 140)
            }

            HStack {
                Button("Recheck") {
                    issues = nil
                    run()
                }
                .disabled(issues == nil)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 620)
        .onAppear(perform: run)
    }

    private var groupedFiles: [String] {
        Array(Set((issues ?? []).map(\.file))).sorted()
    }

    private func icon(for kind: DocDoctor.Kind) -> String {
        switch kind {
        case .brokenLink: return "link"
        case .brokenImage: return "photo"
        case .deadAnchor: return "number"
        case .orphanPage: return "questionmark.folder"
        }
    }

    private func open(_ issue: DocDoctor.Issue) {
        let url = root.appendingPathComponent(issue.file)
        dismiss()
        state.add(url: url)
        if issue.line != nil {
            // Seed find-in-page with the target so it's highlighted.
            state.pendingSearchQuery = issue.target
        }
    }

    private func run() {
        let root = root
        Task.detached(priority: .userInitiated) {
            let skipped: Set<String> = ["node_modules", "vendor", ".build", "dist", ".git"]
            var relativePaths: [String] = []
            if let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                for case let url as URL in enumerator {
                    if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                        if skipped.contains(url.lastPathComponent) {
                            enumerator.skipDescendants()
                        }
                        continue
                    }
                    let relative = url.path.hasPrefix(root.path + "/")
                        ? String(url.path.dropFirst(root.path.count + 1))
                        : url.lastPathComponent
                    relativePaths.append(relative)
                    if relativePaths.count >= 4000 { break }
                }
            }
            let markdownCount = relativePaths.filter { $0.lowercased().hasSuffix(".md") }.count
            let found = DocDoctor.scan(files: relativePaths) { path in
                try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            }
            await MainActor.run {
                checkedCount = markdownCount
                issues = found
            }
        }
    }
}
