import Foundation

/// Every UserDefaults key the app persists, in one place. All keys live in
/// the `app.pullmark.PullMark` defaults domain (see CLAUDE.md — the bundle
/// id must not change or these values are orphaned).
enum DefaultsKeys {
    /// Light/Dark/System override (`Appearance` raw value).
    static let appearance = "pm.appearance"
    /// Reading theme for rendered Markdown (`Theme` raw value).
    static let theme = "pm.theme"
    /// Default PR diff layout (`PRFileView.DiffLayout` raw value).
    static let diffLayout = "pm.diffLayout"
    /// Whether the outline sidebar is shown.
    static let outlinePanel = "pm.outlinePanel"
    /// Whether blame annotations are shown on rendered documents.
    static let blame = "pm.blame"
    /// JSON-encoded `[RecentItem]` (metadata only, no file contents).
    static let recents = "pm.recents"
    /// Update banner: version the user dismissed (never re-nag).
    static let dismissedUpdateVersion = "pm.dismissedUpdateVersion"
    /// Last app version that ran (drives the post-update What's New sheet).
    static let lastRunVersion = "pm.lastRunVersion"
    /// The user made PullMark the default Markdown app (drives the
    /// "no longer your default" banner when Launch Services loses the binding).
    static let claimedDefaultHandler = "pm.claimedDefaultHandler"
    /// DMG paths whose eject-and-trash offer the user declined (never re-ask).
    static let dmgCleanupDeclined = "pm.dmgCleanupDeclined"
    /// Quick Look previews render Markdown (true, default) or show the raw
    /// source (false). Mirrored into the shared app-group suite for the appex.
    static let qlRendered = "pm.qlRendered"
    /// Repo roots where the commit sheet should stop asking about
    /// committing directly to main/master.
    static let commitToMainAllowed = "pm.commitToMainAllowed"
    /// Commit sheet: also push to origin after a successful commit.
    static let pushAfterCommit = "pm.pushAfterCommit"
    /// Review-request inbox in the sidebar (default on; hidden when
    /// unauthenticated either way).
    static let inboxEnabled = "pm.inboxEnabled"
    /// Inbox unread tracking: PR id → updatedAt last seen.
    static let inboxSeen = "pm.inboxSeen"
    /// Inbox shows only PRs that touch Markdown (default on) — PullMark
    /// has nothing to render for the rest.
    static let inboxMarkdownOnly = "pm.inboxMarkdownOnly"
    /// Cached inbox Markdown-file counts (PR id → count) and the
    /// updatedAt each was computed for — placeholders that stop the
    /// inbox flashing unfiltered at launch and on refresh.
    static let inboxMDCounts = "pm.inboxMDCounts"
    static let inboxCountStamps = "pm.inboxCountStamps"
    /// Restore the previous session's files and PRs at launch (default on).
    static let restoreSession = "pm.restoreSession"
    /// Persisted session: local file paths + PR refs from last quit.
    static let sessionSnapshot = "pm.sessionSnapshot"
    /// Reading positions: document key → scroll fraction.
    static let readingPositions = "pm.readingPositions"
    /// JSON-encoded `ShortcutOverrides`: the user's keyboard customizations.
    static let shortcutOverrides = "pm.shortcutOverrides"
    /// Settings window: the last-selected tab ("general"/"themes"/"keyboard").
    static let settingsTab = "pm.settingsTab"
    /// Outline panel width in points (the HSplitView divider has no
    /// built-in persistence, unlike the sidebar column).
    static let outlineWidth = "pm.outlineWidth"
    /// A window was full screen at quit — SwiftUI restores frames but not
    /// full-screen state, so the app re-enters it manually at launch.
    static let windowWasFullScreen = "pm.windowWasFullScreen"
    /// Document magnification (WKWebView.pageZoom factor, 1.0 = actual
    /// size). App-wide: every document window reads at the same size.
    static let zoom = "pm.zoom"
    /// Pending review comments GitHub hasn't accepted yet (offline or API
    /// failure): JSON-encoded queues keyed by owner/repo#pr@headSHA — line
    /// anchors are only valid against the head they were authored on.
    static let pendingCommentQueues = "pm.pendingCommentQueues"
    /// In-progress review summary text keyed by owner/repo#pr; cleared when
    /// the review submits or is abandoned.
    static let pendingReviewSummaries = "pm.pendingReviewSummaries"
    /// Click-away drafts from the in-page comment composers, keyed by
    /// PR/head/file plus the page's own draft key — see ComposerDraftStore.
    static let composerDrafts = "pm.composerDrafts"
    /// Sidebar sections: expansion state (default expanded).
    /// What clicking a GitHub Markdown link does: RemoteLinkPolicy rawValue
    /// (absent = ask on first click).
    static let remoteLinkPolicy = "pm.remoteLinkPolicy"

    static let sidebarLocalExpanded = "pm.sidebar.localExpanded"
    static let sidebarGitHubExpanded = "pm.sidebar.githubExpanded"
    static let sidebarFoldersExpanded = "pm.sidebar.foldersExpanded"
    static let sidebarPRsExpanded = "pm.sidebar.prsExpanded"
    static let sidebarInboxExpanded = "pm.sidebar.inboxExpanded"
    static let sidebarRecentExpanded = "pm.sidebar.recentExpanded"
}
