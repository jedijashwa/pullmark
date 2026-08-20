import SwiftUI

/// The Settings window (⌘,): a General tab for behavior, an Appearance tab
/// for how rendered pages look (themes — live preview cards through the
/// real WKWebView pipeline — plus content width and line numbers), and a
/// Keyboard tab.
struct SettingsView: View {
    /// Persisted so Settings reopens on the tab you last used.
    @AppStorage(DefaultsKeys.settingsTab, store: UserDefaults.pullmark) private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag("general")
            ThemeSettingsTab()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
                .tag("themes") // tag kept stable so the saved tab choice survives the rename
            KeyboardSettingsTab()
                .tabItem { Label("Keyboard", systemImage: "keyboard") }
                .tag("keyboard")
            ExperimentalSettingsTab()
                .tabItem { Label("Experimental", systemImage: "testtube.2") }
                .tag("experimental")
        }
        .frame(width: 680)
    }
}

// MARK: - General

struct GeneralSettingsTab: View {
    @State private var languageRaw = AppLanguage.current.rawValue
    @EnvironmentObject private var updates: UpdateChecker
    @EnvironmentObject private var defaultApp: DefaultAppManager
    @AppStorage(DefaultsKeys.diffLayout, store: UserDefaults.pullmark) private var diffLayoutRaw = PRFileView.DiffLayout.inline.rawValue
    @AppStorage(DefaultsKeys.qlRendered, store: UserDefaults.pullmark) private var qlRendered = true
    @AppStorage(DefaultsKeys.inboxEnabled, store: UserDefaults.pullmark) private var inboxEnabled = true
    @AppStorage(DefaultsKeys.inboxMarkdownOnly, store: UserDefaults.pullmark) private var inboxMarkdownOnly = true
    @AppStorage(DefaultsKeys.prDiscussionEnabled, store: UserDefaults.pullmark) private var prDiscussionEnabled = true
    @AppStorage(DefaultsKeys.restoreSession, store: UserDefaults.pullmark) private var restoreSession = true
    @AppStorage(DefaultsKeys.remoteLinkPolicy, store: UserDefaults.pullmark) private var remoteLinkPolicyRaw = RemoteLinkPolicy.ask.rawValue
    @AppStorage(DefaultsKeys.folderClickAction, store: UserDefaults.pullmark) private var folderClickRaw = FolderClickAction.preview.rawValue
    @AppStorage(DefaultsKeys.showHiddenFiles, store: UserDefaults.pullmark) private var showHiddenFiles = false
    @AppStorage(DefaultsKeys.autoShowWhatsNew, store: UserDefaults.pullmark) private var autoShowWhatsNew = true
    @State private var updateStatus: String?
    @State private var checking = false
    @State private var cliStatus = CLIInstaller.Status.unavailable
    @State private var cliError: String?
    /// The known-update What's New sheet, presented HERE — the banner's
    /// sheet lives on the main window, and Settings must not point at it.
    @State private var showAvailableNotes = false

    /// Deep-link landing spots this tab owns (AppLinks anchor ids).
    private static let anchors: Set<String> = [
        "github", "restore-session", "show-hidden-files", "github-links",
        "clicking-files", "diff-layout", "review-requests", "pr-discussion",
        "whats-new", "check-updates", "default-app", "command-line", "quick-look",
    ]

    var body: some View {
        ScrollViewReader { scroll in
        Form {
            GitHubNotConnectedAlert()

            Section("Language") {
            Picker("Language:", selection: $languageRaw) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.label).tag(language.rawValue)
                }
            }
            .onChange(of: languageRaw) { raw in
                (AppLanguage(rawValue: raw) ?? .system).apply()
            }
            .settingAnchor("language")
            Text("Takes effect the next time PullMark opens.")
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Section("Reading") {
            Toggle("Restore files and pull requests from the last session", isOn: $restoreSession)
                .help("Reopen what was in the sidebar when PullMark last quit")
                .settingAnchor("restore-session")

            Toggle("Show hidden files", isOn: $showHiddenFiles)
                .help("Dotfiles and hidden folders in Locations — ⇧⌘. toggles this too, like Finder")
                .settingAnchor("show-hidden-files")

            Picker("GitHub Markdown links:", selection: $remoteLinkPolicyRaw) {
                Text("Ask on first click").tag(RemoteLinkPolicy.ask.rawValue)
                Text("Open in PullMark").tag(RemoteLinkPolicy.pullmark.rawValue)
                Text("Open in Browser").tag(RemoteLinkPolicy.browser.rawValue)
            }
            .help("What clicking a link to a Markdown file on GitHub does — hold ⌘ while clicking for the other behavior")
            .settingAnchor("github-links")

            Picker("Clicking files in Locations:", selection: $folderClickRaw) {
                Text("Preview First").tag(FolderClickAction.preview.rawValue)
                Text("Open Fully").tag(FolderClickAction.open.rawValue)
            }
            .settingAnchor("clicking-files")
            Text("Preview First shows a file with one click without keeping it — one italicized entry (in Open Files, or under its GitHub repo) that the next preview replaces. Double-click a file, or just start editing, to keep it open. Open Fully keeps every file you click.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section("Reviewing") {
            Picker("Default diff layout:", selection: $diffLayoutRaw) {
                ForEach(PRFileView.DiffLayout.allCases) { layout in
                    Text(layout.rawValue).tag(layout.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .settingAnchor("diff-layout")

            Toggle("Show review requests in the sidebar", isOn: $inboxEnabled)
                .help("Open pull requests where your review is requested")
                .settingAnchor("review-requests")
            Toggle("Only requests that change Markdown", isOn: $inboxMarkdownOnly)
                .disabled(!inboxEnabled)
                .padding(.leading, 20)
                .help("Hide review requests with no Markdown files — PullMark has nothing to show for them")

            // Graduated from Experimental (beta) in the cockpit wave —
            // on by default; stored choices from the beta days stand.
            Toggle("Show review discussion on the PR overview", isOn: $prDiscussionEnabled)
                .help("Adds a Review discussion section under the PR description listing every thread, with code excerpts and links")
                .settingAnchor("pr-discussion")
            }

            // After Reviewing (Josh's placement): the connection is
            // infrastructure, not the app's headline — the top-of-tab
            // alert carries the not-connected case up front instead.
            GitHubConnectionSection()

            Section("Updates") {
            Toggle("Show What's New after an update", isOn: $autoShowWhatsNew)
                .help("Off shows a quiet banner instead — the notes stay one click away")
                .settingAnchor("whats-new")

            LabeledContent("Updates:") {
                // Trailing-aligned: the status line appearing must not widen
                // the column and shove the buttons away from the right edge.
                VStack(alignment: .trailing, spacing: 6) {
                    if let version = updates.availableVersion {
                        // An update is already known: offer it right here —
                        // never send anyone to another window to act on it.
                        HStack(spacing: 8) {
                            if checking {
                                ProgressView().controlSize(.small)
                            }
                            Button("What's New") { showAvailableNotes = true }
                            Button("Update Now") { updates.updateNow() }
                                .buttonStyle(.borderedProminent)
                                .disabled(updates.isUpdating)
                            Button {
                                check()
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .disabled(checking || updates.isUpdating)
                            .help("See if something even newer is available")
                            .accessibilityLabel("Check again for updates")
                        }
                        Text("PullMark \(version) is available.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        switch updates.updateRun {
                        case .updating(let phase):
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text(phase)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        case .failed(let message):
                            Text("Update failed: \(message)")
                                .font(.callout)
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        case .idle:
                            EmptyView()
                        }
                    } else {
                        HStack(spacing: 8) {
                            if checking {
                                ProgressView().controlSize(.small)
                            }
                            Button("Check for Updates…") { check() }
                                .disabled(checking)
                        }
                    }
                    if let updateStatus {
                        Text(updateStatus)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .settingAnchor("check-updates")
            }

            Section("System") {
            LabeledContent("Default Markdown app:") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 7) {
                        if let icon = defaultApp.currentHandlerIcon {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 19, height: 19)
                        }
                        Text(defaultApp.currentHandlerName ?? "No app is set")
                        if defaultApp.isPullMarkDefault {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .help("Markdown files open in PullMark")
                        }
                    }
                    // Never offered from `swift run` — a dev binary must not
                    // grab the Launch Services binding.
                    if defaultApp.isAppBundle && !defaultApp.isPullMarkDefault {
                        HStack(spacing: 8) {
                            Button("Make PullMark the Default") { defaultApp.makeDefault() }
                                .disabled(defaultApp.claiming)
                            if defaultApp.claiming {
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                    if let error = defaultApp.lastError {
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .settingAnchor("default-app")

            LabeledContent("Command line:") {
                // The `pullmark` command for DMG installs — Homebrew users
                // already get it from the cask's binary stanza.
                VStack(alignment: .leading, spacing: 6) {
                    if cliStatus == .installed {
                        HStack(spacing: 7) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("The pullmark command is installed")
                        }
                    } else if cliStatus == .notInstalled {
                        Button("Install pullmark Command…") {
                            cliError = CLIInstaller.install()
                            cliStatus = CLIInstaller.status
                        }
                        .help("Adds a pullmark command to /usr/local/bin so you can open files and folders from the shell")
                    } else {
                        Text("Not available in this build")
                            .foregroundStyle(.secondary)
                    }
                    if let cliError {
                        Text(cliError)
                            .font(.callout)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // A single literal: concatenation would select Text's
                    // verbatim String initializer and render raw markdown.
                    Text("Open files, folders, and worktrees from the shell — [about the pullmark command](https://pullmark.app/docs/cli/).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .settingAnchor("command-line")

            Picker("Quick Look previews:", selection: $qlRendered) {
                Text("Rendered").tag(true)
                Text("Raw Source").tag(false)
            }
            .pickerStyle(.segmented)
            .help("What pressing space in Finder shows for Markdown files")
            .settingAnchor("quick-look")
            }

        }
        .formStyle(.grouped)
        .frame(height: 560)
        .consumesSettingAnchors(Self.anchors, proxy: scroll)
        }
        // The binding can change behind our back (Finder's "Change All…",
        // another app claiming it) — re-resolve whenever the tab shows.
        .onAppear {
            defaultApp.refresh()
            cliStatus = CLIInstaller.status
            // The Updates row can offer Update Now directly — resolve how
            // this copy updates (brew cask vs in-place) before it's needed.
            updates.detectUpdateMethodIfNeeded()
        }
        .sheet(isPresented: $showAvailableNotes) {
            ReleaseNotesSheet(title: "What's New in PullMark",
                              markdown: updates.availableNotes)
        }
    }

    private func check() {
        checking = true
        updateStatus = nil
        let before = updates.availableVersion
        Task {
            let message = await updates.checkManually()
            if let message {
                updateStatus = message
            } else if let after = updates.availableVersion, after == before {
                updateStatus = "PullMark \(after) is still the newest available."
            }
            checking = false
        }
    }
}

// MARK: - Experimental

/// How settled an experimental feature is. Two levels, one contract
/// each: beta features get a valiant compatibility effort and are
/// likely to graduate; alpha features carry no guarantees at all —
/// they may change incompatibly or disappear.
enum ExperimentalLevel {
    case alpha, beta

    var label: String {
        switch self {
        case .alpha: return "ALPHA"
        case .beta: return "BETA"
        }
    }
}

/// The level badge every experimental feature wears.
struct ExperimentalBadge: View {
    let level: ExperimentalLevel

    var body: some View {
        Text(level.label)
            .font(.system(size: 9, weight: .bold))
            .kerning(0.6)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(level == .alpha
                    ? Color.orange.opacity(0.22) : Color.purple.opacity(0.18)))
            .foregroundStyle(level == .alpha ? Color.orange : Color.purple)
            .accessibilityLabel("\(level.label) experimental feature")
    }
}

/// The Experimental tab: the levels contract up top, an alpha
/// visibility switch (confirmed before it turns on), then every
/// experimental feature as its own labeled section — with empty states
/// for "none right now" and "all alpha, alpha hidden".
struct ExperimentalSettingsTab: View {
    @AppStorage(DefaultsKeys.showAlphaFeatures, store: UserDefaults.pullmark) private var showAlphaFeatures = false
    @AppStorage(DefaultsKeys.marginNotesEnabled, store: UserDefaults.pullmark) private var marginNotesEnabled = true
    @AppStorage(DefaultsKeys.marginNotesIntroSeen, store: UserDefaults.pullmark) private var marginNotesIntroSeen = false
    @AppStorage(DefaultsKeys.marginNoteAuthor, store: UserDefaults.pullmark) private var marginNoteAuthor = ""
    @State private var confirmingAlpha = false
    @State private var copiedSnippet = false

    /// The current roster, by level. The empty states below cover the
    /// day either level empties out again. (Review discussion
    /// graduated to General ▸ Reviewing in 0.34.0; margin notes
    /// graduated alpha → beta in 0.35.0.)
    private static let alphaFeatureCount = 0
    private static let betaFeatureCount = 1

    var body: some View {
        ScrollViewReader { scroll in
        Form {
            Section {
                // Single literals per branch: concatenation would select
                // Text's verbatim String initializer and render raw
                // markdown. The alpha sentence (and switch) only exist
                // while something is actually at that level — explaining
                // and gating an empty tier just confuses.
                if Self.alphaFeatureCount > 0 {
                    Text("Features land here before their design is settled. **Beta** features get a real compatibility effort between versions and are likely to graduate. **Alpha** features carry no guarantees: they may change incompatibly, their data formats may not migrate, and they may disappear entirely. [About experimental features](https://pullmark.app/docs/experimental/)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Toggle("Show alpha features", isOn: alphaBinding)
                } else {
                    Text("Features land here before their design is settled. **Beta** features get a real compatibility effort between versions and are likely to graduate. [About experimental features](https://pullmark.app/docs/experimental/)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if Self.betaFeatureCount == 0 && !showAlphaFeatures {
                emptyState(
                    "Nothing to show at this level",
                    detail: Self.alphaFeatureCount > 0
                        ? "Every current experimental feature is alpha — turn on "
                            + "“Show alpha features” to see \(Self.alphaFeatureCount == 1 ? "it" : "them")."
                        : "There are no experimental features right now.")
            }

            marginNotesSection
        }
        .formStyle(.grouped)
        .frame(height: 560)
        .consumesSettingAnchors(["margin-notes"], proxy: scroll)
        .onAppear {
            // A deep link that landed here wants something alpha —
            // don't let the tab look empty; offer the switch directly.
            if SettingsOpener.pendingAlphaPrompt {
                SettingsOpener.pendingAlphaPrompt = false
                if !showAlphaFeatures { confirmingAlpha = true }
            }
        }
        }
        .alert("Show alpha features?", isPresented: $confirmingAlpha) {
            Button("Show Alpha Features") { showAlphaFeatures = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Alpha features are the frontier: their behavior and data formats may change incompatibly between versions, transitions may not be supported, and a feature may be removed entirely. Use them at your own risk.")
        }
    }

    /// The switch itself never flips on directly — the confirmation
    /// dialog owns that; turning alpha OFF needs no ceremony.
    private var alphaBinding: Binding<Bool> {
        Binding(
            get: { showAlphaFeatures },
            set: { wanted in
                if wanted { confirmingAlpha = true } else { showAlphaFeatures = false }
            }
        )
    }

    private func emptyState(_ title: String, detail: String) -> some View {
        Section {
            VStack(spacing: 8) {
                Image(systemName: "testtube.2")
                    .font(.system(size: 28))
                    .foregroundStyle(.tertiary)
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
        }
    }

    private var marginNotesSection: some View {
        Section {
            // Visible whether or not the feature is on: what it is, and
            // where to read more.
            Text("Comment on any local Markdown document the way you'd comment on a PR. Notes save into the file itself as `<!-- note @you: … -->` comments — ordinary HTML comments that stay out of rendered Markdown, shown by PullMark as bubbles pinned to their spot, and written so agents can read and act on them. [How margin notes work](https://pullmark.app/docs/experimental/margin-notes/)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .settingAnchor("margin-notes")

            Toggle("Enable margin notes", isOn: $marginNotesEnabled)
                .help("Adds the authoring tools — hover a block, ⌥⌘M; documents that already contain notes always show them either way")
                // Flipping the toggle in either direction is an informed
                // choice — this section says everything the first-use
                // intro would, so it never needs to interrupt later.
                .onChange(of: marginNotesEnabled) { _ in
                    marginNotesIntroSeen = true
                }

            if marginNotesEnabled {
                TextField("Sign notes as:", text: $marginNoteAuthor,
                          prompt: Text(NSUserName()))
                    .help("The @name your notes carry — empty uses your GitHub login, or this Mac's account name when signed out")

                VStack(alignment: .leading, spacing: 6) {
                    Text("Using it")
                        .font(.callout.weight(.semibold))
                    Text("Hover any block for the note bubble (select text first to quote it), or press ⌥⌘M. Edit and delete from each bubble; deleting a note is how it's resolved. Open Files rows show a count chip while a document still carries notes, and View → Hide Margin Notes clears the page for clean reading.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Teach your agent")
                            .font(.callout.weight(.semibold))
                        Spacer()
                        Button(copiedSnippet ? String(localized: "Copied") : String(localized: "Copy")) {
                            let pasteboard = NSPasteboard.general
                            pasteboard.clearContents()
                            pasteboard.setString(MarginNotes.agentInstructions, forType: .string)
                            copiedSnippet = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                copiedSnippet = false
                            }
                        }
                        .help("Copies instructions for CLAUDE.md / AGENTS.md — how to read margin notes and delete them as they're addressed")
                    }
                    Text("Paste the copied snippet into your agent's instructions file (CLAUDE.md, AGENTS.md, …) and \"address the margin notes in the file\" becomes a complete handoff — the agent deletes each note as it resolves it, and you watch the bubbles disappear.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            HStack(spacing: 8) {
                Text("Margin Notes")
                ExperimentalBadge(level: .beta)
            }
        }
    }
}

// MARK: - Themes

struct ThemeSettingsTab: View {
    @AppStorage(Appearance.defaultsKey, store: UserDefaults.pullmark) private var appearanceRaw = Appearance.system.rawValue
    @AppStorage(Theme.defaultsKey, store: UserDefaults.pullmark) private var themeRaw = Theme.standard.rawValue
    @AppStorage(ContentWidth.defaultsKey, store: UserDefaults.pullmark) private var contentWidthRaw = ContentWidth.standard.rawValue
    @AppStorage(LineNumbers.defaultsKey, store: UserDefaults.pullmark) private var lineNumbersOn = false
    @State private var customNames: [String] = []

    private var selection: ThemeSelection {
        ThemeSelection.resolve(themeRaw, availableCustom: customNames)
    }

    /// Deep-link landing spots this tab owns (AppLinks anchor ids).
    private static let anchors: Set<String> = [
        "appearance-mode", "theme", "content-width", "line-numbers",
    ]

    var body: some View {
        ScrollViewReader { scroll in
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Appearance")
                    .font(.headline)
                    .settingAnchor("appearance-mode")
                Picker("Appearance", selection: $appearanceRaw) {
                    ForEach(Appearance.allCases) { appearance in
                        Text(appearance.label).tag(appearance.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 340)
                Text("Light, Dark, or match the system — the window and every rendered page follow, and each theme brings its own light and dark looks.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Theme")
                    .font(.headline)
                    .padding(.top, 10)
                    .settingAnchor("theme")
                HStack(alignment: .top, spacing: 16) {
                    ForEach(Theme.allCases) { theme in
                        ThemePreviewCard(
                            title: theme.label,
                            descriptor: theme.descriptor,
                            theme: theme.rawValue,
                            selected: selection == ThemeSelection(theme: theme, customName: nil)
                        ) {
                            themeRaw = theme.rawValue
                        }
                    }
                }
                if !customNames.isEmpty {
                    Text("Custom themes")
                        .font(.headline)
                        .padding(.top, 4)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 16)],
                              alignment: .leading, spacing: 16) {
                        ForEach(customNames, id: \.self) { name in
                            ThemePreviewCard(
                                title: name,
                                descriptor: "\(name).css",
                                theme: Theme.github.rawValue,
                                customCSS: CustomThemes.css(for: name),
                                selected: selection.customName == name
                            ) {
                                themeRaw = CustomThemes.selectionPrefix + name
                            }
                        }
                    }
                }
                HStack(spacing: 10) {
                    Button("Open Themes Folder") {
                        NSWorkspace.shared.open(CustomThemes.ensureDirectoryExists())
                    }
                    Button("Refresh") { customNames = CustomThemes.availableThemeNames() }
                }
                .padding(.top, 2)
                Text("Themes restyle rendered Markdown and diffs, and follow the Light/Dark appearance. Drop .css files into the Themes folder to add your own — they apply on top of the GitHub look. Quick Look previews follow your theme too (custom themes fall back to their GitHub base there).")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Content width")
                    .font(.headline)
                    .padding(.top, 10)
                    .settingAnchor("content-width")
                HStack(alignment: .top, spacing: 16) {
                    ForEach(ContentWidth.allCases) { width in
                        WidthPreviewCard(width: width, selected: contentWidthRaw == width.rawValue) {
                            contentWidthRaw = width.rawValue
                        }
                    }
                }
                Text("How far text may stretch before it wraps. Standard keeps the classic book-like measure; Wide fits more on screen and still caps the line length; Full Width gives the document the whole window — handy in full screen. Applies everywhere, live, and plays with any theme.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Line numbers")
                    .font(.headline)
                    .padding(.top, 10)
                    .settingAnchor("line-numbers")
                HStack(alignment: .top, spacing: 16) {
                    LineNumberPreviewCard(showNumbers: false, selected: !lineNumbersOn) {
                        lineNumbersOn = false
                    }
                    LineNumberPreviewCard(showNumbers: true, selected: lineNumbersOn) {
                        lineNumbersOn = true
                    }
                }
                Text("Each block's starting source line, in the margin of rendered documents and diffs — hover a number for the block's full range. Rendered text wraps freely, so numbering is per block, not per visual line. The raw source view always shows its own line numbers.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
        }
        .frame(height: 620)
        .consumesSettingAnchors(Self.anchors, proxy: scroll)
        }
        .onAppear { customNames = CustomThemes.availableThemeNames() }
    }
}

/// One selectable content-width card: a drawn miniature page whose text
/// column sits at that option's proportion of the window — the System
/// Settings Appearance-picker pattern, where every option is a small
/// picture of its result.
struct WidthPreviewCard: View {
    let width: ContentWidth
    let selected: Bool
    let select: () -> Void

    /// The miniature's text-column share of the page. Not to scale —
    /// exaggerated enough to read at a glance.
    private var measure: CGFloat {
        switch width {
        case .standard: return 0.55
        case .wide: return 0.78
        case .full: return 0.96
        }
    }

    /// Text lines as fractions of the column (a heading, then prose with
    /// a ragged last line).
    private static let lines: [(width: CGFloat, height: CGFloat, emphasis: Bool)] = [
        (0.42, 6, true),
        (1.0, 3.5, false), (0.97, 3.5, false), (1.0, 3.5, false),
        (0.88, 3.5, false), (1.0, 3.5, false), (0.58, 3.5, false),
    ]

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color(nsColor: .textBackgroundColor))
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(Self.lines.enumerated()), id: \.offset) { _, line in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(.secondary.opacity(line.emphasis ? 0.55 : 0.3))
                            .frame(width: max(10, 176 * measure * line.width),
                                   height: line.height)
                    }
                }
                .frame(width: 176 * measure, alignment: .leading)
            }
            .frame(width: 200, height: 108)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(selected ? Color.accentColor : Color(nsColor: .separatorColor),
                                  lineWidth: selected ? 2.5 : 1)
            )
            .overlay(alignment: .bottomTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color.white, Color.accentColor)
                        .background(Circle().fill(.white).padding(2))
                        .padding(7)
                }
            }
            .padding(.bottom, 4)
            Text(width.label)
                .font(.callout.weight(selected ? .semibold : .medium))
            Text(width.descriptor)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 200)
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(width.label) content width")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, select)
    }
}

/// One selectable line-numbers card: the width cards' miniature-page idiom,
/// with or without block-start numbers in the margin. Both cards reserve
/// the number slot so the text column sits identically in each — the two
/// states read as equals, not as a default and a decoration.
struct LineNumberPreviewCard: View {
    let showNumbers: Bool
    let selected: Bool
    let select: () -> Void

    /// Miniature blocks: a heading and two prose paragraphs, numbered at
    /// their starting lines like the real gutter.
    private static let lines: [(width: CGFloat, height: CGFloat, emphasis: Bool, number: String?)] = [
        (0.42, 6, true, "1"),
        (1.0, 3.5, false, "3"), (0.97, 3.5, false, nil), (1.0, 3.5, false, nil),
        (0.88, 3.5, false, "7"), (1.0, 3.5, false, nil), (0.58, 3.5, false, nil),
    ]

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color(nsColor: .textBackgroundColor))
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(Self.lines.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .center, spacing: 5) {
                            Text(showNumbers ? (line.number ?? "") : "")
                                .font(.system(size: 7, design: .monospaced))
                                .foregroundStyle(.secondary.opacity(0.8))
                                // Sized to the bar, not the glyph, so the
                                // numbered miniature keeps the same row
                                // rhythm (and centering) as the bare one.
                                .frame(width: 12, height: line.height, alignment: .trailing)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(.secondary.opacity(line.emphasis ? 0.55 : 0.3))
                                .frame(width: max(10, 176 * 0.55 * line.width),
                                       height: line.height)
                        }
                    }
                }
            }
            .frame(width: 200, height: 108)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(selected ? Color.accentColor : Color(nsColor: .separatorColor),
                                  lineWidth: selected ? 2.5 : 1)
            )
            .overlay(alignment: .bottomTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color.white, Color.accentColor)
                        .background(Circle().fill(.white).padding(2))
                        .padding(7)
                }
            }
            .padding(.bottom, 4)
            Text(showNumbers ? String(localized: "Shown") : String(localized: "Hidden"))
                .font(.callout.weight(selected ? .semibold : .medium))
            Text(showNumbers ? String(localized: "Each block's source line in the margin") : String(localized: "A clean margin, numbers on demand in Source"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 200)
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(showNumbers ? Text("Line numbers shown") : Text("Line numbers hidden"))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, select)
    }
}

/// One selectable theme card: a miniature, non-interactive MarkdownWebView
/// rendering a fixed sample through the real pipeline with this theme
/// (built-in name and, for custom themes, the user CSS appended).
struct ThemePreviewCard: View {
    let title: String
    let descriptor: String
    let theme: String
    var customCSS: String?
    let selected: Bool
    let select: () -> Void

    /// Sample rendered through the diff pipeline so every card shows type,
    /// a link, code, and a green added-diff block in its theme's palette.
    private static let sampleSegments: [DiffSegmentPayload] = [
        DiffSegmentPayload(
            kind: "unchanged",
            text: "## Reading Notes\n\nA **quiet** page, an *aside*, and a [link](https://pullmark.app).",
            oldText: nil, lineStart: 1, lineEnd: 3, side: "RIGHT"),
        DiffSegmentPayload(
            kind: "unchanged",
            text: "```swift\nlet review = pr.render()\n```",
            oldText: nil, lineStart: 4, lineEnd: 6, side: "RIGHT"),
        DiffSegmentPayload(
            kind: "added",
            text: "This paragraph was added in the pull request.",
            oldText: nil, lineStart: 7, lineEnd: 7, side: "RIGHT"),
    ]

    private var previewHTML: String {
        HTMLBuilder.diffPage(segments: Self.sampleSegments,
                             commentable: false,
                             title: title,
                             theme: theme,
                             customCSS: customCSS,
                             preview: true)
    }

    var body: some View {
        VStack(spacing: 6) {
            MarkdownWebView(html: previewHTML, interactive: false)
                .frame(width: 200, height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(selected ? Color.accentColor : Color(nsColor: .separatorColor),
                                      lineWidth: selected ? 2.5 : 1)
                )
                .overlay(alignment: .bottomTrailing) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 18))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Color.white, Color.accentColor)
                            .background(Circle().fill(.white).padding(2))
                            .padding(7)
                    }
                }
                .padding(.bottom, 4)
            Text(title)
                .font(.callout.weight(selected ? .semibold : .medium))
            Text(descriptor)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 200)
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) theme")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, select)
    }
}

// MARK: - GitHub connection

/// The General tab's top section (spec: github-connection): whether
/// PullMark can talk to GitHub, as whom, and through which credential
/// source — with the recheck and the setup walkthrough one click away.
struct GitHubConnectionSection: View {
    @ObservedObject private var connection = GitHubClient.shared.connection
    @State private var showSetup = false
    @AppStorage(DefaultsKeys.githubLinkStyle, store: UserDefaults.pullmark)
    private var githubLinkStyleRaw = "branch"

    var body: some View {
        Section("GitHub") {
            LabeledContent("Connection:") {
                HStack(spacing: 10) {
                    statusLine
                    Spacer()
                    Button("Check Again") {
                        Task { await GitHubClient.shared.recheck() }
                    }
                    .disabled(connection.status == .checking)
                    .help("Re-read credentials from the GitHub CLI and git credential helpers — after gh auth login, this connects without relaunching")
                    Button("Set Up…") { showSetup = true }
                        .help("Walk through connecting PullMark to GitHub")
                }
            }
            .settingAnchor("github")

            Text("PullMark borrows the credentials your own tools already have — the GitHub CLI or a git credential helper. It has no login of its own, stores nothing, and never sees a password. [About GitHub access](https://pullmark.app/docs/troubleshooting/#github-access)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Copy GitHub links as:", selection: $githubLinkStyleRaw) {
                Text("Current branch").tag("branch")
                Text("Exact commit (permalink)").tag("commit")
            }
            .help("What Copy GitHub Link copies — hold ⌥ in the menu for the other flavor")
        }
        .sheet(isPresented: $showSetup) { GitHubSetupSheet() }
        .onAppear {
            // Settings can open before any API call has resolved the
            // token — never leave the row stuck on "Checking…".
            if connection.status == .checking {
                Task { await GitHubClient.shared.recheck() }
            }
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch connection.status {
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking…").foregroundStyle(.secondary)
            }
        case .connected(let login, let source):
            HStack(spacing: 6) {
                Circle().fill(.green).frame(width: 7, height: 7)
                Text(login.map { "Connected as \($0)" } ?? "Connected")
                Text("· \(source.label)")
                    .foregroundStyle(.secondary)
            }
        case .notConnected:
            // Just the fact: the top-of-tab alert and the footer below
            // both carry the consequence, and the row stays one line
            // like every other LabeledContent (design-review catch).
            HStack(spacing: 6) {
                Circle().fill(.orange).frame(width: 7, height: 7)
                Text("Not connected")
            }
        }
    }
}

/// The top-of-General alert (spec: github-connection, Josh's revision):
/// signed out is worth one loud line at the top of the tab, and the fix
/// is a jump away — it scrolls to the GitHub section rather than
/// duplicating its controls. Invisible while connected; sticky through
/// rechecks.
struct GitHubNotConnectedAlert: View {
    @ObservedObject private var connection = GitHubClient.shared.connection

    /// Sticky through rechecks via the model's settled verdict: a
    /// failed Check Again passes through .checking, and the alert
    /// vanishing-then-snapping-back would shift every row under the
    /// cursor (design-review catch). Only a real connect clears it.
    var body: some View {
        if connection.settledNotConnected {
            Section {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Not connected to GitHub — private repositories and reviewing are unavailable.")
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Show") {
                        SettingsAnchorFocus.shared.pending = "github"
                    }
                    .help("Jump to the GitHub connection section")
                }
            }
        }
    }
}
