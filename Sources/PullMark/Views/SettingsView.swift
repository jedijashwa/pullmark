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
        }
        .frame(width: 680)
    }
}

// MARK: - General

struct GeneralSettingsTab: View {
    @EnvironmentObject private var updates: UpdateChecker
    @EnvironmentObject private var defaultApp: DefaultAppManager
    @AppStorage(DefaultsKeys.diffLayout, store: UserDefaults.pullmark) private var diffLayoutRaw = PRFileView.DiffLayout.inline.rawValue
    @AppStorage(DefaultsKeys.qlRendered, store: UserDefaults.pullmark) private var qlRendered = true
    @AppStorage(DefaultsKeys.inboxEnabled, store: UserDefaults.pullmark) private var inboxEnabled = true
    @AppStorage(DefaultsKeys.inboxMarkdownOnly, store: UserDefaults.pullmark) private var inboxMarkdownOnly = true
    @AppStorage(DefaultsKeys.restoreSession, store: UserDefaults.pullmark) private var restoreSession = true
    @AppStorage(DefaultsKeys.remoteLinkPolicy, store: UserDefaults.pullmark) private var remoteLinkPolicyRaw = RemoteLinkPolicy.ask.rawValue
    @AppStorage(DefaultsKeys.folderClickAction, store: UserDefaults.pullmark) private var folderClickRaw = FolderClickAction.preview.rawValue
    @AppStorage(DefaultsKeys.marginNotesEnabled, store: UserDefaults.pullmark) private var marginNotesEnabled = false
    @AppStorage(DefaultsKeys.marginNoteAuthor, store: UserDefaults.pullmark) private var marginNoteAuthor = ""
    @AppStorage(DefaultsKeys.updateChannel, store: UserDefaults.pullmark) private var updateChannelRaw = UpdateChannel.stable.rawValue
    @State private var updateStatus: String?
    @State private var checking = false
    @State private var cliStatus = CLIInstaller.Status.unavailable
    @State private var cliError: String?
    /// The known-update What's New sheet, presented HERE — the banner's
    /// sheet lives on the main window, and Settings must not point at it.
    @State private var showAvailableNotes = false

    var body: some View {
        Form {
            Section("Reading") {
            Toggle("Restore files and pull requests from the last session", isOn: $restoreSession)
                .help("Reopen what was in the sidebar when PullMark last quit")

            Picker("GitHub Markdown links:", selection: $remoteLinkPolicyRaw) {
                Text("Ask on first click").tag(RemoteLinkPolicy.ask.rawValue)
                Text("Open in PullMark").tag(RemoteLinkPolicy.pullmark.rawValue)
                Text("Open in Browser").tag(RemoteLinkPolicy.browser.rawValue)
            }
            .help("What clicking a link to a Markdown file on GitHub does — hold ⌘ while clicking for the other behavior")

            Picker("Clicking files in Locations:", selection: $folderClickRaw) {
                Text("Preview First").tag(FolderClickAction.preview.rawValue)
                Text("Open Fully").tag(FolderClickAction.open.rawValue)
            }
            Text("Preview First shows a file with one click without keeping it — "
                + "one italicized entry (in Open Files, or under its GitHub repo) "
                + "that the next preview replaces. Double-click a file, or just "
                + "start editing, to keep it open. Open Fully keeps every file you click.")
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

            Toggle("Show review requests in the sidebar", isOn: $inboxEnabled)
                .help("Open pull requests where your review is requested")
            Toggle("Only requests that change Markdown", isOn: $inboxMarkdownOnly)
                .disabled(!inboxEnabled)
                .padding(.leading, 20)
                .help("Hide review requests with no Markdown files — PullMark has nothing to show for them")
            }

            Section("Updates") {
            Picker("Update channel:", selection: $updateChannelRaw) {
                ForEach(UpdateChannel.allCases) { channel in
                    Text(channel.label).tag(channel.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .help("Beta offers pre-release versions with features still being tested")
            if updateChannelRaw == UpdateChannel.beta.rawValue {
                Text("Beta versions are signed and notarized like any release, but "
                    + "their features are still settling — see pullmark.app/docs/beta.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

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
                }
            }

            Picker("Quick Look previews:", selection: $qlRendered) {
                Text("Rendered").tag(true)
                Text("Raw Source").tag(false)
            }
            .pickerStyle(.segmented)
            .help("What pressing space in Finder shows for Markdown files")
            }

            Section("Experimental") {
            Toggle("Margin notes", isOn: $marginNotesEnabled)
                .help("Comment on local Markdown documents the way you'd comment on a PR")
            Text("Notes save into the file itself as <!-- note @you: … --> "
                + "comments — invisible to every other tool, rendered by "
                + "PullMark as bubbles, and written so agents can read and "
                + "act on them. Turning this on adds the authoring tools "
                + "(hover a block, ⌥⌘M); documents that already contain "
                + "notes always show them either way. Details: "
                + "pullmark.app/docs/beta/margin-notes")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Sign notes as:", text: $marginNoteAuthor,
                      prompt: Text(NSUserName()))
                .disabled(!marginNotesEnabled)
                .padding(.leading, 20)
                .help("The @name your notes carry — empty uses your GitHub "
                    + "login, or this Mac's account name when signed out")
            }
        }
        .formStyle(.grouped)
        .frame(height: 560)
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
            ReleaseNotesSheet(
                title: "What's New in PullMark \(updates.availableVersion ?? "")",
                markdown: updates.availableNotes
            )
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Appearance")
                    .font(.headline)
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
            Text(showNumbers ? "Shown" : "Hidden")
                .font(.callout.weight(selected ? .semibold : .medium))
            Text(showNumbers ? "Each block's source line in the margin" : "A clean margin, numbers on demand in Source")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 200)
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(showNumbers ? "Line numbers shown" : "Line numbers hidden")
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
