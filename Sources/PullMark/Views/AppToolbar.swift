import SwiftUI
import AppKit

/// The whole window's toolbar, customizable via the native right-click →
/// Customize Toolbar… palette. Every item lives here — window-level
/// actions and the active surface's controls alike — because SwiftUI only
/// persists toolbar customization for window-level `.toolbar(id:)`
/// content: detail-hosted customizable items are re-merged fresh at every
/// launch, resurrecting whatever the user removed, and a single unnamed
/// `.toolbar {}` item anywhere in the window disables customization for
/// the whole toolbar (both verified live on this OS). Surface views feed
/// their values and callbacks through SurfaceToolbar registration.
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
    let surface: SurfaceToolbar?
    let reviewSessionID: String?
    let marginNotesEnabled: Bool
    @Binding var appearanceRaw: String

    var body: some CustomizableToolbarContent {
        if let surface {
            switch surface.kind {
            case .localFile:
                LocalFileToolbarItems(state: state, surface: surface,
                                      marginNotesEnabled: marginNotesEnabled)
            case .remoteDoc:
                RemoteDocToolbarItems(state: state, surface: surface)
            case .prFile:
                PRFileToolbarItems(state: state, surface: surface)
            case .prDoc:
                PRDocToolbarItems(state: state, surface: surface)
            case .prOverview:
                PROverviewToolbarItems(surface: surface)
            }
        }
        windowItems
    }

    /// The window-level cluster, present on every surface. Declaration
    /// order is collapse priority (later dies first), and SwiftUI ignores
    /// NSToolbarItem.visibilityPriority for its own "»" overflow (verified
    /// live) — so Review is declared FIRST here: review status must
    /// survive the squeeze that rightly claims the open buttons and
    /// appearance menu before it (spec §3). The cost is position — Review
    /// sits left of the open/appearance cluster now instead of
    /// trailing-most.
    @ToolbarContentBuilder
    private var windowItems: some CustomizableToolbarContent {
        if let reviewSessionID {
            ToolbarItem(id: "review", placement: .primaryAction) {
                ReviewToolbarButton(sessionID: reviewSessionID,
                                    tracker: state.reviewAnchor) {
                    state.send(.reviewChanges)
                }
            }
        }
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
    let surface: SurfaceToolbar
    let marginNotesEnabled: Bool
    @AppStorage(DefaultsKeys.blame, store: UserDefaults.pullmark) private var blameVisible = false
    @AppStorage(DefaultsKeys.outlinePanel, store: UserDefaults.pullmark) private var outlineVisible = false

    var body: some CustomizableToolbarContent {
        ToolbarItem(id: "local-share") {
            if let url = surface.shareURL {
                ShareLink(item: url)
                    .help("Share this document")
            }
        }
        ToolbarItem(id: "local-edit") {
            EditToolbarToggle(surface: surface)
        }
        ToolbarItem(id: "local-compare") {
            CompareToolbarButton(surface: surface)
        }
        // No git context, no Blame button: the toggle only appears for
        // files inside a repository.
        if surface.blameAvailable {
            ToolbarItem(id: "local-blame") {
                BlameToggle(visible: $blameVisible)
                    .disabled(surface.blameDisabled)
            }
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
    let surface: SurfaceToolbar
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
            if let url = surface.shareURL {
                ShareLink(item: url)
                    .help("Share a link to this document on GitHub")
            }
        }
        ToolbarItem(id: "remote-reload", showsByDefault: false) {
            ReloadToolbarButton(state: state,
                                disabledReason: surface.reloadDisabledReason)
        }
        HiddenExtraItems(state: state, idPrefix: "remote", includeSource: true)
    }
}

private struct PRFileToolbarItems: CustomizableToolbarContent {
    let state: AppState
    let surface: SurfaceToolbar
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
                get: { surface.mode ?? "" },
                set: { surface.setMode?($0) }
            )) {
                ForEach(surface.modeOptions, id: \.self) { option in
                    Text(option).tag(option)
                }
            }
            .pickerStyle(.segmented)
        }
        ToolbarItem(id: "pr-outline") {
            OutlineToggle(visible: $outlineVisible)
        }
        if surface.showsLayout {
            ToolbarItem(id: "pr-layout") {
                Picker("Layout", selection: $layoutRaw) {
                    ForEach(PRFileView.DiffLayout.allCases) { layout in
                        Text(layout.rawValue).tag(layout.rawValue)
                    }
                }
                .pickerStyle(.menu)
                // A brand-new file renders inline regardless: split mode
                // would show an all-hatched old column against the
                // untinted document — half the pane saying nothing.
                .disabled(surface.layoutDisabledReason != nil)
                .help(surface.layoutDisabledReason
                    ?? "Inline or side-by-side rendered diff")
            }
        }
        if surface.blameAvailable {
            ToolbarItem(id: "pr-blame") {
                BlameToggle(visible: $blameVisible)
            }
        }
        if surface.showsFileComment {
            ToolbarItem(id: "pr-comment") {
                Button {
                    state.send(.commentOnFile)
                } label: {
                    Label("Comment on File", systemImage: "plus.bubble")
                }
                .help("Comment on this file as a whole, not a specific line")
            }
        }
        HiddenExtraItems(state: state, idPrefix: "pr")
    }
}

private struct PRDocToolbarItems: CustomizableToolbarContent {
    let state: AppState
    let surface: SurfaceToolbar
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
    let surface: SurfaceToolbar

    var body: some CustomizableToolbarContent {
        ToolbarItem(id: "overview-share") {
            if let url = surface.shareURL {
                ShareLink(item: url)
                    .help("Share a link to this pull request")
            }
        }
    }
}

// MARK: - Item content views

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
    let surface: SurfaceToolbar
    @ObservedObject private var shortcuts = ShortcutStore.shared

    var body: some View {
        Toggle(isOn: Binding(
            get: { surface.editMode },
            set: { surface.setEditMode?($0) }
        )) {
            Label("Edit", systemImage: "pencil")
        }
        // The key equivalent lives on Edit → Edit Mode; binding it here too
        // would give one combo two owners.
        .help(surface.editMode
            ? "Done editing\(shortcuts.hint(.editMode))"
            : "Edit this document\(shortcuts.hint(.editMode)) — then click any block")
        .disabled(surface.editDisabled)
    }
}

/// A real button popping a native NSMenu built from live state at click
/// time (see MenuAnchorBox — SwiftUI's toolbar Menu caches stale rows).
/// The button owns the anchor; the surface view owns the menu content.
private struct CompareToolbarButton: View {
    let surface: SurfaceToolbar
    @State private var anchor = MenuAnchorBox()

    var body: some View {
        Button {
            if let view = anchor.view { surface.popCompare?(view) }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "clock.arrow.circlepath")
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .opacity(0.8)
            }
        }
        .accessibilityLabel("Compare")
        .background(MenuAnchorReader(box: anchor))
        .disabled(!surface.compareAvailable)
        .help(surface.compareAvailable
            ? "Compare with a previous revision or branch"
            : (surface.compareUnavailableReason ?? "Comparing is unavailable here"))
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
    let surface: SurfaceToolbar
    @ObservedObject private var shortcuts = ShortcutStore.shared

    var body: some View {
        Button {
            state.send(.addMarginNote)
        } label: {
            Label("Add Margin Note", systemImage: "note.text.badge.plus")
        }
        .disabled(surface.marginNoteDisabled)
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
            // Toolbar content doesn't reliably inherit the hierarchy's
            // environment — inject explicitly.
            PRFileNavigation(sessionID: sessionID, path: path, session: session)
                .environmentObject(state)
        }
    }
}
