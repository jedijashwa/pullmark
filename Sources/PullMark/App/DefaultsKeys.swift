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
    /// Restore the previous session's files and PRs at launch (default on).
    static let restoreSession = "pm.restoreSession"
    /// Persisted session: local file paths + PR refs from last quit.
    static let sessionSnapshot = "pm.sessionSnapshot"
    /// Reading positions: document key → scroll fraction.
    static let readingPositions = "pm.readingPositions"
}
