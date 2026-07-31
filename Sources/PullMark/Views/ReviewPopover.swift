import SwiftUI

// MARK: - Morphing review control (spec §3)

/// The one persistent review control, on every PR surface: quiet
/// "Review changes" when nothing is pending, "Finish your review · N"
/// with a badge tint when something is. It is both the status and the
/// entry point — clicking it opens the review popover.
///
/// It lives in the WINDOW-level toolbar (ContentView), not the PR
/// surface's own: SwiftUI overflows a detail view's toolbar items into
/// the "»" menu before any window-level item, at every width (verified
/// empirically), so a surface-hosted review control vanished at 1281pt
/// while the appearance menu survived — status must outlast secondary
/// controls, the way Xcode and Safari shed their toolbars. Clicking it
/// posts the same `.reviewChanges` command as the View menu and ⇧⌘R;
/// the active surface presents the popover from its root view via
/// `ReviewPopoverPresenter`, which keeps every entry point working even
/// when the toolbar does collapse this button on very narrow windows.
struct ReviewToolbarButton: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var shortcuts = ShortcutStore.shared
    let sessionID: String
    let tracker: ReviewAnchorTracker
    let action: () -> Void

    var body: some View {
        let count = state.session(sessionID)?.pendingComments.count ?? 0
        Button {
            action()
        } label: {
            // A Label, not bare Text: the toolbar's overflow menu strips
            // the capsule tint but keeps the label's image, so the icon
            // is what carries the pending state into the collapsed
            // representation (the count survives in the title text).
            // Expanded, the tint wraps icon and title together — one
            // visual unit, not a glyph floating beside a pill.
            Label {
                Text(ReviewControl.buttonLabel(pendingCount: count))
            } icon: {
                if count > 0 {
                    Image(systemName: "text.bubble.fill")
                        .foregroundStyle(.yellow)
                }
            }
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, count > 0 ? 7 : 0)
            .padding(.vertical, count > 0 ? 2 : 0)
            .background(count > 0 ? Color.yellow.opacity(0.28) : .clear,
                        in: Capsule())
        }
        // The presenter reads this view's live toolbar frame at open time
        // so the popover arrow can point at the actual button.
        .background(TrackedViewCapture { tracker.buttonView = $0 })
        .help((count == 0
                ? "Review these changes — summary, verdict, and your pending comments"
                : "Finish your review — \(count) pending comment\(count == 1 ? "" : "s")")
            + shortcuts.hint(.reviewChanges))
    }
}

/// Live AppKit handles to the review toolbar button and the surface's
/// root view. Frames are resolved on demand (window coordinates) at the
/// moment the popover presents — SwiftUI preferences can't cross the
/// NSToolbar boundary, and continuous tracking would go stale the moment
/// the toolbar relaid itself out.
final class ReviewAnchorTracker {
    weak var buttonView: NSView?
    weak var rootView: NSView?

    /// The button's horizontal center in the root view's own coordinate
    /// space, or nil while the button is overflowed/absent (collapsed
    /// into the "»" menu removes it from the window hierarchy).
    var buttonMidX: CGFloat? {
        guard let button = buttonView, let root = rootView,
              let window = button.window, window === root.window,
              !button.isHiddenOrHasHiddenAncestor else { return nil }
        let buttonFrame = button.convert(button.bounds, to: nil)
        guard buttonFrame.width > 0 else { return nil }
        let rootFrame = root.convert(root.bounds, to: nil)
        return buttonFrame.midX - rootFrame.minX
    }
}

/// Invisible, hit-transparent NSView that hands itself to the tracker so
/// window-coordinate frames can be resolved on demand. The assignment is
/// deferred out of `makeNSView` (never mutate shared state during view
/// construction).
private struct TrackedViewCapture: NSViewRepresentable {
    let assign: (NSView) -> Void

    final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> PassthroughView {
        let view = PassthroughView()
        DispatchQueue.main.async { assign(view) }
        return view
    }

    func updateNSView(_ nsView: PassthroughView, context: Context) {}
}

/// Presents the review popover from the surface's root view. The anchor
/// point sits at the toolbar button's horizontal center whenever the
/// button is actually in the window (arrow points at the button), and
/// falls back to the top-trailing corner while the toolbar has the
/// button overflowed. Root-view presentation is what keeps all three
/// entry points working while the toolbar is collapsed (see
/// `ReviewToolbarButton`).
struct ReviewPopoverPresenter: ViewModifier {
    @EnvironmentObject private var state: AppState
    let sessionID: String
    @Binding var isPresented: Bool

    private var tracker: ReviewAnchorTracker { state.reviewAnchor }

    func body(content: Content) -> some View {
        content
            .background(TrackedViewCapture { [weak state] view in
                state?.reviewAnchor.rootView = view
            })
            .overlay(alignment: .topLeading) {
                GeometryReader { geo in
                    Color.clear
                        .frame(width: 1, height: 1)
                        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                            ReviewPopover(sessionID: sessionID)
                                .environmentObject(state)
                        }
                        .position(x: anchorX(width: geo.size.width), y: 0.5)
                }
                .allowsHitTesting(false)
            }
    }

    /// Recomputed on every body pass — in particular the one that flips
    /// `isPresented`, so the anchor is fresh when presentation happens.
    private func anchorX(width: CGFloat) -> CGFloat {
        guard let midX = tracker.buttonMidX, midX > 0, midX < width else {
            return width - 0.5
        }
        return midX
    }
}

// MARK: - Review popover

/// The review surface (formerly the overview's inline section): summary,
/// the unified pending-comment list with honest sync status, the verdict
/// selection, Submit review, and Abandon review. Verdicts appear only
/// here, never in the composer (spec §3).
struct ReviewPopover: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    let sessionID: String

    /// Comment preselected every time the popover opens — never remembered
    /// from the last submit (spec §3 amendment): ⌘↩ can never approve
    /// unless Approve was deliberately chosen this time.
    @State private var verdict: ReviewVerdict = .comment
    @State private var reviewSummary = ""
    /// The last programmatically seeded summary text — anything beyond it
    /// means the user typed, and seeding must stop.
    @State private var summarySeed: String?
    @State private var summaryEdited = false
    @State private var submitting = false
    @State private var confirmAbandon = false
    /// Resolved from the client's cached identity; nil (unknown) leaves
    /// all verdicts enabled — the server 422 surfaces instead of the app
    /// blocking on a network check.
    @State private var viewerLogin: String?
    /// Chrome text follows the document zoom (damped) like the sidebar
    /// and outline panels — the pending comment bodies especially.
    @AppStorage(DefaultsKeys.zoom) private var zoom = 1.0

    private var fonts: ChromeFonts { ChromeFonts(zoom: zoom) }

    var body: some View {
        if let session = state.session(sessionID) {
            content(session)
        } else {
            EmptyView()
        }
    }

    private func content(_ session: PRSession) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(ReviewControl.headerLabel(pendingCount: session.pendingComments.count))
                .font(fonts.headline)

            if !session.pendingComments.isEmpty {
                pendingList(session)
            }

            TextField("Review summary (optional)", text: $reviewSummary, axis: .vertical)
                .font(fonts.body)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)

            syncStatusRow(session)

            verdictSection(session)

            HStack(spacing: 10) {
                if session.pendingReview != nil || !session.pendingComments.isEmpty {
                    // Quiet, link-weight — destruction lives behind the red
                    // confirmation, so the resting control needn't shout
                    // next to Submit.
                    Button("Abandon review", role: .destructive) { confirmAbandon = true }
                        .buttonStyle(.borderless)
                        .font(fonts.body)
                        .fixedSize()
                        .help("Discard the pending review and all its comments, on GitHub too")
                }
                Spacer()
                ProgressView()
                    .controlSize(.small)
                    .opacity(submitting ? 1 : 0)
                Button("Submit review") { submit() }
                    .buttonStyle(.borderedProminent)
                    // ⌘↩, not plain Return — Return belongs to the summary
                    // field. The prominence is the button's, never a
                    // verdict's: Comment is preselected on every open.
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!ReviewControl.submitEnabled(
                        verdict: verdict,
                        hasSummary: !reviewSummary
                            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        pendingCount: session.pendingComments.count))
                    .fixedSize()
                    .help("Submit the review with the selected verdict (⌘↩)")
            }
            .disabled(submitting)
        }
        .padding(16)
        .frame(width: 440)
        .task {
            seedSummary(session)
            viewerLogin = await state.client.viewerIdentity()?.login
            // Identity can resolve after an option was already chosen.
            if let current = state.session(sessionID), isOwnPR(current),
               !ReviewControl.verdictSelectable(verdict, ownPR: true) {
                verdict = .comment
            }
        }
        // Adoption can land mid-popover (60s poll): re-seed from the server
        // summary while the user hasn't typed.
        .onChange(of: session.pendingReview?.summary) { _ in
            if let session = state.session(sessionID) { seedSummary(session) }
        }
        .onChange(of: reviewSummary) { text in
            if text != (summarySeed ?? "") { summaryEdited = true }
            if let ref = state.session(sessionID)?.ref {
                PendingReviewStore.saveSummary(
                    text.trimmingCharacters(in: .whitespacesAndNewlines), ref: ref)
            }
        }
        .confirmationDialog("Abandon this review?", isPresented: $confirmAbandon) {
            // "Abandon review" — GitHub's own casing, same as the control
            // that opened this dialog; the sentence above carries context.
            Button("Abandon review", role: .destructive) {
                Task {
                    await state.abandonPendingReview(sessionID: sessionID)
                    reviewSummary = ""
                    summarySeed = nil
                    summaryEdited = false
                }
            }
        } message: {
            Text("All pending comments and the summary will be discarded, on GitHub too.")
        }
    }

    // MARK: Pending comments

    /// Each row's bottom edge in the list content's coordinate space,
    /// feeding `ReviewControl.pendingListHeight` so the visible list
    /// always ends on a whole row instead of slicing one mid-body.
    @State private var pendingRowBottoms: [CGFloat] = []
    /// The content's frame in the ScrollView's coordinate space — how the
    /// bottom fade knows whether more rows remain below the fold.
    @State private var pendingContentFrame: CGRect = .zero
    private static let pendingListCap: CGFloat = 180

    private func pendingList(_ session: PRSession) -> some View {
        let height = ReviewControl.pendingListHeight(
            rowBottoms: pendingRowBottoms, cap: Self.pendingListCap)
        // Rows exist below the fold and the user hasn't scrolled them into
        // view yet: fade the tail out so the clip reads as scrollable
        // (the sizing already leaves the next row peeking under it).
        let bottomClipped = height.map {
            pendingContentFrame.maxY > $0 + 1
        } ?? false
        // Scrolled: a symmetric top fade eases the first visible row out
        // instead of shearing it mid-glyph at the clip edge.
        let topClipped = pendingContentFrame.minY < -1
        return ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(session.pendingComments) { comment in
                    pendingRow(comment)
                        .background(GeometryReader { geo in
                            Color.clear.preference(
                                key: PendingRowBottomsKey.self,
                                value: [geo.frame(in: .named("pendingList")).maxY])
                        })
                }
            }
            .background(GeometryReader { geo in
                Color.clear.preference(
                    key: PendingContentFrameKey.self,
                    value: geo.frame(in: .named("pendingListViewport")))
            })
            .coordinateSpace(name: "pendingList")
        }
        .coordinateSpace(name: "pendingListViewport")
        // Before the first measurement lands, fall back to the old cap.
        .frame(maxHeight: height ?? Self.pendingListCap)
        .mask(
            VStack(spacing: 0) {
                if topClipped {
                    LinearGradient(colors: [.clear, .black],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 24)
                }
                Rectangle()
                if bottomClipped {
                    LinearGradient(colors: [.black, .clear],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 24)
                }
            }
        )
        .onPreferenceChange(PendingRowBottomsKey.self) {
            pendingRowBottoms = $0.sorted()
        }
        .onPreferenceChange(PendingContentFrameKey.self) {
            pendingContentFrame = $0
        }
    }

    private func pendingRow(_ comment: PendingComment) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("\(comment.path) · \(comment.lineDescription)")
                        .font(fonts.captionBold)
                        .foregroundStyle(.secondary)
                    PendingCommentTag(uploaded: comment.serverID != nil,
                                      font: fonts.caption2Bold)
                }
                Text(comment.body)
                    .font(fonts.body)
                    .lineLimit(3)
            }
            Spacer()
            Button {
                state.removePendingComment(sessionID: sessionID, id: comment.id)
            } label: {
                Image(systemName: "trash")
                    .font(fonts.body)
            }
            .buttonStyle(.borderless)
            // VoiceOver hears which comment dies, not the glyph's name.
            .accessibilityLabel("Discard comment, \(comment.path) \(comment.lineDescription)")
            .help(comment.serverID != nil
                ? "Discard this comment from the pending review on GitHub"
                : "Discard this comment")
        }
        .padding(6)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }

    /// Honest sync status: the model keeps GitHub current on its own, and
    /// this row says whether it managed to.
    @ViewBuilder
    private func syncStatusRow(_ session: PRSession) -> some View {
        if !session.queuedComments.isEmpty {
            HStack(spacing: 10) {
                Label("\(session.queuedComments.count) not yet on GitHub",
                      systemImage: "exclamationmark.icloud")
                    .font(fonts.callout)
                    .foregroundStyle(.orange)
                Button("Retry Upload") {
                    Task { await state.syncPendingComments(sessionID: sessionID) }
                }
                .fixedSize()
                .help("Upload the remaining comments into your pending review on GitHub")
            }
        } else if session.pendingReview != nil {
            Label("Pending review on GitHub", systemImage: "checkmark.icloud")
                .font(fonts.callout)
                .foregroundStyle(.secondary)
                .help("Saved as a pending review — visible only to you until you submit")
        }
    }

    // MARK: Verdict

    private func isOwnPR(_ session: PRSession) -> Bool {
        ReviewControl.isOwnPR(viewer: viewerLogin, author: session.details.user?.login)
    }

    private func verdictSection(_ session: PRSession) -> some View {
        let ownPR = isOwnPR(session)
        return VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(ReviewVerdict.allCases) { option in
                    verdictRow(option, ownPR: ownPR)
                }
            }
            // VoiceOver gets the real semantics — one radio group, "radio
            // button, 2 of 3" per row — instead of three loose buttons.
            // The binding refuses own-PR-gated verdicts, mirroring the
            // visual rows' disabled state, and the group's hint carries
            // the shared reason.
            .accessibilityRepresentation {
                Picker("Review verdict", selection: Binding(
                    get: { verdict },
                    set: { newValue in
                        if ReviewControl.verdictSelectable(newValue, ownPR: ownPR) {
                            verdict = newValue
                        }
                    })) {
                    ForEach(ReviewVerdict.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.radioGroup)
                .accessibilityHint(ownPR ? ReviewControl.ownPRRestrictionReason : "")
            }
            if ownPR {
                Text(ReviewControl.ownPRRestrictionReason)
                    .font(fonts.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    /// Radio-style row. Hand-built rather than a radioGroup Picker because
    /// individual options must disable (own-PR gating) with the rest live;
    /// the accessibilityRepresentation above restores the radio-group
    /// semantics VoiceOver expects.
    private func verdictRow(_ option: ReviewVerdict, ownPR: Bool) -> some View {
        let selectable = ReviewControl.verdictSelectable(option, ownPR: ownPR)
        return Button {
            verdict = option
        } label: {
            HStack(spacing: 7) {
                Image(systemName: verdict == option ? "circle.inset.filled" : "circle")
                    .foregroundStyle(verdict == option && selectable
                        ? AnyShapeStyle(Color.accentColor)
                        : AnyShapeStyle(.secondary))
                Text(option.label)
                    .foregroundStyle(selectable ? AnyShapeStyle(.primary)
                                                : AnyShapeStyle(.tertiary))
            }
            .font(fonts.body)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!selectable)
        .help(option.help)
    }

    // MARK: Actions

    /// Seeds the summary field while the user hasn't typed: a non-empty
    /// server summary wins (a review started or continued on github.com),
    /// else the disk-persisted draft.
    private func seedSummary(_ session: PRSession) {
        guard !summaryEdited else { return }
        let server = session.pendingReview?.summary ?? ""
        let seeded = server.isEmpty
            ? (PendingReviewStore.loadSummary(ref: session.ref) ?? "")
            : server
        guard !seeded.isEmpty, seeded != reviewSummary else { return }
        summarySeed = seeded
        reviewSummary = seeded
    }

    private func submit() {
        guard state.session(sessionID) != nil else { return }
        submitting = true
        let summary = reviewSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        let event = verdict.rawValue
        Task {
            do {
                try await state.submitReview(sessionID: sessionID, event: event,
                                             summary: summary.isEmpty ? nil : summary)
                reviewSummary = ""
                summarySeed = nil
                summaryEdited = false
                state.lastNotice = "Review submitted."
                dismiss()
            } catch {
                state.lastError = error.localizedDescription
            }
            submitting = false
        }
    }
}

/// Bottom edges of the pending-comment rows, in list-content coordinates.
private struct PendingRowBottomsKey: PreferenceKey {
    static var defaultValue: [CGFloat] = []
    static func reduce(value: inout [CGFloat], nextValue: () -> [CGFloat]) {
        value.append(contentsOf: nextValue())
    }
}

/// The pending list content's frame in the ScrollView's coordinate space.
private struct PendingContentFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

/// GitHub's "Pending" tag for comments in the viewer's pending review;
/// "Not uploaded" flags a queued comment GitHub hasn't accepted yet.
struct PendingCommentTag: View {
    let uploaded: Bool
    /// Zoom-following override from the host (ChromeFonts).
    var font: Font?

    var body: some View {
        Text(uploaded ? "Pending" : "Not uploaded")
            .font(font ?? .caption2.bold())
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background((uploaded ? Color.yellow : Color.orange).opacity(0.3),
                        in: Capsule())
    }
}
