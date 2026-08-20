import SwiftUI
import AppKit

/// The whole window's toolbar, customizable via the native right-click →
/// Customize Toolbar… palette. Every item lives here — window-level
/// actions and the active surface's controls alike — because SwiftUI only
/// persists toolbar customization for window-level `.toolbar(id:)`
/// content: detail-hosted customizable items are re-merged fresh at every
/// launch, resurrecting whatever the user removed, and a single unnamed
/// `.toolbar {}` item anywhere in the window disables customization for
/// the whole toolbar (both verified live on this OS).
///
/// STRUCTURE (which items exist) follows `kind`, derived from the model
/// (AppState.surfaceExpectation) — never from view-lifecycle
/// registration, which SwiftUI's remounting makes unreliable. The
/// registered `surface` supplies only VALUES and callbacks, may briefly
/// be nil while a fresh surface's registration lands, and every item
/// renders a safe disabled default in that gap.
///
/// Item IDs carry a surface prefix ("local-blame", "pr-blame") so each
/// surface keeps its own arrangement and the palette only ever offers the
/// items that exist where the user opened it. Items new to the pool ship
/// `showsByDefault: false`: out of the box the toolbar looks exactly as
/// it always has, and the palette holds the rest.
///
/// Declaration order is also collapse priority: when the window narrows,
/// SwiftUI moves LATER-declared items into the "»" overflow menu first
/// (verified empirically). Navigation is wayfinding and must survive the
/// squeeze, so it leads its surface; each surface's tail is sacrificial —
/// the same order Xcode and Safari shed secondary items.
struct AppToolbar: CustomizableToolbarContent {
    let state: AppState
    let kind: SurfaceToolbar.Kind?
    let surface: SurfaceToolbar?
    let reviewSessionID: String?
    let marginNotesEnabled: Bool
    @Binding var appearanceRaw: String

    var body: some CustomizableToolbarContent {
        // First of all: back/forward is wayfinding and outlives every
        // squeeze (declaration order is collapse priority — later dies
        // first). Also the deliberate exception to "new items ship
        // hidden": the buttons ARE the feature
        // (spec: back-forward-navigation §5).
        ToolbarItem(id: "nav-history", placement: .navigation) {
            NavHistoryControl(state: state)
        }
        // Known Tahoe cosmetic: the glass grouping fuses this pair with
        // the PR surface's navigation cluster into one capsule. Both
        // split attempts failed live — ToolbarSpacer typechecks as
        // customizable content but is silently dropped from
        // `.toolbar(id:)` toolbars, and an empty gap item's width
        // pushes the whole PR cluster into overflow at the default
        // window size. Revisit if the toolbar ever gets more room.
        // Declared before the rest: review status must survive the
        // squeeze that rightly claims surface items and the open buttons
        // (spec §3). Placement still renders it in the trailing cluster.
        if let reviewSessionID {
            ToolbarItem(id: "review", placement: .primaryAction) {
                ReviewToolbarButton(sessionID: reviewSessionID,
                                    tracker: state.reviewAnchor) {
                    state.send(.reviewChanges)
                }
            }
        }
        if let kind {
            switch kind {
            case .localFile:
                LocalFileToolbarItems(state: state, surface: surface,
                                      marginNotesEnabled: marginNotesEnabled)
            case .remoteDoc:
                RemoteDocToolbarItems(state: state, surface: surface)
            case .prFile:
                PRFileToolbarItems(state: state, surface: surface)
            case .prDoc:
                PRDocToolbarItems(state: state)
            case .prOverview:
                PROverviewToolbarItems(state: state, surface: surface)
            }
        }
        windowItems
    }

    /// The window-level cluster, present on every surface — the
    /// sacrificial tail of the collapse order (SwiftUI ignores
    /// NSToolbarItem.visibilityPriority for its own "»" overflow,
    /// verified live; declaration order is the only knob, and the review
    /// control is declared first in `body` for the same reason).
    @ToolbarContentBuilder
    private var windowItems: some CustomizableToolbarContent {
        ToolbarItem(id: "open-file", placement: .primaryAction) {
            OpenFileToolbarButton(state: state)
        }
        ToolbarItem(id: "open-pr", placement: .primaryAction) {
            OpenPRToolbarButton(state: state)
        }
        ToolbarItem(id: "appearance", placement: .primaryAction) {
            Menu {
                Picker("Appearance", selection: $appearanceRaw) {
                    ForEach(Appearance.allCases) { appearance in
                        Text(appearance.label).tag(appearance.rawValue)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Appearance", systemImage: "circle.lefthalf.filled")
            }
            .help("Switch between light, dark, and system appearance")
        }
    }
}

/// Refuses customize-palette drops into the toolbar's SIDEBAR section —
/// left of the split-view tracking separator, territory SwiftUI manages
/// for the sidebar toggle and mangles when a foreign item lands there
/// (see ToolbarArrangement). AppKit consults the toolbar DELEGATE for
/// every candidate drop index (`toolbar(_:itemIdentifier:canBeInsertedAt:)`,
/// macOS 13+) and animates the native refusal itself, so the fix is a
/// forwarding proxy wrapped around SwiftUI's own delegate: every message
/// passes through untouched except the drop question, which additionally
/// applies our section rule. AppKit then places refused drops at the
/// nearest allowed index — "the drop worked, adjusted", never a mangle.
final class ToolbarDropVeto: NSObject, NSToolbarDelegate {
    let original: AnyObject

    init(wrapping original: AnyObject) {
        self.original = original
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || original.responds(to: aSelector)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        original.responds(to: aSelector) ? original : super.forwardingTarget(for: aSelector)
    }

    func toolbar(_ toolbar: NSToolbar, itemIdentifier: NSToolbarItem.Identifier,
                 canBeInsertedAt index: Int) -> Bool {
        if !ToolbarArrangement.isSystemItem(itemIdentifier.rawValue),
           let separator = toolbar.items.firstIndex(where: {
               ToolbarArrangement.isSeparator($0.itemIdentifier.rawValue)
           }),
           index <= separator {
            return false
        }
        // Defer to SwiftUI's own answer when it cares too.
        if let originalDelegate = original as? NSToolbarDelegate,
           originalDelegate.responds(to: #selector(NSToolbarDelegate.toolbar(_:itemIdentifier:canBeInsertedAt:))) {
            return originalDelegate.toolbar?(toolbar, itemIdentifier: itemIdentifier,
                                             canBeInsertedAt: index) ?? true
        }
        return true
    }
}

/// Backstop for sidebar-section corruption (see ToolbarArrangement for
/// the full story): installs the drop veto on every toolbar the window
/// gets (surface switches swap NSToolbar identities), and — should a bad
/// arrangement exist anyway (saved by an older build, or any path the
/// veto misses) — scrubs the SAVED configuration and re-applies it
/// wholesale through the same restore path SwiftUI handles at launch.
/// Item-by-item NSToolbar surgery loses to SwiftUI's own model; the
/// config layer is where repairs stick. Polling is deliberate: a palette
/// MOVE emits no NSToolbar notifications (verified live), and the
/// clean-state fast path is one string-array compare. Lives on the
/// window content (ContentView), outside any toolbar item.
struct ToolbarSectionEnforcer: NSViewRepresentable {
    final class Coordinator {
        var observers: [NSObjectProtocol] = []
        var enforcementScheduled = false
        var poll: Timer?
        /// Every veto ever installed — NSToolbar.delegate is weak, and a
        /// surface switch may reattach a previously-seen toolbar whose
        /// proxy must still be alive.
        var vetoes: [ToolbarDropVeto] = []
        deinit {
            observers.forEach(NotificationCenter.default.removeObserver(_:))
            poll?.invalidate()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let coordinator = context.coordinator
        // AppKit's pair is WILL-add / DID-remove; a palette drop fires both.
        for name in [NSToolbar.willAddItemNotification,
                     NSToolbar.didRemoveItemNotification] {
            coordinator.observers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak view, weak coordinator] note in
                guard let view, let coordinator,
                      let toolbar = view.window?.toolbar,
                      (note.object as? NSToolbar) === toolbar,
                      !coordinator.enforcementScheduled else { return }
                coordinator.enforcementScheduled = true
                // Coalesce the burst a drop produces, and never mutate
                // from inside the notification.
                DispatchQueue.main.async {
                    coordinator.enforcementScheduled = false
                    Self.repairIfNeeded(view.window?.toolbar)
                }
            })
        }
        // Bulk restores (surface-identity switches) emit no per-item
        // notifications, and neither does a customize-palette MOVE within
        // the toolbar (verified live) — a slow poll is the only reliable
        // net. The clean-state fast path is one string-array compare.
        coordinator.poll = Timer.scheduledTimer(withTimeInterval: 1.5,
                                                repeats: true) { [weak view, weak coordinator] _ in
            Self.installVeto(on: view?.window?.toolbar, coordinator: coordinator)
            Self.repairIfNeeded(view?.window?.toolbar)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator
        DispatchQueue.main.async { [weak nsView, weak coordinator] in
            Self.installVeto(on: nsView?.window?.toolbar, coordinator: coordinator)
            Self.repairIfNeeded(nsView?.window?.toolbar)
        }
    }

    /// Wraps the toolbar's delegate in the drop veto. Re-checked on every
    /// sweep: each surface switch creates a fresh NSToolbar with SwiftUI's
    /// own delegate, and the proxy must be re-applied to the new one.
    static func installVeto(on toolbar: NSToolbar?, coordinator: Coordinator?) {
        guard let toolbar, let coordinator,
              let delegate = toolbar.delegate, !(delegate is ToolbarDropVeto) else { return }
        let veto = ToolbarDropVeto(wrapping: delegate)
        coordinator.vetoes.append(veto)
        toolbar.delegate = veto
    }

    static func repairIfNeeded(_ toolbar: NSToolbar?) {
        guard let toolbar else { return }
        let identifiers = toolbar.items.map { $0.itemIdentifier.rawValue }
        guard ToolbarArrangement.repaired(identifiers) != identifiers else { return }
        // Scrub what's on disk first, so a relaunch is clean even if the
        // live re-application below doesn't take.
        ToolbarArrangement.repairSavedConfigurations(in: .standard)
        let key = ToolbarArrangement.configKeyPrefix + toolbar.identifier
        if let config = UserDefaults.standard.dictionary(forKey: key) {
            toolbar.setConfiguration(config)
        }
    }
}

// MARK: - Per-surface item sets

/// The default-hidden tail every document surface offers: zoom controls
/// and the content-width picker (plus, where the surface renders one, the
/// raw-source toggle). IDs carry the surface prefix so each surface keeps
/// its own arrangement.
private struct HiddenExtraItems: CustomizableToolbarContent {
    let state: AppState
    let idPrefix: String
    var includeSource = false

    var body: some CustomizableToolbarContent {
        if includeSource {
            ToolbarItem(id: "\(idPrefix)-source", showsByDefault: false) {
                SourceToolbarToggle(state: state)
            }
        }
        ToolbarItem(id: "\(idPrefix)-zoom-out", showsByDefault: false) {
            ZoomToolbarButton(operation: .zoomOut)
        }
        ToolbarItem(id: "\(idPrefix)-actual-size", showsByDefault: false) {
            ZoomToolbarButton(operation: .actualSize)
        }
        ToolbarItem(id: "\(idPrefix)-zoom-in", showsByDefault: false) {
            ZoomToolbarButton(operation: .zoomIn)
        }
        ToolbarItem(id: "\(idPrefix)-width", showsByDefault: false) {
            ContentWidthToolbarPicker()
        }
    }
}

private struct LocalFileToolbarItems: CustomizableToolbarContent {
    let state: AppState
    let surface: SurfaceToolbar?
    let marginNotesEnabled: Bool
    @AppStorage(DefaultsKeys.blame, store: UserDefaults.pullmark) private var blameVisible = false
    @AppStorage(DefaultsKeys.outlinePanel, store: UserDefaults.pullmark) private var outlineVisible = false

    var body: some CustomizableToolbarContent {
        ToolbarItem(id: "local-share") {
            ShareSheetButton(mode: .document, state: state, surface: surface,
                             help: "Share this document")
        }
        ToolbarItem(id: "local-edit") {
            EditToolbarToggle(surface: surface)
        }
        ToolbarItem(id: "local-compare") {
            CompareToolbarButton(surface: surface)
        }
        // Present whether or not the file sits in a git repository —
        // STRUCTURE never follows the registration (it arrives after the
        // toolbar is created, and conditional items resurrect removed
        // ones; see the header). No git context just disables the toggle.
        ToolbarItem(id: "local-blame") {
            BlameToggle(visible: $blameVisible)
                .disabled(surface?.blameAvailable != true
                    || surface?.blameDisabled == true)
        }
        ToolbarItem(id: "local-outline") {
            OutlineToggle(visible: $outlineVisible)
        }
        ToolbarItem(id: "local-reload") {
            ReloadToolbarButton(state: state, disabledReason: nil)
        }
        HiddenExtraItems(state: state, idPrefix: "local", includeSource: true)
        // In the pool only while the feature itself is on — an item for a
        // disabled alpha feature would be a ghost.
        if marginNotesEnabled {
            ToolbarItem(id: "local-margin-note", showsByDefault: false) {
                MarginNoteToolbarButton(state: state, surface: surface)
            }
        }
    }
}

private struct RemoteDocToolbarItems: CustomizableToolbarContent {
    let state: AppState
    let surface: SurfaceToolbar?
    @AppStorage(DefaultsKeys.blame, store: UserDefaults.pullmark) private var blameVisible = false
    @AppStorage(DefaultsKeys.outlinePanel, store: UserDefaults.pullmark) private var outlineVisible = false

    var body: some CustomizableToolbarContent {
        ToolbarItem(id: "remote-compare") {
            CompareToolbarButton(surface: surface)
        }
        ToolbarItem(id: "remote-blame") {
            BlameToggle(visible: $blameVisible)
        }
        ToolbarItem(id: "remote-outline") {
            OutlineToggle(visible: $outlineVisible)
        }
        ToolbarItem(id: "remote-share", showsByDefault: false) {
            ShareSheetButton(mode: .link, state: state, surface: surface,
                             help: "Share a link to this document on GitHub")
        }
        ToolbarItem(id: "remote-reload", showsByDefault: false) {
            ReloadToolbarButton(state: state,
                                disabledReason: surface?.reloadDisabledReason)
        }
        HiddenExtraItems(state: state, idPrefix: "remote", includeSource: true)
    }
}

private struct PRFileToolbarItems: CustomizableToolbarContent {
    let state: AppState
    let surface: SurfaceToolbar?
    @AppStorage(DefaultsKeys.blame, store: UserDefaults.pullmark) private var blameVisible = false
    @AppStorage(DefaultsKeys.outlinePanel, store: UserDefaults.pullmark) private var outlineVisible = false
    @AppStorage(DefaultsKeys.diffLayout, store: UserDefaults.pullmark) private var layoutRaw = PRFileView.DiffLayout.inline.rawValue

    var body: some CustomizableToolbarContent {
        // The sidebar shouldn't be the only way around a PR: back to the
        // overview, and step or jump between its Markdown files.
        ToolbarItem(id: "pr-nav", placement: .navigation) {
            PRFileNavigationItem(state: state)
        }
        ToolbarItem(id: "pr-mode", placement: .principal) {
            Picker("View", selection: Binding(
                get: { surface?.mode ?? "" },
                set: { surface?.setMode?($0) }
            )) {
                ForEach(surface?.modeOptions ?? [], id: \.self) { option in
                    Text(option).tag(option)
                }
            }
            .pickerStyle(.segmented)
        }
        ToolbarItem(id: "pr-outline") {
            OutlineToggle(visible: $outlineVisible)
        }
        // Unconditional for the same reason as local-blame: only the
        // rendered diff has a layout to pick, but the ITEM must exist at
        // toolbar creation. Other modes disable it.
        ToolbarItem(id: "pr-layout") {
            Picker("Layout", selection: $layoutRaw) {
                ForEach(PRFileView.DiffLayout.allCases) { layout in
                    Text(layout.rawValue).tag(layout.rawValue)
                }
            }
            .pickerStyle(.menu)
            // A brand-new file renders inline regardless: split mode
            // would show an all-hatched old column against the untinted
            // document — half the pane saying nothing.
            .disabled(surface?.showsLayout != true
                || surface?.layoutDisabledReason != nil)
            // Mode first: on an added file in Result mode both reasons are
            // true, but the mode is why the picker does nothing HERE.
            .help(surface?.showsLayout != true
                ? "Inline or side-by-side rendered diff — for the Rendered Diff view"
                : (surface?.layoutDisabledReason
                    ?? "Inline or side-by-side rendered diff"))
        }
        // Unconditional (structure never follows the registration);
        // blame annotates the Result view only, other modes disable it.
        ToolbarItem(id: "pr-blame") {
            BlameToggle(visible: $blameVisible)
                .disabled(surface?.blameAvailable != true)
        }
        ToolbarItem(id: "pr-comment") {
            Button {
                state.send(.commentOnFile)
            } label: {
                Label("Comment on File", systemImage: "plus.bubble")
            }
            .help("Comment on this file as a whole, not a specific line")
        }
        HiddenExtraItems(state: state, idPrefix: "pr")
    }
}

private struct PRDocToolbarItems: CustomizableToolbarContent {
    let state: AppState
    @AppStorage(DefaultsKeys.blame, store: UserDefaults.pullmark) private var blameVisible = false
    @AppStorage(DefaultsKeys.outlinePanel, store: UserDefaults.pullmark) private var outlineVisible = false

    var body: some CustomizableToolbarContent {
        ToolbarItem(id: "prdoc-blame") {
            BlameToggle(visible: $blameVisible)
        }
        ToolbarItem(id: "prdoc-outline") {
            OutlineToggle(visible: $outlineVisible)
        }
        HiddenExtraItems(state: state, idPrefix: "prdoc")
    }
}

private struct PROverviewToolbarItems: CustomizableToolbarContent {
    let state: AppState
    let surface: SurfaceToolbar?

    var body: some CustomizableToolbarContent {
        ToolbarItem(id: "overview-share") {
            ShareSheetButton(mode: .link, state: state, surface: surface,
                             help: "Share a link to this pull request")
        }
    }
}

// MARK: - Item content views

/// The share button: one click, the system sheet — but through AppKit's
/// picker rather than ShareLink (whose macOS Copy row has a
/// DTS-confirmed bug with custom payloads), and with the document
/// carried as ONE multi-flavor pasteboard item (DocumentShareItem).
/// That payload is the whole #72 fix: the sheet's Copy row writes the
/// picker's items verbatim, so a bare file URL pasted as a file NAME in
/// text fields; now Copy yields the file to Finder, rich text to chat
/// composers and word processors, and the Markdown source to plain
/// fields. Slack and Teams ship no macOS share extensions (verified),
/// so sheet-Copy-then-paste — or dragging the title-bar proxy icon in —
/// is the honest route to them.
private struct ShareSheetButton: View {
    enum Mode {
        /// Local file: the file itself plus its rendered/plain flavors.
        case document
        /// Remote doc or PR overview: the canonical web link.
        case link
    }
    let mode: Mode
    let state: AppState
    let surface: SurfaceToolbar?
    let help: String
    @State private var anchor = MenuAnchorBox()

    var body: some View {
        Button {
            if let view = anchor.view { present(from: view) }
        } label: {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        .accessibilityLabel("Share")
        .background(MenuAnchorReader(box: anchor))
        .disabled(surface?.shareURL == nil)
        .help(help)
    }

    private func present(from view: NSView) {
        guard let shareURL = surface?.shareURL else { return }
        // The registered document, when this surface owns one — comparing
        // unregisters it, and the sheet degrades to sharing the file
        // itself rather than a stale rendering. (The source view keeps
        // the registration; its share carries the rendered flavors.)
        if mode == .document, let document = state.activeDocument {
            DocumentShare.buildItem(for: document, fileURL: shareURL) {
                DocumentShare.presentSheet(item: $0, from: view)
            }
        } else {
            DocumentShare.presentSheet(url: shareURL, from: view)
        }
    }
}

private struct OpenFileToolbarButton: View {
    let state: AppState
    @ObservedObject private var shortcuts = ShortcutStore.shared

    var body: some View {
        Button {
            state.openFileOrFolder()
        } label: {
            Label("Open File or Folder", systemImage: "folder")
        }
        .help("Open local Markdown files or a folder"
            + shortcuts.hint(.openFile))
    }
}

private struct OpenPRToolbarButton: View {
    let state: AppState
    @ObservedObject private var shortcuts = ShortcutStore.shared

    var body: some View {
        Button {
            state.showAddPR = true
        } label: {
            Label("Open Pull Request", systemImage: "arrow.triangle.pull")
        }
        .help("Open a GitHub pull request"
            + shortcuts.hint(.openPullRequest))
    }
}

private struct EditToolbarToggle: View {
    let surface: SurfaceToolbar?
    @ObservedObject private var shortcuts = ShortcutStore.shared

    var body: some View {
        Toggle(isOn: Binding(
            get: { surface?.editMode ?? false },
            set: { surface?.setEditMode?($0) }
        )) {
            Label("Edit", systemImage: "pencil")
        }
        // The key equivalent lives on Edit → Edit Mode; binding it here too
        // would give one combo two owners.
        .help(surface?.editMode == true
            ? "Done editing\(shortcuts.hint(.editMode))"
            : "Edit this document\(shortcuts.hint(.editMode)) — then click any block")
        .disabled(surface?.editDisabled ?? true)
    }
}

/// A real button popping a native NSMenu built from live state at click
/// time (see MenuAnchorBox — SwiftUI's toolbar Menu caches stale rows).
/// The button owns the anchor; the surface view owns the menu content.
private struct CompareToolbarButton: View {
    let surface: SurfaceToolbar?
    @State private var anchor = MenuAnchorBox()

    var body: some View {
        Button {
            if let view = anchor.view { surface?.popCompare?(view) }
        } label: {
            HStack(spacing: 3) {
                // The quiet signal that there's something to compare:
                // this file has uncommitted changes. Anchored to the
                // clock glyph itself (the thing it badges) at its
                // 1-o'clock, with a background-colored keyline so the
                // overlap reads deliberate. Hidden mid-comparison — the
                // page is already showing the changes.
                Image(systemName: "clock.arrow.circlepath")
                    .overlay(alignment: .topTrailing) {
                        if surface?.compareHasChanges == true, surface?.comparing != true {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 5, height: 5)
                                .background(
                                    Circle()
                                        .fill(Color(nsColor: .windowBackgroundColor))
                                        .frame(width: 7.5, height: 7.5)
                                )
                                .offset(x: 2, y: -1.5)
                                .accessibilityLabel("Uncommitted changes")
                        }
                    }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .opacity(0.8)
            }
        }
        .accessibilityLabel("Compare")
        .background(MenuAnchorReader(box: anchor))
        .disabled(surface?.compareAvailable != true)
        .help(surface?.compareAvailable != true
            ? (surface?.compareUnavailableReason ?? "Comparing is unavailable here")
            : surface?.compareHasChanges == true
                ? "This file has uncommitted changes — compare with a previous revision or branch"
                : "Compare with a previous revision or branch")
    }
}

private struct ReloadToolbarButton: View {
    let state: AppState
    let disabledReason: String?

    var body: some View {
        Button {
            state.send(.reload)
        } label: {
            Label("Reload", systemImage: "arrow.clockwise")
        }
        .disabled(disabledReason != nil)
        .help(disabledReason ?? "Reload this document")
    }
}

private struct SourceToolbarToggle: View {
    @ObservedObject var state: AppState
    @ObservedObject private var shortcuts = ShortcutStore.shared

    var body: some View {
        Toggle(isOn: $state.sourceViewVisible) {
            Label("Source", systemImage: "chevron.left.forwardslash.chevron.right")
        }
        // Same condition as View → Show Markdown Source: no rendered
        // document on screen (a comparison, say), nothing to flip.
        .disabled(state.activeDocument == nil)
        .help("Show the raw Markdown behind the rendered document"
            + shortcuts.hint(.toggleSource))
    }
}

/// One zoom control per toolbar item — a grouped ControlGroup was tried
/// and the customize palette rendered its three button labels on top of
/// each other; separate items also let people add just the pair they use.
private struct ZoomToolbarButton: View {
    enum Operation { case zoomOut, actualSize, zoomIn }
    let operation: Operation
    @AppStorage(DefaultsKeys.zoom, store: UserDefaults.pullmark) private var zoom = 1.0
    @ObservedObject private var shortcuts = ShortcutStore.shared

    var body: some View {
        switch operation {
        case .zoomOut:
            Button {
                zoom = DocumentZoom.zoomOut(from: zoom)
            } label: {
                Label("Zoom Out", systemImage: "minus.magnifyingglass")
            }
            .disabled(zoom <= DocumentZoom.minimum)
            .help("Make the document smaller" + shortcuts.hint(.zoomOut))
        case .actualSize:
            Button {
                zoom = 1.0
            } label: {
                Label("Actual Size", systemImage: "1.magnifyingglass")
            }
            .disabled(DocumentZoom.isActualSize(zoom))
            .help("Reset the zoom to 100%" + shortcuts.hint(.actualSize))
        case .zoomIn:
            Button {
                zoom = DocumentZoom.zoomIn(from: zoom)
            } label: {
                Label("Zoom In", systemImage: "plus.magnifyingglass")
            }
            .disabled(zoom >= DocumentZoom.maximum)
            .help("Make the document bigger" + shortcuts.hint(.zoomIn))
        }
    }
}

private struct ContentWidthToolbarPicker: View {
    @AppStorage(ContentWidth.defaultsKey, store: UserDefaults.pullmark) private var contentWidthRaw = ContentWidth.standard.rawValue

    var body: some View {
        Menu {
            Picker("Content Width", selection: $contentWidthRaw) {
                ForEach(ContentWidth.allCases) { width in
                    Text(width.label).tag(width.rawValue)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label("Content Width", systemImage: "arrow.left.and.right")
        }
        .help("How wide the rendered text column runs")
    }
}

private struct MarginNoteToolbarButton: View {
    let state: AppState
    let surface: SurfaceToolbar?
    @ObservedObject private var shortcuts = ShortcutStore.shared

    var body: some View {
        Button {
            state.send(.addMarginNote)
        } label: {
            Label("Add Margin Note", systemImage: "note.text.badge.plus")
        }
        .disabled(surface?.marginNoteDisabled ?? true)
        .help("Add a margin note on the block you're reading"
            + shortcuts.hint(.addMarginNote))
    }
}

/// The PR file navigation cluster, rebuilt from app state — the selection
/// carries the session and path, so no registration is needed.
private struct PRFileNavigationItem: View {
    @ObservedObject var state: AppState

    var body: some View {
        if case .prFile(let sessionID, let path) = state.selection,
           let session = state.session(sessionID) {
            // HStack, deliberately: PRFileNavigation's body emits several
            // sibling views (back, previous/next, the n-of-m jump menu),
            // and a ToolbarItem renders only the FIRST view of a bare
            // tuple — the old code spread them across a ToolbarItemGroup,
            // which has no customizable form. The stack keeps the whole
            // wayfinding cluster one draggable unit.
            // (Toolbar content also doesn't reliably inherit the
            // hierarchy's environment — inject explicitly.)
            HStack(spacing: 2) {
                PRFileNavigation(sessionID: sessionID, path: path, session: session)
            }
            .environmentObject(state)
        }
    }
}
