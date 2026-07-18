import SwiftUI

// MARK: - PR overview

struct PROverviewView: View {
    @EnvironmentObject private var state: AppState
    let sessionID: String

    @State private var reviewSummary = ""
    @State private var submitting = false
    @State private var confirmation: String?

    var body: some View {
        if let session = state.session(sessionID) {
            VStack(alignment: .leading, spacing: 0) {
                if session.updateAvailable {
                    PRUpdateBanner(sessionID: sessionID)
                }
                header(session)
                    .padding([.horizontal, .top], 20)
                    .padding(.bottom, 12)
                if !session.drafts.isEmpty {
                    draftsSection(session)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)
                }
                Divider()
                MarkdownWebView(html: HTMLBuilder.documentPage(
                    markdown: session.details.body?.isEmpty == false
                        ? session.details.body!
                        : "_No description provided._",
                    title: session.details.title
                ))
                .background(Color(nsColor: .textBackgroundColor))
            }
            .navigationTitle(String("\(session.ref.owner)/\(session.ref.repo) #\(session.ref.number)"))
        } else {
            EmptyView()
        }
    }

    private func header(_ session: PRSession) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(session.details.title)
                .font(.title2.bold())
            HStack(spacing: 8) {
                let status = PRStatus(details: session.details)
                Label(status.label, systemImage: status.systemImage)
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(status.color.opacity(0.18), in: Capsule())
                    .foregroundStyle(status.color)
                if let login = session.details.user?.login {
                    Text("opened by \(login)")
                        .foregroundStyle(.secondary)
                }
                Link("View on GitHub", destination: session.details.htmlUrl)
            }
            .font(.callout)
            Text(filesSummary(session))
                .font(.callout)
                .foregroundStyle(.secondary)
            if let confirmation {
                Label(confirmation, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            }
        }
    }

    private func draftsSection(_ session: PRSession) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(session.drafts) { draft in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(draft.path) · \(draft.lineDescription)")
                                        .font(.caption.bold())
                                        .foregroundStyle(.secondary)
                                    Text(draft.body)
                                        .lineLimit(3)
                                }
                                Spacer()
                                Button {
                                    state.removeDraft(sessionID: sessionID, draftID: draft.id)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .help("Discard this draft comment")
                            }
                            .padding(6)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
                .frame(maxHeight: 180)

                TextField("Review summary (optional)", text: $reviewSummary, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Menu("Submit Review") {
                        Button("Comment") { submit(event: "COMMENT") }
                        Button("Approve") { submit(event: "APPROVE") }
                        Button("Request Changes") { submit(event: "REQUEST_CHANGES") }
                    }
                    .fixedSize()
                    Button("Save as Pending on GitHub") { submit(event: nil) }
                        .help("Uploads the comments as a pending (draft) review you can finish on GitHub")
                    if submitting {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                }
                .disabled(submitting)
            }
            .padding(4)
        } label: {
            Label("Review draft — \(session.drafts.count) comment\(session.drafts.count == 1 ? "" : "s")",
                  systemImage: "text.bubble")
        }
    }

    private func filesSummary(_ session: PRSession) -> String {
        let md = session.markdownFiles.count
        var parts = ["\(md) Markdown file\(md == 1 ? "" : "s") changed"]
        if session.otherFileCount > 0 {
            parts.append("\(session.otherFileCount) other file\(session.otherFileCount == 1 ? "" : "s") not shown")
        }
        return parts.joined(separator: " · ")
    }

    private func submit(event: String?) {
        guard let session = state.session(sessionID) else { return }
        submitting = true
        confirmation = nil
        let summary = reviewSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                try await state.client.createReview(
                    session.ref,
                    commitID: session.details.head.sha,
                    body: summary.isEmpty ? nil : summary,
                    event: event,
                    drafts: session.drafts
                )
                state.clearDrafts(sessionID: sessionID)
                reviewSummary = ""
                confirmation = event == nil
                    ? "Saved as a pending review on GitHub."
                    : "Review submitted."
            } catch {
                state.lastError = error.localizedDescription
            }
            submitting = false
        }
    }
}

// MARK: - PR file (rendered diff)

struct PRFileView: View {
    @EnvironmentObject private var state: AppState
    let sessionID: String
    let path: String

    enum Mode: String, CaseIterable, Identifiable {
        case renderedDiff = "Rendered Diff"
        case sourceDiff = "Source Diff"
        case result = "Result"
        var id: String { rawValue }
    }

    enum DiffLayout: String, CaseIterable, Identifiable {
        case inline = "Inline"
        case split = "Side by Side"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .renderedDiff
    @AppStorage("pm.diffLayout") private var layoutRaw = DiffLayout.inline.rawValue
    @State private var baseText: String?
    @State private var headText: String?
    @State private var loading = true
    @State private var loadError: String?
    @State private var commentTarget: CommentTarget?
    @State private var outline: [OutlineItem] = []
    @StateObject private var proxy = WebViewProxy()
    @AppStorage("pm.outlinePanel") private var outlineVisible = false

    private var layout: DiffLayout { DiffLayout(rawValue: layoutRaw) ?? .inline }

    private var session: PRSession? { state.session(sessionID) }
    private var file: PullRequestFile? { session?.files.first { $0.filename == path } }

    var body: some View {
        VStack(spacing: 0) {
            if session?.updateAvailable == true {
                PRUpdateBanner(sessionID: sessionID)
            }
            if state.findBarVisible {
                FindBar(proxy: proxy)
            }
            if loading {
                ProgressView("Loading \(path)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 36))
                        .foregroundStyle(.orange)
                    Text(loadError)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 480)
                    Button("Retry") { Task { await load() } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    MarkdownWebView(
                        html: html,
                        onCommentRequest: { message in
                            commentTarget = CommentTarget(
                                lineStart: message.lineStart,
                                lineEnd: message.lineEnd,
                                side: message.side,
                                suggestionSeed: suggestionSeed(for: message)
                            )
                        },
                        remoteContext: remoteContext,
                        onOpenRemoteFile: { repoPath in
                            state.openRemoteDoc(sessionID: sessionID, path: repoPath)
                        },
                        onOutline: { outline = $0 },
                        proxy: proxy
                    )
                    .layoutPriority(1)
                    if outlineVisible {
                        OutlineSidebar(items: outline, proxy: proxy)
                    }
                }
                .background(Color(nsColor: .textBackgroundColor))
            }
        }
        .navigationTitle(path)
        .toolbar {
            ToolbarItem {
                OutlineToggle(visible: $outlineVisible)
            }
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $mode) {
                    ForEach(Mode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }
            ToolbarItem {
                if mode == .renderedDiff {
                    Picker("Layout", selection: $layoutRaw) {
                        ForEach(DiffLayout.allCases) { layout in
                            Text(layout.rawValue).tag(layout.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    .help("Inline or side-by-side rendered diff")
                }
            }
        }
        .task(id: sessionID + "|" + path + "|" + (session?.details.head.sha ?? "")) {
            await load()
        }
        .sheet(item: $commentTarget) { target in
            CommentComposer(sessionID: sessionID, path: path, target: target)
        }
    }

    private var remoteContext: RemoteResourceContext? {
        guard let session else { return nil }
        return RemoteResourceContext(ref: session.ref, commitSHA: session.details.head.sha)
    }

    /// Current content of the targeted new-file lines, used to pre-fill a
    /// ```suggestion block. Only meaningful on the new side.
    private func suggestionSeed(for message: BridgeMessage) -> String? {
        guard message.side == "RIGHT", let headText else { return nil }
        return TextLines.lines(in: headText, from: message.lineStart, to: message.lineEnd)
    }

    private var html: String {
        guard let file else { return "" }
        switch mode {
        case .result:
            let markdown = file.status == "removed"
                ? "> [!NOTE]\n> This file was deleted in the pull request."
                : (headText ?? "")
            return HTMLBuilder.documentPage(markdown: markdown, title: path,
                                            remote: HTMLBuilder.RemoteAssets(filePath: path))
        case .sourceDiff:
            return HTMLBuilder.patchPage(
                patch: file.patch ?? "No textual diff available for this file.",
                title: path
            )
        case .renderedDiff:
            let old = MarkdownBlocks.split(baseText ?? "")
            let new = MarkdownBlocks.split(headText ?? "")
            var segments = BlockDiff.diff(old: old, new: new).map { segment -> DiffSegmentPayload in
                var payload = segment.payload
                if case .modified(let oldBlock, let newBlock) = segment {
                    payload.wordDiff = WordDiff.markup(old: oldBlock.text, new: newBlock.text)
                }
                return payload
            }
            let threads = ReviewThreads.group(
                (session?.reviewComments ?? []).filter { $0.path == path }
            )
            let placed = ReviewThreads.place(threads, in: segments)
            segments = placed.segments
            let outdated = placed.outdated.map { thread in
                ThreadPayload(lineLabel: thread.lineLabel,
                              comments: thread.comments.map(CommentPayload.init))
            }
            return HTMLBuilder.diffPage(segments: segments,
                                        outdatedThreads: outdated,
                                        layout: layout == .split ? "split" : "inline",
                                        remote: HTMLBuilder.RemoteAssets(filePath: path),
                                        title: path)
        }
    }

    private func load() async {
        guard let session, let file else { return }
        loading = true
        loadError = nil
        do {
            if file.status == "added" {
                baseText = ""
            } else {
                baseText = try await state.client.fileContent(
                    session.ref,
                    path: file.previousFilename ?? path,
                    at: session.mergeBaseSHA
                )
            }
            if file.status == "removed" {
                headText = ""
            } else {
                headText = try await state.client.fileContent(
                    session.ref,
                    path: path,
                    at: session.details.head.sha
                )
            }
        } catch {
            loadError = error.localizedDescription
        }
        loading = false
    }
}

struct CommentTarget: Identifiable {
    let id = UUID()
    let lineStart: Int
    let lineEnd: Int
    let side: String
    var suggestionSeed: String?
}

// MARK: - Comment composer

struct CommentComposer: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    let sessionID: String
    let path: String
    let target: CommentTarget

    @State private var text = ""
    @State private var posting = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Comment on \(path)")
                .font(.headline)
            Text(draft.lineDescription)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 130)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.35))
                )

            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            HStack {
                if target.suggestionSeed != nil {
                    Button {
                        insertSuggestion()
                    } label: {
                        Label("Insert Suggestion", systemImage: "plus.diamond")
                    }
                    .help("Insert a ```suggestion block pre-filled with the current lines")
                }
                Text("Comments must target lines that are part of the PR diff.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add to Review") {
                    state.addDraft(sessionID: sessionID, draft)
                    dismiss()
                }
                .disabled(trimmed.isEmpty || posting)
                Button("Comment Now") { postNow() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty || posting)
                if posting {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .padding(20)
        .frame(width: 500)
    }

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// GitHub applies the suggestion in place of the commented lines, so the
    /// block starts as their current content for the user to edit.
    private func insertSuggestion() {
        guard let seed = target.suggestionSeed else { return }
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        text += "```suggestion\n\(seed)\n```\n"
    }

    private var draft: DraftComment {
        DraftComment(path: path, lineStart: target.lineStart, lineEnd: target.lineEnd,
                     side: target.side, body: trimmed)
    }

    private func postNow() {
        guard let session = state.session(sessionID) else { return }
        posting = true
        error = nil
        Task {
            do {
                try await state.client.createComment(
                    session.ref,
                    commitID: session.details.head.sha,
                    comment: draft
                )
                await state.reloadComments(sessionID: sessionID)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            posting = false
        }
    }
}

// MARK: - Browsed repo document

/// A repo Markdown file opened via a link from PR content, rendered at the
/// PR's head commit.
struct PRDocView: View {
    @EnvironmentObject private var state: AppState
    let sessionID: String
    let path: String

    @State private var html = ""
    @State private var loading = true
    @State private var loadError: String?
    @State private var outline: [OutlineItem] = []
    @StateObject private var proxy = WebViewProxy()
    @AppStorage("pm.outlinePanel") private var outlineVisible = false

    private var session: PRSession? { state.session(sessionID) }

    var body: some View {
        VStack(spacing: 0) {
            if state.findBarVisible {
                FindBar(proxy: proxy)
            }
            if loading {
                ProgressView("Loading \(path)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 36))
                        .foregroundStyle(.orange)
                    Text(loadError)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 480)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    MarkdownWebView(
                        html: html,
                        remoteContext: session.map {
                            RemoteResourceContext(ref: $0.ref, commitSHA: $0.details.head.sha)
                        },
                        onOpenRemoteFile: { repoPath in
                            state.openRemoteDoc(sessionID: sessionID, path: repoPath)
                        },
                        onOutline: { outline = $0 },
                        proxy: proxy
                    )
                    .layoutPriority(1)
                    if outlineVisible {
                        OutlineSidebar(items: outline, proxy: proxy)
                    }
                }
                .background(Color(nsColor: .textBackgroundColor))
            }
        }
        .navigationTitle(path)
        .toolbar {
            ToolbarItem {
                OutlineToggle(visible: $outlineVisible)
            }
        }
        .task(id: sessionID + "|" + path + "|" + (session?.details.head.sha ?? "")) {
            await load()
        }
    }

    private func load() async {
        guard let session else { return }
        loading = true
        loadError = nil
        do {
            let markdown = try await state.client.fileContent(session.ref, path: path,
                                                              at: session.details.head.sha)
            html = HTMLBuilder.documentPage(markdown: markdown, title: path,
                                            remote: HTMLBuilder.RemoteAssets(filePath: path))
        } catch {
            loadError = error.localizedDescription
        }
        loading = false
    }
}

// MARK: - Add PR sheet

struct AddPRSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var input = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Open Pull Request")
                .font(.headline)
            TextField("https://github.com/owner/repo/pull/123 or owner/repo#123", text: $input)
                .textFieldStyle(.roundedBorder)
                .frame(width: 420)
                .onSubmit { add() }
            Text("Works with private repos using your existing gh or git credentials.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: 420, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Open") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || input.trimmingCharacters(in: .whitespaces).isEmpty)
                if busy {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .padding(20)
    }

    private func add() {
        busy = true
        error = nil
        Task {
            do {
                try await state.addPR(input)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}
