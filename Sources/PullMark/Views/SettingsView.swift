import SwiftUI

/// The Settings window (⌘,): a General tab for appearance and behavior, and
/// a Themes tab whose live preview cards render a fixed sample document
/// through the real WKWebView pipeline, one per theme.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            ThemeSettingsTab()
                .tabItem { Label("Themes", systemImage: "paintpalette") }
        }
        .frame(width: 680)
    }
}

// MARK: - General

struct GeneralSettingsTab: View {
    @EnvironmentObject private var updates: UpdateChecker
    @EnvironmentObject private var defaultApp: DefaultAppManager
    @AppStorage(Appearance.defaultsKey) private var appearanceRaw = Appearance.system.rawValue
    @AppStorage(DefaultsKeys.diffLayout) private var diffLayoutRaw = PRFileView.DiffLayout.inline.rawValue
    @AppStorage(DefaultsKeys.qlRendered) private var qlRendered = true
    @AppStorage(DefaultsKeys.autosaveEdits) private var autosaveEdits = true
    @AppStorage(DefaultsKeys.inboxEnabled) private var inboxEnabled = true
    @AppStorage(DefaultsKeys.restoreSession) private var restoreSession = true
    @State private var updateStatus: String?
    @State private var checking = false

    var body: some View {
        Form {
            Section("Appearance") {
            Picker("Appearance:", selection: $appearanceRaw) {
                ForEach(Appearance.allCases) { appearance in
                    Text(appearance.label).tag(appearance.rawValue)
                }
            }
            .pickerStyle(.segmented)
            }

            Section("Reviewing") {
            Picker("Default diff layout:", selection: $diffLayoutRaw) {
                ForEach(PRFileView.DiffLayout.allCases) { layout in
                    Text(layout.rawValue).tag(layout.rawValue)
                }
            }
            .pickerStyle(.segmented)

            Picker("Quick Look previews:", selection: $qlRendered) {
                Text("Rendered").tag(true)
                Text("Raw Source").tag(false)
            }
            .pickerStyle(.segmented)
            .help("What pressing space in Finder shows for Markdown files")

            Toggle("Show review requests in the sidebar", isOn: $inboxEnabled)
                .help("Open pull requests where your review is requested")
            }

            Section("Reading") {
            Toggle("Restore files and pull requests from the last session", isOn: $restoreSession)
                .help("Reopen what was in the sidebar when PullMark last quit")
            }

            Section("Editing") {
            Picker("Saving edits:", selection: $autosaveEdits) {
                Text("Automatically").tag(true)
                Text("Manually (⌘S)").tag(false)
            }
            .pickerStyle(.segmented)
            .help("Automatic writes each edit to disk as you leave a block; Manual keeps edits in the window (dirty dot) until ⌘S — the editor's model")
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

            LabeledContent("Updates:") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Button("Check for Updates…") { check() }
                            .disabled(checking)
                        if checking {
                            ProgressView().controlSize(.small)
                        }
                    }
                    if let updateStatus {
                        Text(updateStatus)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            }
        }
        .formStyle(.grouped)
        .frame(height: 560)
        // The binding can change behind our back (Finder's "Change All…",
        // another app claiming it) — re-resolve whenever the tab shows.
        .onAppear { defaultApp.refresh() }
    }

    private func check() {
        checking = true
        updateStatus = nil
        Task {
            let message = await updates.checkManually()
            updateStatus = message ?? "Update available — see the banner in the main window."
            checking = false
        }
    }
}

// MARK: - Themes

struct ThemeSettingsTab: View {
    @AppStorage(Theme.defaultsKey) private var themeRaw = Theme.github.rawValue
    @State private var customNames: [String] = []

    private var selection: ThemeSelection {
        ThemeSelection.resolve(themeRaw, availableCustom: customNames)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
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
                Text("Themes restyle rendered Markdown and diffs, and follow the Light/Dark appearance. Drop .css files into the Themes folder to add your own — they apply on top of the GitHub look. Quick Look previews follow your theme too (custom themes fall back to their GitHub base there).")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
        }
        .frame(height: 540)
        .onAppear { customNames = CustomThemes.availableThemeNames() }
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
