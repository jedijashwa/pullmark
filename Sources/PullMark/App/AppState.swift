import AppKit
import SwiftUI

struct LocalFile: Identifiable, Equatable {
    let url: URL
    let displayName: String
    /// Directory that relative images/links in this document resolve against
    /// (the containing folder, or the opened folder root).
    let resourceRoot: URL
    var id: URL { url }
}

struct PRSession: Identifiable {
    let ref: PullRequestRef
    var details: PullRequestDetails
    var mergeBaseSHA: String
    var files: [PullRequestFile]
    var reviewComments: [ReviewComment] = []
    var threadMeta: [Int: ThreadMeta] = [:]
    /// The viewer's pending review on GitHub — the source of truth. Nil
    /// when none exists (or the viewer is unauthenticated).
    var pendingReview: PendingReviewState?
    /// Comments authored here that GitHub hasn't accepted yet (offline or
    /// API failure) — persisted to disk, retried on sync. Always updated
    /// together with `pendingReview` so the unified list below and its
    /// per-row upload state can never disagree.
    var queuedComments: [PendingComment] = []
    /// The unified pending set the UI shows: server-accepted first, then
    /// the local queue, in authorship order within each.
    var pendingComments: [PendingComment] {
        (pendingReview?.comments ?? []) + queuedComments
    }
    /// Repo Markdown files opened via links from PR content (not part of the diff).
    var browsedDocs: [String] = []
    /// Set when the PR's head moved on GitHub since it was loaded.
    var updateAvailable = false
    /// Review comments/threads failed to load — the diff must not
    /// silently masquerade as an uncommented PR.
    var commentsUnavailable = false
    /// Where the PR stands (spec: pr-cockpit) — nil until the first
    /// cockpit fetch lands; the header renders no capsules meanwhile.
    /// Isolated from commentsUnavailable in both directions.
    var cockpit: PRCockpitState?
    /// The conversation timeline's raw inputs and GraphQL-only viewer
    /// state (reaction tints, node ids, edit signals).
    var issueComments: [IssueComment] = []
    var reviews: [PullRequestReview] = []
    var conversationMeta: [Int: ReviewCommentMeta] = [:]
    var reviewMeta: [Int: ReviewCommentMeta] = [:]
    var reviewReactions: [Int: ReactionRollup] = [:]
    /// The conversation failed to load and nothing older is on hand —
    /// the section shows one quiet retrying row.
    var conversationUnavailable = false
    /// ETag of the last single-page comments fetch: the quiet tick's
    /// 304s are free. Nil once the list spills past one page.
    var conversationETag: String?

    var id: String { "\(ref.owner)/\(ref.repo)#\(ref.number)" }
    var markdownFiles: [PullRequestFile] { files.filter(\.isMarkdown) }
    var otherFileCount: Int { files.count - markdownFiles.count }
}

/// A GitHub repo opened for reading outside any PR: documents opened from
/// links or ⌘K, plus an on-demand Markdown tree. `ref.number` is 0 — the
/// established "just a repo" shape (BlameService uses the same).
struct RemoteRepoSession: Identifiable {
    let ref: PullRequestRef
    /// The branch/tag/SHA exactly as the user's link spelled it — what the
    /// provenance bar displays.
    let displayRef: String
    /// Commit `displayRef` resolved to on first fetch. Nil until then —
    /// sessions restored from a snapshot stay unresolved so nothing touches
    /// the network at launch, only when a document is actually selected.
    var commitSHA: String?
    /// Documents opened via links or ⌘K, in open order.
    var docs: [String] = []
    /// Markdown paths of the full repo tree at `commitSHA` — fetched only
    /// when the user asks to browse (one recursive Trees API call).
    var treePaths: [String]?
    var treeTruncated = false
    var treeLoading = false

    var id: String { "\(ref.owner)/\(ref.repo)@\(displayRef)" }
}

/// What a click on a GitHub Markdown link does by default. `.ask` (the
/// initial state) presents a one-time choice that sets the default;
/// ⌘-click always inverts whatever the default is.
enum RemoteLinkPolicy: String {
    case ask
    case pullmark
    case browser
}

/// What a single click on a file inside a Location does. `.preview` (the
/// default) shows the file and keeps at most one transient, italicized
/// entry in Open Files; `.open` pins a full entry on every click.
enum FolderClickAction: String {
    case preview
    case open
}

/// A clicked GitHub link awaiting the user's first-click choice. Keeps the
/// original URL so "open in browser" preserves the link exactly.
struct RemoteLinkPrompt: Identifiable {
    let id = UUID()
    let link: RemoteDocLink
    let url: URL
}

/// A heading anchor to scroll to once a remote document finishes loading.
struct RemoteAnchorRequest: Equatable {
    let id = UUID()
    let sessionID: String
    let path: String
    let fragment: String
}

enum SidebarSelection: Hashable {
    case local(URL)
    /// An opened folder root (spec §1) — selecting it shows the folder
    /// placeholder; a file is only selected when the user picks one.
    case folder(URL)
    /// A directory row inside a folder tree: (root, relative path).
    /// Selectable so ←/→ keyboard tree navigation works (spec §8.1).
    case folderNode(URL, String)
    case prOverview(String)
    case prFile(String, String)
    /// A repo document browsed from PR content: (session id, repo path).
    case prDoc(String, String)
    /// A GitHub repo session's root row: (session id).
    case remoteRepo(String)
    /// A document in a GitHub repo session: (session id, repo path).
    case remoteDoc(String, String)
    /// Review Request and Recents rows participate in selection and
    /// keyboard navigation (spec §1); opening happens on click/Return,
    /// not on arrow-selection.
    case inboxItem(String)
    case recentItem(String)
}

struct MessageError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// The document-shaped content currently frontmost in the detail area (a
/// local file, a PR file's Result view, or a browsed repo doc). Registered
/// by the detail views so app-level menu commands (Export as PDF/HTML, Copy
/// as Markdown) can reach the live web view and the original markdown
/// source. Diff views and the PR overview never register — those commands
/// are document-only (v1).
struct ActiveDocument {
    /// Registration identity, so a disappearing view only unregisters itself.
    let id: String
    /// Suggested export file basename (source file name without extension).
    let exportBaseName: String
    /// The original markdown source backing the rendered page.
    let markdown: String
    /// Handle on the live web view rendering the document.
    let proxy: WebViewProxy
    /// Root for pullmark-local image resolution (local files only).
    var localRoot: URL?
    /// Context for pullmark-remote image resolution (PR content only).
    var remoteContext: RemoteResourceContext?
}

/// What the window-level customizable toolbar needs from the active detail
/// surface. Toolbar items live on the window (ContentView) because SwiftUI
/// only persists customization for window-level `.toolbar(id:)` items —
/// detail-hosted ones are re-merged fresh at every launch, resurrecting
/// anything the user removed (verified live). Views register this the way
/// they register ActiveDocument; value fields drive the items' on/off and
/// enabled states, closures reach back into the registering view's own
/// state. Closures capture the view struct, so they read live @State —
/// re-registration is only needed when a *value* field changes.
struct SurfaceToolbar {
    enum Kind {
        case localFile
        case remoteDoc
        case prFile
        case prDoc
        case prOverview
    }

    /// Which surface these values belong to — must equal the id
    /// AppState.surfaceExpectation derives for the same document, or the
    /// registration is ignored as stale. (Structure — which items exist —
    /// derives from surfaceExpectation's kind, never from here.)
    let id: String

    /// Share target: the local file URL, the PR's html page, or the
    /// document's canonical github.com blob page — never a raw URL.
    var shareURL: URL?

    // Local file: edit mode.
    var editMode = false
    var editDisabled = false
    var setEditMode: ((Bool) -> Void)?

    // Compare (local + remote): the view builds its NSMenu from live git
    // state at click time and pops it on the toolbar button's anchor.
    var compareAvailable = false
    var compareUnavailableReason: String?
    var popCompare: ((NSView) -> Void)?
    /// A comparison is on screen — flips the View-menu item to Stop.
    var comparing = false
    /// Git-backed comparisons work here (repo with history) — gates the
    /// View-menu item; the button itself stays enabled for local files
    /// because Compare with File… works without git.
    var compareGitAvailable = false
    /// The working file differs from HEAD — the button's quiet dot.
    var compareHasChanges = false

    // Blame: visibility itself is the global AppStorage toggle; the
    // surface only says whether blame exists here at all, and whether the
    // toggle is momentarily disabled (a local file mid-comparison).
    var blameAvailable = false
    var blameDisabled = false

    // Margin notes (local files): the button is pointless while the page
    // shows something that isn't the document (comparison, source view).
    var marginNoteDisabled = false

    // Remote docs: reload re-resolves the branch; a session opened at a
    // specific commit has nothing to re-resolve.
    var reloadDisabledReason: String?

    // PR file: the Rendered Diff / Source Diff / Result mode picker, by
    // raw value so the view keeps its Mode enum private.
    var modeOptions: [String] = []
    var mode: String?
    var setMode: ((String) -> Void)?

    // PR file: the Inline / Side by Side layout picker (the value is the
    // global AppStorage; the surface controls presence and disabling).
    var showsLayout = false
    var layoutDisabledReason: String?
}

/// A recently opened file, folder, or pull request. Persisted (metadata only)
/// in UserDefaults.
struct RecentItem: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        case file
        case folder
        case pr
    }

    var kind: Kind
    var path: String?
    var owner: String?
    var repo: String?
    var number: Int?
    var title: String
    var prStatus: PRStatus?
    var lastOpened: Date

    var id: String {
        switch kind {
        case .file: return "file:" + (path ?? "")
        case .folder: return "folder:" + (path ?? "")
        case .pr: return "pr:\(owner ?? "")/\(repo ?? "")#\(number ?? 0)"
        }
    }

    var ref: PullRequestRef? {
        guard kind == .pr, let owner, let repo, let number else { return nil }
        return PullRequestRef(owner: owner, repo: repo, number: number)
    }
}

/// Menu commands that act on state owned by a detail view rather than by
/// AppState — the view performs them when they arrive.
enum DocumentCommand: Equatable {
    case reload
    case toggleEditMode
    case findNext
    case findPrevious
    case showRenderedDiff
    case showSourceDiff
    case showResult
    case flipDiffLayout
    /// Opens the review popover on the active PR surface (spec §3).
    case reviewChanges
    /// Margin notes (beta): the composer on the block the reader is on,
    /// and the file-level variant at the top of the document.
    case addMarginNote
    case addFileMarginNote
    /// Opens the whole-file comment sheet on the active PR file.
    case commentOnFile
    /// View → Compare with Last Commit / Stop Comparing (local files).
    case toggleCompare
}

struct DocumentCommandRequest: Equatable {
    let id = UUID()
    let command: DocumentCommand
}

@MainActor
final class AppState: ObservableObject {
    @Published var localFiles: [LocalFile] = [] {
        didSet { scheduleNoteTracking() }
    }
    /// Opened folder roots (spec §1) — closeable places with trees,
    /// alongside the individually opened documents in `localFiles`.
    @Published var folders: [LocalFolder] = []
    @Published var prSessions: [PRSession] = []
    @Published var remoteSessions: [RemoteRepoSession] = []
    /// Set when a GitHub link is clicked while the policy is still `.ask` —
    /// drives the one-time choice alert.
    @Published var remoteLinkPrompt: RemoteLinkPrompt?
    /// Anchor scroll handed to the remote doc view once its page loads.
    @Published var remoteAnchor: RemoteAnchorRequest?
    /// The transient working-set entry (at most ONE per window, local or
    /// remote): the file last single-clicked in a Location, shown
    /// italicized where it belongs — the end of Open Files for local
    /// files, the session's docs area for remote docs. Replaced by the
    /// next preview, promoted by double-click, Keep Open, or (locally)
    /// any authoring interaction.
    enum PreviewEntry: Equatable {
        case local(LocalFile)
        case remote(sessionID: String, path: String)
    }
    @Published var preview: PreviewEntry? {
        didSet { scheduleNoteTracking() }
    }

    /// Margin-note counts for the working set (file path → count) — the
    /// Open Files bubble chips. Kept live by per-file watchers so an
    /// agent working through a document's notes updates the chip as it
    /// deletes them.
    @Published var marginNoteCounts: [String: Int] = [:]
    private var noteWatchers: [String: FileWatcher] = [:]

    /// Deferred: the triggering didSet runs mid-publish, and tracking
    /// publishes marginNoteCounts changes of its own.
    private func scheduleNoteTracking() {
        Task { @MainActor [weak self] in self?.syncNoteTracking() }
    }

    private func syncNoteTracking() {
        var wanted: [String: URL] = [:]
        for file in localFiles { wanted[file.url.path] = file.url }
        if case .local(let file) = preview { wanted[file.url.path] = file.url }
        for path in noteWatchers.keys where wanted[path] == nil {
            noteWatchers[path] = nil
            marginNoteCounts[path] = nil
        }
        for (path, url) in wanted where noteWatchers[path] == nil {
            noteWatchers[path] = FileWatcher(url: url) { [weak self] in
                self?.refreshNoteCount(url: url)
            }
            refreshNoteCount(url: url)
        }
    }

    private func refreshNoteCount(url: URL) {
        Task.detached(priority: .utility) { [weak self] in
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let count = MarginNotes.count(in: text)
            // Rebound to a `let` so the MainActor closure captures an
            // immutable reference (weak `self` is a var — a Swift 6 error).
            guard let self else { return }
            await MainActor.run { self.marginNoteCounts[url.path] = count }
        }
    }

    /// The local preview, when that's what the preview is — what the Open
    /// Files section renders.
    var previewFile: LocalFile? {
        if case .local(let file) = preview { return file }
        return nil
    }
    /// A review thread to reveal once its file's rendered-diff page
    /// loads — set by the overview's View in File jump (spec:
    /// pr-review-discussion), consumed by PRFileView.
    struct ThreadReveal: Equatable {
        let sessionID: String
        let path: String
        let rootID: Int
    }
    @Published var pendingThreadReveal: ThreadReveal?

    /// Compare requests from pullmark://compare deep links (the CLI's
    /// --diff/--diff-with flags), keyed by standardized file path and
    /// consumed by the file's view when it shows. A dictionary, not a
    /// slot: one invocation may ask for several files diffed, and each
    /// entry belongs to its file however long the view takes to appear.
    @Published var pendingCompares: [String: AppLinks.CompareRequest] = [:]

    @Published var selection: SidebarSelection? {
        didSet {
            guard selection != oldValue else { return }
            // A pending View-in-File reveal is only valid on the way to
            // its file; navigating anywhere else retires it — a stale
            // reveal would scroll-jump an unrelated visit minutes later.
            if let reveal = pendingThreadReveal,
               selection != .prFile(reveal.sessionID, reveal.path) {
                pendingThreadReveal = nil
            }
            let current = selection
            // Deferred: the binding writes during event handling, and this
            // may publish localFiles/previewFile changes in response.
            Task { @MainActor [weak self] in self?.reactToSelection(current) }
        }
    }
    /// File/folder recents whose paths currently don't resolve — dimmed
    /// in the sidebar, revived automatically when the path returns
    /// (spec §6). Recomputed on app activation and window open.
    @Published var missingRecentIDs: Set<String> = []
    /// A dead recent the user clicked: presents the quiet notice with a
    /// Remove from Recents action instead of the old error-and-purge.
    @Published var deadRecent: RecentItem?
    @Published var showAddPR = false
    @Published var lastError: String?
    /// The native media inspector (click an image/diagram/formula).
    @Published var lightbox: LightboxContent?
    /// Informational, non-error messages ("no Markdown files here") — shown
    /// as a plain notice, never behind the "Something went wrong" title.
    @Published var lastNotice: String?
    /// Transient "Show Markdown Source" (⌥⌘U): flips the active document
    /// view to the raw text. Deliberately not persisted — reading stays the
    /// default on every launch.
    @Published var sourceViewVisible = false
    /// Show Resolved Conversations (Result-view thread markers, spec §1).
    /// Transient and default-off — resolved threads leave the reading
    /// surface on every launch; the in-page control and the View menu item
    /// mirror each other through this flag.
    @Published var resolvedConversationsVisible = false
    /// ⌘K Open Quickly palette.
    @Published var openQuicklyVisible = false
    /// Presents the commit sheet for a repo root (File → Commit Changes…).
    @Published var commitRequest: CommitRequest?
    /// Bumped after an in-app commit lands. Views holding git-derived state
    /// (compare menus, blame, titlebar branch) reload on change — a commit
    /// alters history without touching the file, so file watchers miss it.
    @Published var gitStateTick = 0
    @Published var findBarVisible = false
    /// The authenticated GitHub login, published for synchronous use by
    /// payload building (author-gating the ⋯ menu, tinting reaction
    /// chips). Set whenever identity resolution succeeds; nil gates all
    /// viewer-relative affordances off.
    @Published private(set) var viewerLogin: String?
    @Published var recents: [RecentItem] = []
    @Published var searchPaletteVisible = false
    /// Query handed from the search palette to the detail view it opened;
    /// consumed once (the view drives find-in-page with it after its page
    /// loads, so the term is highlighted and scrolled into view).
    @Published var pendingSearchQuery: String?
    /// See ActiveDocument; nil while a diff, the PR overview, or the empty
    /// placeholder is frontmost (export/copy menu items disable themselves).
    @Published var activeDocument: ActiveDocument?
    /// The most recent SurfaceToolbar registration. Never cleared (see
    /// registerSurfaceToolbar) — read through expectedSurfaceToolbar,
    /// which id-gates it against the surface actually on screen.
    @Published var surfaceToolbar: SurfaceToolbar?
    /// A menu command aimed at whichever detail view is on screen. Menus
    /// live at app level but these act on per-view state, so the command
    /// is posted here and the view that owns the state performs it.
    /// Carries an id so repeating the same command still fires.
    @Published var documentCommand: DocumentCommandRequest?

    /// Posts a command to the detail view and lets it clear the slot.
    func send(_ command: DocumentCommand) {
        documentCommand = DocumentCommandRequest(command: command)
    }

    /// Consumes the pending command if it is one this view handles.
    func take(_ command: DocumentCommand) -> Bool {
        guard documentCommand?.command == command else { return false }
        documentCommand = nil
        return true
    }

    let client = GitHubClient.shared

    /// One per window (like AppState itself): connects the window-level
    /// review toolbar button to whichever PR surface presents the review
    /// popover, so the popover's arrow can point at the actual button.
    let reviewAnchor = ReviewAnchorTracker()

    private static let recentsKey = DefaultsKeys.recents
    private static let recentsLimit = 12

    private var updateTimer: Timer?

    /// The key window's AppState: external opens (Finder, CLI, dock drops)
    /// land in the frontmost window now that each window owns its state.
    /// ContentView updates this as windows gain key status.
    static weak var keyInstance: AppState?

    /// Cross-window dedup: opens can arrive through both the scene's
    /// onOpenURL and the app delegate's router path, and with per-window
    /// states those may target different windows. First path in wins;
    /// the duplicate within the window is swallowed.
    private static var recentOpens: [URL: Date] = [:]
    static func gateOpen(_ url: URL) -> Bool {
        let now = Date()
        recentOpens = recentOpens.filter { now.timeIntervalSince($0.value) < 2 }
        guard recentOpens[url] == nil else { return false }
        recentOpens[url] = now
        return true
    }

    /// Router delivery with a retry buffer: keyInstance is weak and goes
    /// nil between a key window closing and the next one keying — an open
    /// landing in that gap would otherwise be silently dropped.
    static func deliverExternalOpens(_ urls: [URL], retries: Int = 20) {
        if let instance = keyInstance {
            for url in urls where gateOpen(url) { instance.add(url: url) }
        } else if retries > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                deliverExternalOpens(urls, retries: retries - 1)
            }
        }
    }

    /// A compare deep link: open the file and mark it for comparing.
    /// Retries like document opens do, but with a 10-second budget — a
    /// COLD launch (WebKit warmup plus session restore) takes well past
    /// the 2 seconds documents need, and exhausting the budget dropped
    /// the request silently (verified live). The pending entry is set
    /// before add(url:) so the view can't appear ahead of its request,
    /// and deliberately skips the open dedup gate: "open plain, then
    /// open diffed" within two seconds is a real sequence, not a bounce.
    static func deliverCompareOpen(file: URL, request: AppLinks.CompareRequest,
                                   retries: Int = 100) {
        if let instance = keyInstance {
            instance.pendingCompares[file.standardizedFileURL.path] = request
            instance.add(url: file)
        } else if retries > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                deliverCompareOpen(file: file, request: request, retries: retries - 1)
            }
        }
    }

    init() {
        if Self.keyInstance == nil { Self.keyInstance = self }
        OpenURLRouter.shared.onOpen { urls in
            Task { @MainActor in AppState.deliverExternalOpens(urls) }
        }
        // Command-line arguments, in case this state is created before the
        // app delegate finished launching (or vice versa).
        Task { @MainActor [weak self] in
            for url in LaunchArguments.consumeFileURLs() { self?.add(url: url) }
        }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.checkForPRUpdates()
                await self?.refreshCockpitIfDue()
                await self?.refreshInboxIfDue()
            }
        }
        // Recents truth + folder-root revival on every return to the app
        // (spec §6) — a cheap existence pass, no watchers on recents.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.validateSidebarPaths() }
        }
        // Demo launches (PM_DEMO=1) fabricate their session below and show
        // nothing real — no recents, no inbox, no restore.
        if !DemoMode.active {
            loadRecents()
            loadInboxCounts()
        }
        Task { @MainActor [weak self] in
            // Brief grace so launch-time opens (CLI, Finder) land first —
            // restore skips itself when anything is already open.
            try? await Task.sleep(nanoseconds: 300_000_000)
            if DemoMode.active {
                self?.installDemoSessionIfNeeded()
            } else {
                self?.restoreSessionIfWanted()
                await self?.refreshInboxIfDue()
            }
        }
    }

    // MARK: - Demo mode (PM_DEMO=1)

    /// Fabricates the curated demo session directly — the same shape
    /// `addPR` builds from live responses, but entirely offline (see
    /// DemoSession for the content and DemoMode for the persistence
    /// seam). First window only, and only while it is still empty,
    /// mirroring the session-restore rules.
    private func installDemoSessionIfNeeded() {
        guard Self.keyInstance === self, localFiles.isEmpty, prSessions.isEmpty
        else { return }
        localFiles = DemoSession.installLocalDocs()
        let session = DemoSession.makeSession()
        viewerLogin = DemoSession.viewerLogin
        adoptionKnown.insert(session.id)
        prSessions = [session]
        selection = .prOverview(session.id)
    }

    // MARK: - Review-request inbox

    @Published var inbox: [GitHubClient.InboxPR] = []
    /// Markdown-file counts per inbox id, cached per update stamp.
    /// Markdown-file counts keyed by PR id. A count from a previous
    /// updatedAt keeps serving as a placeholder while the refresh
    /// re-counts — invalidating on every activity bump made the whole
    /// inbox flash unfiltered for a beat. Persisted so launches don't
    /// flash either.
    @Published var inboxMDCounts: [String: Int] = [:]
    /// id → the updatedAt the count was computed for.
    private var inboxCountStamps: [String: String] = [:]
    private var lastInboxRefresh: Date?

    var inboxEnabled: Bool {
        UserDefaults.pullmark.object(forKey: DefaultsKeys.inboxEnabled) as? Bool ?? true
    }

    /// Search-API rate limits are tight (30/min): refresh at most every
    /// five minutes, quietly — an inbox should never produce error alerts.
    func refreshInboxIfDue() async {
        // Only the key window polls — N windows sharing one rate limit
        // would multiply identical searches for identical results.
        // Demo mode never polls: the fixture is the whole world.
        guard !DemoMode.active, inboxEnabled, Self.keyInstance === self else { return }
        if let last = lastInboxRefresh, Date().timeIntervalSince(last) < 300 { return }
        lastInboxRefresh = Date()
        guard let items = try? await client.reviewRequests() else { return }
        // Counts FIRST, list after, published together: the visible list
        // must never show an item its filter hasn't judged yet — that
        // was the flash of unfiltered requests on every refresh. Counts
        // from an older updatedAt serve as placeholders (top 15 counted;
        // the long tail shows uncounted by design).
        let liveIDs = Set(items.map(\.id))
        var counts = inboxMDCounts.filter { liveIDs.contains($0.key) }
        var stamps = inboxCountStamps.filter { liveIDs.contains($0.key) }
        for item in items.prefix(15) where stamps[item.id] != item.updatedAt {
            if let count = try? await client.markdownFileCount(item.ref) {
                counts[item.id] = count
                stamps[item.id] = item.updatedAt
            }
        }
        inboxMDCounts = counts
        inboxCountStamps = stamps
        inbox = items
        persistInboxCounts()
    }

    func inboxMDCount(_ item: GitHubClient.InboxPR) -> Int? {
        inboxMDCounts[item.id]
    }

    private func persistInboxCounts() {
        UserDefaults.pullmark.set(inboxMDCounts, forKey: DefaultsKeys.inboxMDCounts)
        UserDefaults.pullmark.set(inboxCountStamps, forKey: DefaultsKeys.inboxCountStamps)
    }

    func loadInboxCounts() {
        let defaults = UserDefaults.pullmark
        if let counts = defaults.dictionary(forKey: DefaultsKeys.inboxMDCounts) as? [String: Int] {
            inboxMDCounts = counts
        }
        if let stamps = defaults.dictionary(forKey: DefaultsKeys.inboxCountStamps) as? [String: String] {
            inboxCountStamps = stamps
        }
    }

    func inboxIsUnread(_ item: GitHubClient.InboxPR) -> Bool {
        let seen = UserDefaults.pullmark.dictionary(forKey: DefaultsKeys.inboxSeen) as? [String: String]
        return seen?[item.id] != item.updatedAt
    }

    func openInboxItem(_ item: GitHubClient.InboxPR) {
        var seen = UserDefaults.pullmark.dictionary(forKey: DefaultsKeys.inboxSeen) as? [String: String] ?? [:]
        seen[item.id] = item.updatedAt
        // Bounded, but never pruned against the current (single-page) inbox
        // — that resurrected read state for anything briefly absent.
        if seen.count > 200 {
            let live = Set(inbox.map(\.id))
            for key in seen.keys where !live.contains(key) {
                seen[key] = nil
                if seen.count <= 200 { break }
            }
        }
        UserDefaults.pullmark.set(seen, forKey: DefaultsKeys.inboxSeen)
        objectWillChange.send()
        Task {
            do {
                try await addPR("\(item.ref.owner)/\(item.ref.repo)#\(item.ref.number)")
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    // MARK: - Session restore

    /// Files and PRs reopen where you left off (Settings-controlled,
    /// default on). Snapshots are written at quit and when the key window
    /// closes; restore is skipped when the app was launched to open
    /// something specific.
    /// PRs from the previous snapshot that haven't (re)opened yet — kept in
    /// every new snapshot so an offline launch can't erase them.
    private var pendingRestorePRs: Set<String> = []

    /// Snapshot v2 (spec: session restore): folder ROOTS with their view
    /// modes and expansion — not the flattened file list, so files added
    /// while the app was closed appear on relaunch. Array order is the
    /// manual order. The v1 dictionary format migrates on read.
    private struct SessionSnapshot: Codable {
        struct Folder: Codable {
            var path: String
            var viewMode: LocalFolder.ViewMode
            var expanded: [String]
        }
        struct RemoteRepo: Codable {
            var owner: String
            var repo: String
            var ref: String
            var docs: [String]
        }
        var files: [String]
        var folders: [Folder]
        var prs: [String]
        /// Optional so pre-0.26 snapshots (and pre-0.26 apps reading newer
        /// snapshots) keep decoding. Refs restore unresolved — the SHA is
        /// re-resolved on first selection, never at launch.
        var remotes: [RemoteRepo]? = nil
        /// The transient preview entry's path — restored still-as-preview,
        /// so a reading position doesn't silently harden into a pin.
        var preview: String? = nil
        /// Its remote twin: (session id, repo path). At most one of the
        /// two preview fields is set.
        struct RemotePreview: Codable {
            var session: String
            var path: String
        }
        var remotePreview: RemotePreview? = nil
    }

    func snapshotSession() {
        let openPRs = prSessions.map { "\($0.ref.owner)/\($0.ref.repo)#\($0.ref.number)" }
        let snapshot = SessionSnapshot(
            files: localFiles.map(\.url.path),
            folders: folders.map {
                .init(path: $0.rootURL.path, viewMode: $0.viewMode,
                      expanded: Array($0.expandedPaths))
            },
            prs: openPRs + pendingRestorePRs.filter { !openPRs.contains($0) },
            remotes: remoteSessions.map {
                .init(owner: $0.ref.owner, repo: $0.ref.repo, ref: $0.displayRef, docs: $0.docs)
            },
            preview: previewFile?.url.path,
            remotePreview: {
                if case .remote(let sessionID, let path) = preview {
                    return .init(session: sessionID, path: path)
                }
                return nil
            }())
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.pullmark.set(data, forKey: DefaultsKeys.sessionSnapshot)
        }
    }

    /// The stored snapshot in v2 form: decodes v2 data, else migrates the
    /// v1 dictionary (flat file list — no way to tell folder-scanned
    /// files apart, so they all land in Files, per spec).
    private static func loadSnapshot() -> SessionSnapshot? {
        if let data = UserDefaults.pullmark.data(forKey: DefaultsKeys.sessionSnapshot),
           let snapshot = try? JSONDecoder().decode(SessionSnapshot.self, from: data) {
            return snapshot
        }
        if let legacy = UserDefaults.pullmark.dictionary(forKey: DefaultsKeys.sessionSnapshot)
            as? [String: [String]] {
            return SessionSnapshot(files: legacy["files"] ?? [], folders: [],
                                   prs: legacy["prs"] ?? [])
        }
        return nil
    }

    private func restoreSessionIfWanted() {
        // Only the first window restores — ⌘N must open EMPTY windows,
        // not clones of the last session.
        guard Self.keyInstance === self,
              UserDefaults.pullmark.object(forKey: DefaultsKeys.restoreSession) as? Bool ?? true,
              localFiles.isEmpty, folders.isEmpty, prSessions.isEmpty, remoteSessions.isEmpty,
              let snapshot = Self.loadSnapshot()
        else { return }
        for saved in snapshot.remotes ?? [] {
            var session = RemoteRepoSession(
                ref: PullRequestRef(owner: saved.owner, repo: saved.repo, number: 0),
                displayRef: saved.ref)
            session.docs = saved.docs
            remoteSessions.append(session)
        }
        for path in snapshot.files where FileManager.default.fileExists(atPath: path) {
            add(url: URL(fileURLWithPath: path))
        }
        for saved in snapshot.folders {
            let root = URL(fileURLWithPath: saved.path)
            var folder = LocalFolder(rootURL: root)
            folder.viewMode = saved.viewMode
            folder.expandedPaths = Set(saved.expanded)
            folder.scanning = true
            // A missing root restores dimmed rather than vanishing —
            // rescan marks it missing and later activation revives it.
            folders.append(folder)
            watchFolder(root)
            rescanFolder(root: root)
        }
        if let saved = snapshot.remotePreview,
           remoteSessions.contains(where: { $0.id == saved.session }) {
            preview = .remote(sessionID: saved.session, path: saved.path)
        } else if let path = snapshot.preview, FileManager.default.fileExists(atPath: path),
                  let file = treeFile(for: URL(fileURLWithPath: path)) {
            // Folders are appended above (trees still scanning), so the
            // prefix check treeFile needs already answers.
            preview = .local(file)
        }
        selection = nil
        pendingRestorePRs = Set(snapshot.prs)
        for pr in pendingRestorePRs {
            Task { [weak self] in
                do {
                    try await self?.addPR(pr)
                    self?.pendingRestorePRs.remove(pr)
                } catch {
                    // Kept pending: the next snapshot still lists it, so a
                    // failed (offline) restore never erases the PR.
                }
            }
        }
    }

    deinit {
        updateTimer?.invalidate()
    }

    // MARK: - Active document

    func registerActiveDocument(_ document: ActiveDocument) {
        activeDocument = document
    }

    /// Views unregister by id on disappear; the guard keeps a stale
    /// onDisappear (fired after the next view already registered) from
    /// clobbering the new registration.
    func unregisterActiveDocument(id: String) {
        if activeDocument?.id == id { activeDocument = nil }
    }

    /// Overwrite-only, and deliberately WITHOUT an unregister: SwiftUI can
    /// spawn two incarnations of a surface where the SURVIVOR registers
    /// first and a doomed clone registers (and disappears) after — no
    /// lifecycle-based guard can tell who survives, so any clearing path
    /// eventually clears a live registration (caught in the wild three
    /// different ways). Stale registrations are inert instead: the toolbar
    /// derives its STRUCTURE from `surfaceExpectation` and only reads
    /// these values when the registered id matches the expected one.
    ///
    /// The publish is deferred a tick because onAppear/onChange run inside
    /// SwiftUI's render transaction, where a @Published write updates the
    /// value but can silently drop the re-render.
    func registerSurfaceToolbar(_ surface: SurfaceToolbar) {
        DispatchQueue.main.async { [weak self] in
            self?.surfaceToolbar = surface
        }
    }

    /// What surface the detail area is showing, derived from the same
    /// model state DetailView dispatches on — its switch and this one must
    /// agree branch for branch. This drives the window toolbar's
    /// structure (which items exist, which arrangement identity applies):
    /// pure derivation is transactionally consistent with the selection,
    /// where view-lifecycle registration provably is not.
    var surfaceExpectation: (kind: SurfaceToolbar.Kind, id: String)? {
        switch selection {
        case nil, .inboxItem, .recentItem:
            return nil
        case .local(let url):
            guard localFile(for: url) != nil else { return nil }
            return (.localFile, "local:" + url.path)
        case .folder(let root):
            guard let folder = folder(for: root), !folder.missing,
                  let readme = PathTree.readmePath(in: folder.filePaths),
                  localFile(for: folder.fileURL(for: readme)) != nil else { return nil }
            return (.localFile, "local:" + folder.fileURL(for: readme).path)
        case .folderNode(let root, let path):
            guard let folder = folder(for: root),
                  let readme = PathTree.readmePath(in: folder.filePaths, directory: path),
                  localFile(for: folder.fileURL(for: readme)) != nil else { return nil }
            return (.localFile, "local:" + folder.fileURL(for: readme).path)
        case .prOverview(let id):
            guard session(id) != nil else { return nil }
            return (.prOverview, "prOverview:" + id)
        case .prFile(let id, let path):
            guard session(id) != nil else { return nil }
            return (.prFile, "prFile:" + id + "|" + path)
        case .prDoc(let id, let path):
            guard session(id) != nil else { return nil }
            return (.prDoc, "prDoc:" + id + "|" + path)
        case .remoteRepo(let id):
            guard let session = remoteSession(id),
                  let readme = session.treePaths.flatMap({ PathTree.readmePath(in: $0) })
                      ?? PathTree.readmePath(in: session.docs) else { return nil }
            return (.remoteDoc, "remoteDoc:" + id + "|" + readme)
        case .remoteDoc(let id, let path):
            guard remoteSession(id) != nil else { return nil }
            return (.remoteDoc, "remoteDoc:" + id + "|" + path)
        }
    }

    /// The registered values, but only when they belong to the surface the
    /// detail area is actually showing — a stale registration for anything
    /// else reads as nil and items fall back to safe defaults until the
    /// live view's next update lands. One known soft spot: ids are
    /// per-document, not per-incarnation, so returning to a document whose
    /// dead view registered last serves that incarnation's closures for a
    /// tick until the fresh onAppear registration overwrites them — a
    /// toolbar click in that window no-ops against discarded state, then
    /// self-heals.
    var expectedSurfaceToolbar: SurfaceToolbar? {
        guard let surfaceToolbar, surfaceToolbar.id == surfaceExpectation?.id else {
            return nil
        }
        return surfaceToolbar
    }

    // MARK: - Local files

    func openFileOrFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Open Markdown files or a folder containing them"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { add(url: url) }
    }

    /// Empty-state buttons (spec §8.4) offer the two opens separately.
    func openFilesPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "Open Markdown files"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { add(url: url) }
    }

    func openFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Open a folder containing Markdown files"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { add(url: url) }
    }

    /// The local URL the selection points at — drives the File menu's
    /// Reveal in Finder and Copy Path commands.
    var selectionLocalURL: URL? {
        switch selection {
        case .local(let url): return url
        case .folder(let root): return root
        case .folderNode(let root, let path):
            return folder(for: root)?.fileURL(for: path)
        default: return nil
        }
    }

    /// The folder root the selection lives in (Refresh Folder's target).
    var selectionFolderRoot: URL? {
        switch selection {
        case .folder(let root), .folderNode(let root, _):
            return root
        case .local(let url):
            return folders.first { url.path.hasPrefix($0.rootURL.path + "/") }?.rootURL
        default:
            return nil
        }
    }

    /// ⌫ on the selected sidebar item (spec §4): the same non-destructive
    /// removal as the context menus, only for removable top-level items.
    func removeSelectedSidebarItem() {
        switch selection {
        case .local(let url):
            // Only ad-hoc Files rows remove; tree files are contents of a
            // place, not removable items.
            if let file = localFiles.first(where: { $0.url == url }) {
                removeLocalFile(file)
            }
        case .folder(let root):
            removeFolder(root)
        case .prOverview(let id):
            removePR(id)
        case .remoteRepo(let id):
            removeRemoteSession(id)
        case .recentItem(let id):
            removeRecent(id: id)
        default:
            break
        }
    }

    func add(url: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return }
        if isDirectory.boolValue {
            addFolder(url)
            noteRecent(RecentItem(kind: .folder, path: url.path,
                                  title: url.lastPathComponent, lastOpened: Date()))
        } else {
            // An explicit open pins; a matching preview entry is absorbed.
            if case .local(let p) = preview, p.url == url { preview = nil }
            addFile(url, displayName: url.lastPathComponent,
                    resourceRoot: url.deletingLastPathComponent())
            noteRecent(RecentItem(kind: .file, path: url.path,
                                  title: url.lastPathComponent, lastOpened: Date()))
            // The system's recents too, so the Dock icon's right-click
            // menu and Apple → Recent Items know about PullMark documents
            // — the in-app Recents section alone is invisible from the
            // Finder side. Files only: a folder in Recent Items would
            // reopen in Finder, not here.
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        }
    }

    /// Resolves a selection URL to a document. Ad-hoc opens live in
    /// `localFiles`; folder-tree files synthesize their entry on the fly
    /// (relative display name, root as resource root) so the detail view
    /// works identically for both.
    func localFile(for url: URL) -> LocalFile? {
        if let file = localFiles.first(where: { $0.url == url }) { return file }
        for folder in folders where url.path.hasPrefix(folder.rootURL.path + "/") {
            let relative = String(url.path.dropFirst(folder.rootURL.path.count + 1))
            return LocalFile(url: url, displayName: relative, resourceRoot: folder.rootURL)
        }
        return nil
    }

    func removeLocalFile(_ file: LocalFile) {
        localFiles.removeAll { $0.url == file.url }
        if selection == .local(file.url) { selection = nil }
    }

    // MARK: - Preview (transient working-set entry)

    var folderClickAction: FolderClickAction {
        FolderClickAction(rawValue: UserDefaults.pullmark.string(
            forKey: DefaultsKeys.folderClickAction) ?? "") ?? .preview
    }

    /// A file synthesized from the Location tree that contains it — nil
    /// for anything not under an open folder root.
    private func treeFile(for url: URL) -> LocalFile? {
        for folder in folders where url.path.hasPrefix(folder.rootURL.path + "/") {
            let relative = String(url.path.dropFirst(folder.rootURL.path.count + 1))
            return LocalFile(url: url, displayName: relative, resourceRoot: folder.rootURL)
        }
        return nil
    }

    /// Selecting an unpinned file inside a Location is "viewing" — it
    /// previews (or pins, per the setting). Runs deferred from the
    /// selection didSet; anything else selected leaves the preview alone,
    /// the way a preview tab survives focusing another tab.
    private func reactToSelection(_ value: SidebarSelection?) {
        guard value == selection else { return }
        switch value {
        case .local(let url):
            guard !localFiles.contains(where: { $0.url == url }),
                  let file = treeFile(for: url) else { return }
            switch folderClickAction {
            case .preview:
                if preview != .local(file) { preview = .local(file) }
            case .open:
                localFiles.append(file)
                if case .local(let p) = preview, p.url == url { preview = nil }
            }
        case .remoteDoc(let sessionID, let path):
            guard let index = remoteSessions.firstIndex(where: { $0.id == sessionID }),
                  !remoteSessions[index].docs.contains(path) else { return }
            switch folderClickAction {
            case .preview:
                if preview != .remote(sessionID: sessionID, path: path) {
                    preview = .remote(sessionID: sessionID, path: path)
                }
            case .open:
                remoteSessions[index].docs.append(path)
                if preview == .remote(sessionID: sessionID, path: path) { preview = nil }
            }
        default:
            return
        }
    }

    /// Double-click on a tree row or the preview row: keep the file open.
    func pinFile(at url: URL) {
        if case .local(let p) = preview, p.url == url { preview = nil }
        guard !localFiles.contains(where: { $0.url == url }),
              let file = treeFile(for: url) else {
            selection = .local(url)
            return
        }
        localFiles.append(file)
        selection = .local(url)
    }

    /// The remote twin: keep a browsed doc open in its session's docs list.
    func pinRemoteDoc(sessionID: String, path: String) {
        if preview == .remote(sessionID: sessionID, path: path) { preview = nil }
        guard let index = remoteSessions.firstIndex(where: { $0.id == sessionID }) else { return }
        if !remoteSessions[index].docs.contains(path) {
            remoteSessions[index].docs.append(path)
        }
        selection = .remoteDoc(sessionID, path)
    }

    /// Removes a pinned doc from a remote session's working set — the ✕
    /// gesture the docs rows earned once pinning became deliberate.
    func removeRemoteDoc(sessionID: String, path: String) {
        guard let index = remoteSessions.firstIndex(where: { $0.id == sessionID }) else { return }
        remoteSessions[index].docs.removeAll { $0 == path }
        if selection == .remoteDoc(sessionID, path) { selection = nil }
    }

    /// Authoring beats previewing: the first non-reading interaction with
    /// a previewed file (editing, commenting) pins it. Reading — blame,
    /// history, inspecting an image — never does.
    func pinPreviewIfNeeded(url: URL) {
        guard case .local(let p) = preview, p.url == url else { return }
        pinFile(at: url)
    }

    func dismissPreview() {
        guard let dismissed = preview else { return }
        preview = nil
        switch dismissed {
        case .local(let file):
            if selection == .local(file.url) { selection = nil }
        case .remote(let sessionID, let path):
            if selection == .remoteDoc(sessionID, path) { selection = nil }
        }
    }

    /// In-app navigation (a relative link in a rendered document): files
    /// that live in an open Location preview rather than pin — following
    /// a link is still reading. Everything else pins as before.
    func openViaLink(url: URL) {
        if !localFiles.contains(where: { $0.url == url }), treeFile(for: url) != nil {
            selection = .local(url)
        } else {
            add(url: url)
        }
    }

    /// The Open Files section header's one bulk gesture: pinned local
    /// files plus the preview slot, whatever it holds.
    func closeAllOpenFiles() {
        var closing = Set(localFiles.map(\.url))
        localFiles.removeAll()
        switch preview {
        case .local(let file):
            closing.insert(file.url)
            preview = nil
        case .remote:
            dismissPreview()
        case nil:
            break
        }
        if case .local(let url) = selection, closing.contains(url) { selection = nil }
    }

    /// The root of the open Location containing `url`, if any — gates the
    /// Reveal in Location menu item.
    func folderRootContaining(_ url: URL) -> URL? {
        folders.first { url.path.hasPrefix($0.rootURL.path + "/") }?.rootURL
    }

    /// Expands every ancestor of `url` in its Location's tree and selects
    /// the file — the bridge from a working-set row back to where it lives.
    func revealInLocation(_ url: URL) {
        guard let index = folders.firstIndex(where: {
            url.path.hasPrefix($0.rootURL.path + "/")
        }) else { return }
        let root = folders[index].rootURL
        folders[index].expandedPaths.insert("")
        var relative = url.deletingLastPathComponent().path
        while relative.count > root.path.count {
            folders[index].expandedPaths.insert(
                String(relative.dropFirst(root.path.count + 1)))
            relative = (relative as NSString).deletingLastPathComponent
        }
        selection = .local(url)
    }

    // MARK: - Folder roots (spec §2)

    func folder(for root: URL) -> LocalFolder? {
        folders.first { $0.rootURL == root }
    }

    private func addFolder(_ root: URL) {
        if folders.contains(where: { $0.rootURL == root }) {
            selection = .folder(root)
            rescanFolder(root: root)
            return
        }
        var folder = LocalFolder(rootURL: root)
        folder.scanning = true
        // "" is the root's own expansion entry — new roots open unfolded.
        folder.expandedPaths.insert("")
        folders.append(folder)
        // Opening a folder selects the root, not some scan-order file —
        // the user picks a file when they're ready (spec §8.6).
        selection = .folder(root)
        watchFolder(root)
        rescanFolder(root: root)
    }

    /// Removes the root and its whole tree in one gesture — the missing
    /// "close the folder" operation (spec §4).
    func removeFolder(_ root: URL) {
        folders.removeAll { $0.rootURL == root }
        folderWatchers[root] = nil
        // The preview belongs to the place it was browsed from.
        if case .local(let p) = preview, p.url.path.hasPrefix(root.path + "/") {
            preview = nil
        }
        switch selection {
        case .folder(root):
            selection = nil
        case .local(let url) where url.path.hasPrefix(root.path + "/")
            && !localFiles.contains(where: { $0.url == url }):
            selection = nil
        default:
            break
        }
    }

    func setFolderViewMode(_ root: URL, _ mode: LocalFolder.ViewMode) {
        guard let index = folders.firstIndex(where: { $0.rootURL == root }) else { return }
        folders[index].viewMode = mode
    }

    func setFolderExpanded(_ root: URL, path: String, _ expanded: Bool) {
        guard let index = folders.firstIndex(where: { $0.rootURL == root }) else { return }
        if expanded {
            folders[index].expandedPaths.insert(path)
        } else {
            folders[index].expandedPaths.remove(path)
        }
    }

    /// Rescans a root off the main thread and swaps the tree in. Also the
    /// manual Refresh Folder backstop and the watcher's coalesced target.
    /// One scan per root at a time: FSEvents bursts on a big repo used
    /// to pile unbounded concurrent walks — each slower than the
    /// stream's 0.5s latency — until disk and CPU drowned and the whole
    /// app felt slow (the thousands-of-files-Location report). A burst
    /// during a scan collapses to exactly one follow-up.
    private var rescanInFlight: Set<URL> = []
    private var rescanQueued: Set<URL> = []

    func rescanFolder(root: URL, priority: TaskPriority = .userInitiated) {
        if rescanInFlight.contains(root) {
            rescanQueued.insert(root)
            return
        }
        rescanInFlight.insert(root)
        Task.detached(priority: priority) { [weak self] in
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
            let scan = exists ? Self.scanFolderTree(root: root) : (paths: [], truncated: false)
            let nodes = PathTree.build(scan.paths)
            // Flattened here too — 20k leaves have no business on main.
            let filePaths = nodes.flatMap(PathTree.leafPaths)
            let git = exists ? LocalGit.repoInfo(forDirectory: root) : nil
            guard let self else { return }
            await MainActor.run {
                self.finishRescan(root: root, exists: exists, nodes: nodes,
                                  filePaths: filePaths, truncated: scan.truncated,
                                  git: git)
            }
        }
    }

    private func finishRescan(root: URL, exists: Bool, nodes: [PathTree.Node],
                              filePaths: [String], truncated: Bool,
                              git: LocalGit.RepoInfo?) {
        defer {
            rescanInFlight.remove(root)
            if rescanQueued.remove(root) != nil {
                rescanFolder(root: root, priority: .utility)
            }
        }
        guard let index = folders.firstIndex(where: { $0.rootURL == root }) else { return }
        // Only the initial add-time scan may speak up: watcher
        // rescans repeat for every change in the folder, and a
        // notice that re-fires per rescan is a nag, not a notice.
        // Truncation never alerts at all — the tree's own footer
        // row carries that fact quietly and persistently.
        let initialScan = folders[index].scanning
        folders[index].scanning = false
        if exists {
            // A returned root revives with fresh contents.
            folders[index].missing = false
            folders[index].nodes = nodes
            folders[index].filePaths = filePaths
            folders[index].truncated = truncated
            folders[index].git = git
            if initialScan, filePaths.isEmpty {
                lastNotice = "No Markdown files found in \(root.lastPathComponent)."
            }
        } else {
            // The root vanished (unmounted volume, deleted
            // checkout): dim it, keep the last tree, revive later.
            folders[index].missing = true
        }
    }

    /// Re-walks every live root — the show-hidden-files flip changes what
    /// a scan even sees, so all trees rebuild. Quiet by design: these are
    /// not add-time scans, so no notices fire.
    func rescanAllFolders() {
        for folder in folders where !folder.missing {
            rescanFolder(root: folder.rootURL)
        }
    }

    private var folderWatchers: [URL: FolderWatcher] = [:]

    private func watchFolder(_ root: URL) {
        // FSEvents reports realpath-form paths (/tmp roots arrive as
        // /private/tmp) — canonicalize the SAME way for the relevance
        // check. NOT resolvingSymlinksInPath(): Foundation strips
        // /private from /tmp and /var paths, the exact opposite form,
        // and the mismatch made every event look out-of-root (= rescan).
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let resolvedRoot = root.path.withCString { cString in
            realpath(cString, &buffer).map { String(cString: $0) }
        } ?? root.path
        folderWatchers[root] = FolderWatcher(root: root) { [weak self] changed in
            // Batches wholly inside skipped subtrees (.git churn is the
            // big one) can't change the tree — no rescan.
            let showHidden = UserDefaults.pullmark.bool(forKey: DefaultsKeys.showHiddenFiles)
            guard FolderScanRules.rescanRelevant(changedPaths: changed,
                                                 resolvedRootPath: resolvedRoot,
                                                 showHidden: showHidden) else { return }
            Task { @MainActor in self?.rescanFolder(root: root, priority: .utility) }
        }
    }

    /// Cheap truth pass (spec §6): recents validate and folder roots
    /// revive on app activation and window open.
    func validateSidebarPaths() {
        var missing: Set<String> = []
        for item in recents where item.kind != .pr {
            if let path = item.path, !FileManager.default.fileExists(atPath: path) {
                missing.insert(item.id)
            }
        }
        missingRecentIDs = missing
        if case .local(let p) = preview,
           !FileManager.default.fileExists(atPath: p.url.path) {
            preview = nil
        }
        for folder in folders {
            let exists = FileManager.default.fileExists(atPath: folder.rootURL.path)
            if exists == folder.missing { rescanFolder(root: folder.rootURL) }
        }
        // Branch/worktree facts change outside the app (a checkout in a
        // terminal) — refresh identities on the same activation heartbeat,
        // off-main, publishing only actual changes.
        for folder in folders where !folder.missing {
            let root = folder.rootURL
            Task.detached(priority: .utility) { [weak self] in
                let git = LocalGit.repoInfo(forDirectory: root)
                guard let self else { return }
                await MainActor.run {
                    guard let index = self.folders.firstIndex(where: { $0.rootURL == root }),
                          self.folders[index].git != git else { return }
                    self.folders[index].git = git
                }
            }
        }
    }

    /// Generous for real repos — the tree renders per-expansion, ⌘K
    /// matches this many paths in milliseconds, and truncating a
    /// monorepo at 2000 turned the cap into a nag. The caps that remain
    /// are tripwires for pathological roots (opening ~ or /), not
    /// working limits.
    nonisolated private static let folderFileLimit = 20_000
    nonisolated private static let folderVisitLimit = 250_000

    /// Full background enumeration per root. The spec sketched lazy
    /// per-disclosure scanning, but empty-directory pruning and the
    /// ⌘K/⇧⌘F completeness rule need the full walk anyway — one scan
    /// with a generous cap keeps every guarantee with less machinery.
    nonisolated private static func scanFolderTree(root: URL) -> (paths: [String], truncated: Bool) {
        // .git is unconditional: invisible while hidden files are off,
        // but a raw object store the walker must never descend into
        // once they're on. Shared with the watcher's relevance filter —
        // whatever the scan skips, events inside it must not rescan.
        let skippedDirectories = FolderScanRules.skippedDirectories
        let showHidden = UserDefaults.pullmark.bool(forKey: DefaultsKeys.showHiddenFiles)
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !showHidden { options.insert(.skipsHiddenFiles) }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: options
        ) else { return ([], false) }

        var paths: [String] = []
        var visited = 0
        for case let url as URL in enumerator {
            visited += 1
            if visited > folderVisitLimit { return (paths, true) }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                if skippedDirectories.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard MarkdownFileType.matches(url.pathExtension) else { continue }
            let relative = url.path.hasPrefix(root.path + "/")
                ? String(url.path.dropFirst(root.path.count + 1))
                : url.lastPathComponent
            paths.append(relative)
            if paths.count >= folderFileLimit { return (paths, true) }
        }
        return (paths, false)
    }

    private func addFile(_ url: URL, displayName: String, resourceRoot: URL) {
        if !localFiles.contains(where: { $0.url == url }) {
            localFiles.append(LocalFile(url: url, displayName: displayName, resourceRoot: resourceRoot))
        }
        selection = .local(url)
    }

    // MARK: - Pull requests

    /// Head-revision Markdown text already fetched for PR files and browsed
    /// repo docs, keyed by (session id, repo path). Memory only — populated
    /// as detail views load content, so the search palette can search PR
    /// documents without triggering network fetches.
    struct PRContentKey: Hashable {
        let sessionID: String
        let path: String
    }
    private var prContentCache: [PRContentKey: String] = [:]

    func cachePRContent(sessionID: String, path: String, text: String) {
        prContentCache[PRContentKey(sessionID: sessionID, path: path)] = text
    }

    func cachedPRContent(sessionID: String, path: String) -> String? {
        prContentCache[PRContentKey(sessionID: sessionID, path: path)]
    }

    private func dropPRContentCache(sessionID: String) {
        prContentCache = prContentCache.filter { $0.key.sessionID != sessionID }
    }

    func session(_ id: String) -> PRSession? {
        prSessions.first { $0.id == id }
    }

    func addPR(_ input: String) async throws {
        guard let ref = PullRequestRef.parse(input) else {
            throw MessageError(message: "Could not parse a pull request from “\(input)”. "
                + "Expected something like https://github.com/owner/repo/pull/123 or owner/repo#123.")
        }
        if let existing = prSessions.first(where: { $0.ref == ref }) {
            selection = .prOverview(existing.id)
            return
        }
        let details: PullRequestDetails
        do {
            details = try await client.pullRequest(ref)
        } catch {
            if let apiError = error as? GitHubClient.APIError, apiError.status == 404 {
                updateRecentPRStatus(ref: ref, status: .deleted)
            }
            throw error
        }
        let files = try await client.files(ref)
        var mergeBase = details.base.sha
        do {
            mergeBase = try await client.mergeBaseSHA(ref, base: details.base.sha, head: details.head.sha)
        } catch {
            // Fall back to the base tip; only matters when the base branch moved.
        }
        var session = PRSession(ref: ref, details: details, mergeBaseSHA: mergeBase, files: files)
        do {
            session.reviewComments = try await client.reviewComments(ref)
            session.threadMeta = try await client.reviewThreadMeta(ref)
        } catch {
            // A blip must not render as "no comments on this PR".
            session.commentsUnavailable = true
        }
        // Cockpit and conversation load in their own failure domains: a
        // blip here keeps the header quiet and never trips the comments
        // banner (spec: pr-cockpit). The 60s tick retries both.
        if let payload = try? await client.cockpit(ref) {
            session.cockpit = payload.state
            session.conversationMeta = payload.commentMeta
            session.reviewMeta = payload.reviewMeta
            session.reviewReactions = payload.reviewReactions
        }
        do {
            let (comments, etag) = try await client.issueCommentsIfChanged(ref, etag: nil)
            session.issueComments = comments ?? []
            session.conversationETag = etag
            session.reviews = try await client.reviews(ref)
        } catch {
            session.conversationUnavailable = true
        }
        session.queuedComments = PendingReviewStore.loadQueue(ref: ref, headSHA: details.head.sha)
        // Concurrent opens of the same PR both pass the check at the top of
        // this function during the awaits above — re-check at the append
        // and adopt the winner, or the session (and its pending-comment
        // syncing) exists twice.
        if let existing = prSessions.first(where: { $0.ref == ref }) {
            selection = .prOverview(existing.id)
            return
        }
        prSessions.append(session)
        selection = .prOverview(session.id)
        noteRecent(RecentItem(kind: .pr, owner: ref.owner, repo: ref.repo, number: ref.number,
                              title: details.title, prStatus: PRStatus(details: details),
                              lastOpened: Date()))
        // A pending review saved from here or started on github.com must be
        // visible from the first render; a fetch failure shows the same
        // banner as missing comments — never a silently clean review state.
        let sessionID = session.id
        if await !adoptPendingReview(sessionID: sessionID),
           let index = prSessions.firstIndex(where: { $0.id == sessionID }) {
            prSessions[index].commentsUnavailable = true
        }
        await syncPendingComments(sessionID: sessionID)
    }

    func openRemoteDoc(sessionID: String, path: String) {
        guard let index = prSessions.firstIndex(where: { $0.id == sessionID }) else { return }
        if !prSessions[index].browsedDocs.contains(path) {
            prSessions[index].browsedDocs.append(path)
        }
        selection = .prDoc(sessionID, path)
    }

    // MARK: - GitHub Markdown links (remote repo sessions)

    var remoteLinkPolicy: RemoteLinkPolicy {
        get {
            RemoteLinkPolicy(rawValue: UserDefaults.pullmark.string(forKey: DefaultsKeys.remoteLinkPolicy) ?? "")
                ?? .ask
        }
        set { UserDefaults.pullmark.set(newValue.rawValue, forKey: DefaultsKeys.remoteLinkPolicy) }
    }

    /// Entry point for clicked GitHub Markdown links. ⌘-click inverts the
    /// default; a plain click while the policy is still `.ask` presents the
    /// one-time choice instead of doing anything.
    func handleGitHubLink(_ link: RemoteDocLink, url: URL, inverted: Bool) {
        let inApp: Bool
        switch remoteLinkPolicy {
        case .ask:
            remoteLinkPrompt = RemoteLinkPrompt(link: link, url: url)
            return
        case .pullmark: inApp = !inverted
        case .browser: inApp = inverted
        }
        if inApp {
            openGitHubDoc(link)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// The ask dialog's choice. With `remember` the choice becomes the
    /// default (the policy leaves `.ask`); without it the choice applies
    /// once and the dialog returns next click. The checkbox state itself
    /// persists either way — an uncheck stays unchecked.
    func resolveRemoteLinkPrompt(_ prompt: RemoteLinkPrompt, openInApp: Bool, remember: Bool) {
        UserDefaults.pullmark.set(remember, forKey: DefaultsKeys.remoteLinkRemember)
        if remember {
            remoteLinkPolicy = openInApp ? .pullmark : .browser
        }
        if openInApp {
            openGitHubDoc(prompt.link)
        } else {
            NSWorkspace.shared.open(prompt.url)
        }
    }

    /// Opens a GitHub Markdown link in-app, with PR precedence: a path in
    /// an open PR's diff opens as that PR file (the diff space); the same
    /// repo at the PR's head joins the PR's browsed docs; anything else
    /// gets a remote repo session. Link clicks are navigation — reading —
    /// so the doc previews; `pin: true` (⌘K, an explicit destination)
    /// pins it into the session's docs.
    func openGitHubDoc(_ link: RemoteDocLink, pin: Bool = false) {
        for session in prSessions
        where session.ref.owner.caseInsensitiveCompare(link.owner) == .orderedSame
            && session.ref.repo.caseInsensitiveCompare(link.repo) == .orderedSame {
            if session.files.contains(where: { $0.filename == link.path }) {
                selection = .prFile(session.id, link.path)
                return
            }
            if link.ref == session.details.head.ref || session.details.head.sha.hasPrefix(link.ref) {
                openRemoteDoc(sessionID: session.id, path: link.path)
                return
            }
        }
        // Local precedence: a clone or worktree of this repo checked out on
        // the link's exact branch serves the file from disk — editable,
        // offline, and labeled by the folder row's own branch chip. Any
        // other ref falls through to a pinned remote session; disk truth
        // only wins when it IS the linked ref.
        for folder in folders {
            guard let git = folder.git,
                  git.branch == link.ref,
                  git.gitHubRepos.contains(where: { $0.matches(owner: link.owner, repo: link.repo) })
            else { continue }
            let url = URL(fileURLWithPath: git.toplevel).appendingPathComponent(link.path)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            if localFile(for: url) != nil {
                selection = .local(url)
            } else {
                add(url: url)
            }
            return
        }
        let sessionID = "\(link.owner)/\(link.repo)@\(link.ref)"
        if let index = remoteSessions.firstIndex(where: { $0.id == sessionID }) {
            if pin, !remoteSessions[index].docs.contains(link.path) {
                remoteSessions[index].docs.append(link.path)
            }
        } else {
            var session = RemoteRepoSession(ref: PullRequestRef(owner: link.owner, repo: link.repo, number: 0),
                                            displayRef: link.ref)
            // Unpinned opens leave docs empty — the selection didSet
            // previews the doc under its new session instead.
            session.docs = pin ? [link.path] : []
            remoteSessions.append(session)
        }
        if let fragment = link.fragment {
            remoteAnchor = RemoteAnchorRequest(sessionID: sessionID, path: link.path, fragment: fragment)
        }
        selection = .remoteDoc(sessionID, link.path)
    }

    /// ⌘K with `owner/repo` or a repo URL: open the repo for browsing at
    /// its default branch (or the given ref) and load the tree — pasting a
    /// repo *is* the browse intent, so that path fetches immediately.
    /// "Open Branch Separately" reuses this with `loadTree: false` (the
    /// sibling session appears instantly; its tree stays on demand).
    func openRemoteRepo(owner: String, repo: String, refName: String?,
                        loadTree: Bool = true) async {
        let ref = PullRequestRef(owner: owner, repo: repo, number: 0)
        do {
            let resolvedRef: String
            if let refName {
                resolvedRef = refName
            } else {
                resolvedRef = try await client.defaultBranch(ref)
            }
            let sessionID = "\(owner)/\(repo)@\(resolvedRef)"
            if !remoteSessions.contains(where: { $0.id == sessionID }) {
                remoteSessions.append(RemoteRepoSession(ref: ref, displayRef: resolvedRef))
            }
            selection = .remoteRepo(sessionID)
            if loadTree {
                await loadRemoteTree(sessionID: sessionID)
            }
        } catch {
            lastError = Self.remoteFailureMessage(error, what: "\(owner)/\(repo)")
        }
    }

    /// Re-pins a remote session to another branch in place: same open
    /// docs (refetched at the new ref — a doc missing there says so
    /// loudly), selection follows, the tree refetches only if it was
    /// already loaded. If the target ref is already open as its own
    /// session, switching just goes there — sessions never merge.
    func switchRemoteSession(id: String, toRef newRef: String) {
        guard let index = remoteSessions.firstIndex(where: { $0.id == id }),
              remoteSessions[index].displayRef != newRef else { return }
        let old = remoteSessions[index]
        let newID = "\(old.ref.owner)/\(old.ref.repo)@\(newRef)"
        if remoteSessions.contains(where: { $0.id == newID }) {
            selection = .remoteRepo(newID)
            return
        }
        var session = RemoteRepoSession(ref: old.ref, displayRef: newRef)
        session.docs = old.docs
        remoteSessions[index] = session
        // The preview rides along like the docs do — refetched at the new
        // ref; a doc missing there says so loudly.
        if case .remote(let sessionID, let path) = preview, sessionID == id {
            preview = .remote(sessionID: newID, path: path)
        }
        dropPRContentCache(sessionID: id)
        switch selection {
        case .remoteRepo(let s) where s == id:
            selection = .remoteRepo(newID)
        case .remoteDoc(let s, let path) where s == id:
            selection = .remoteDoc(newID, path)
        default:
            break
        }
        if old.treePaths != nil {
            Task { await loadRemoteTree(sessionID: newID) }
        }
    }

    func remoteSession(_ id: String) -> RemoteRepoSession? {
        remoteSessions.first { $0.id == id }
    }

    /// A relative link inside a remote doc — navigation, so the target
    /// previews (the selection didSet applies the click policy); already
    /// pinned docs just select.
    func openRemoteSessionDoc(sessionID: String, path: String) {
        guard remoteSessions.contains(where: { $0.id == sessionID }) else { return }
        selection = .remoteDoc(sessionID, path)
    }

    /// Resolves the session's friendly ref to a commit SHA on first use —
    /// the moment the session actually touches the network.
    func ensureRemoteSHA(sessionID: String) async throws -> String {
        guard let session = remoteSession(sessionID) else {
            throw MessageError(message: "That repository is no longer open.")
        }
        if let sha = session.commitSHA { return sha }
        let sha = try await client.commitSHA(session.ref, atRef: session.displayRef)
        if let index = remoteSessions.firstIndex(where: { $0.id == sessionID }) {
            remoteSessions[index].commitSHA = sha
        }
        return sha
    }

    /// Reload for a branch-tracking remote session: forget the resolved
    /// commit so the next fetch re-resolves the ref. The browsed tree is
    /// deliberately KEPT — nilling it would unmount any document shown
    /// via the repo-root readme (both DetailView and surfaceExpectation
    /// derive that readme from treePaths) and collapse the sidebar tree;
    /// the caller refreshes it at the new commit instead.
    func unpinRemoteSession(sessionID: String) {
        guard let index = remoteSessions.firstIndex(where: { $0.id == sessionID }) else { return }
        remoteSessions[index].commitSHA = nil
        dropPRContentCache(sessionID: sessionID)
    }

    /// Fetches the repo's Markdown tree for the sidebar (explicit user
    /// action — the Browse row or a ⌘K repo open).
    func loadRemoteTree(sessionID: String) async {
        guard let index = remoteSessions.firstIndex(where: { $0.id == sessionID }),
              !remoteSessions[index].treeLoading else { return }
        remoteSessions[index].treeLoading = true
        do {
            let sha = try await ensureRemoteSHA(sessionID: sessionID)
            guard let session = remoteSession(sessionID) else { return }
            let (paths, truncated) = try await client.markdownTreePaths(session.ref, at: sha)
            if let i = remoteSessions.firstIndex(where: { $0.id == sessionID }) {
                // Same visible cap as local folder scans, and GitHub itself
                // truncates giant trees — either way the UI says so.
                remoteSessions[i].treePaths = Array(paths.prefix(Self.folderFileLimit))
                remoteSessions[i].treeTruncated = truncated || paths.count > Self.folderFileLimit
            }
        } catch {
            lastError = Self.remoteFailureMessage(error, what: sessionID)
        }
        if let i = remoteSessions.firstIndex(where: { $0.id == sessionID }) {
            remoteSessions[i].treeLoading = false
        }
    }

    func removeRemoteSession(_ id: String) {
        remoteSessions.removeAll { $0.id == id }
        if case .remote(let sessionID, _) = preview, sessionID == id { preview = nil }
        dropPRContentCache(sessionID: id)
        switch selection {
        case .remoteRepo(let s) where s == id,
             .remoteDoc(let s, _) where s == id:
            selection = nil
        default:
            break
        }
    }

    /// GitHub answers 404 both for "doesn't exist" and "private repo your
    /// token can't see" — the message must leave both doors open (and the
    /// client already appends a sign-in hint when no credentials resolved).
    static func remoteFailureMessage(_ error: Error, what: String) -> String {
        if let api = error as? GitHubClient.APIError, api.status == 404 {
            return "Couldn't open \(what): \(api.message). It may not exist at that ref, "
                + "or it may be a private repository your GitHub credentials can't access."
        }
        return "Couldn't open \(what): \(error.localizedDescription)"
    }

    /// The 60s quiet tick for the frontmost PR (spec: pr-cockpit):
    /// check activity never bumps the PR's updatedAt, so cockpit state
    /// cannot ride the head-SHA gate below — it refreshes directly,
    /// applied in place with no banner. Key-window-only, like the inbox
    /// poll: N windows share one rate limit.
    func refreshCockpitIfDue() async {
        guard !DemoMode.active, Self.keyInstance === self else { return }
        guard let sessionID = frontmostPRSessionID() else { return }
        await refreshCockpit(sessionID: sessionID)
    }

    /// The PR session the window is currently showing, if any.
    private func frontmostPRSessionID() -> String? {
        switch selection {
        case .prOverview(let id), .prFile(let id, _), .prDoc(let id, _):
            return id
        default:
            return nil
        }
    }

    /// One cockpit + conversation round trip, folded in quietly.
    /// Failures keep last-known state — a tick blip must not blank a
    /// populated header; `conversationUnavailable` only flags when
    /// there is nothing older to show.
    func refreshCockpit(sessionID: String) async {
        guard let session = prSessions.first(where: { $0.id == sessionID }) else { return }
        let ref = session.ref
        if let payload = try? await client.cockpit(ref),
           let index = prSessions.firstIndex(where: { $0.id == sessionID }) {
            prSessions[index].cockpit = payload.state
            prSessions[index].conversationMeta = payload.commentMeta
            prSessions[index].reviewMeta = payload.reviewMeta
            prSessions[index].reviewReactions = payload.reviewReactions
        }
        do {
            let etag = prSessions.first(where: { $0.id == sessionID })?.conversationETag
            let (comments, freshTag) = try await client.issueCommentsIfChanged(ref, etag: etag)
            let reviews = try await client.reviews(ref)
            guard let index = prSessions.firstIndex(where: { $0.id == sessionID }) else { return }
            if let comments {
                // The list endpoint lags fresh writes (0.31.0 lesson): a
                // comment folded in during this fetch can be missing from
                // the response, and replacing wholesale would make the
                // user watch their own comment vanish. Ids ascend, so
                // the lag window is identifiable — keep local comments
                // newer than everything the server returned; genuine
                // deletions (older ids) still drop.
                let maxFetched = comments.map(\.id).max() ?? 0
                let lagging = prSessions[index].issueComments.filter { local in
                    local.id > maxFetched
                }
                prSessions[index].issueComments = comments + lagging
            }
            prSessions[index].conversationETag = freshTag
            prSessions[index].reviews = reviews
            prSessions[index].conversationUnavailable = false
        } catch {
            guard let index = prSessions.firstIndex(where: { $0.id == sessionID }) else { return }
            if prSessions[index].issueComments.isEmpty && prSessions[index].reviews.isEmpty {
                prSessions[index].conversationUnavailable = true
            }
        }
    }

    /// Detects head movement on open PRs; sets a flag rather than reloading
    /// so an in-progress review is never yanked out from under the user.
    func checkForPRUpdates() async {
        // The demo PR has no upstream to move.
        guard !DemoMode.active else { return }
        for session in prSessions where !session.updateAvailable {
            guard let details = try? await client.pullRequest(session.ref) else { continue }
            updateRecentPRStatus(ref: session.ref, status: PRStatus(details: details))
            if details.head.sha != session.details.head.sha,
               let index = prSessions.firstIndex(where: { $0.id == session.id }) {
                prSessions[index].updateAvailable = true
            }
        }
        // A pending review started elsewhere (github.com) appears without
        // a relaunch: adoption rides the same 60s poll. Cheap — one
        // reviews GET per open session, GraphQL only when one exists —
        // and a poll failure stays silent; the next poll retries.
        for session in prSessions {
            await adoptPendingReview(sessionID: session.id)
        }
    }

    func refreshPR(sessionID: String) async {
        guard let session = prSessions.first(where: { $0.id == sessionID }) else { return }
        let ref = session.ref
        do {
            let details = try await client.pullRequest(ref)
            let files = try await client.files(ref)
            let mergeBase = (try? await client.mergeBaseSHA(ref, base: details.base.sha, head: details.head.sha))
                ?? details.base.sha
            var comments: [ReviewComment] = []
            var meta: [Int: ThreadMeta] = [:]
            var commentsUnavailable = false
            do {
                comments = try await client.reviewComments(ref)
                meta = try await client.reviewThreadMeta(ref)
            } catch {
                commentsUnavailable = true
            }
            guard let index = prSessions.firstIndex(where: { $0.id == sessionID }) else { return }
            let headMoved = details.head.sha != prSessions[index].details.head.sha
            prSessions[index].details = details
            prSessions[index].files = files
            prSessions[index].mergeBaseSHA = mergeBase
            if !commentsUnavailable {
                prSessions[index].reviewComments = comments
                prSessions[index].threadMeta = meta
            }
            prSessions[index].commentsUnavailable = commentsUnavailable
            prSessions[index].updateAvailable = false
            if headMoved {
                // Queued anchors are per-head; the old head's queue stays on
                // disk under its own key rather than mis-anchoring here.
                prSessions[index].queuedComments = PendingReviewStore.loadQueue(
                    ref: ref, headSHA: details.head.sha)
            }
            // Cached document text may predate the new head; views refill it.
            dropPRContentCache(sessionID: sessionID)
            updateRecentPRStatus(ref: ref, status: PRStatus(details: details))
            if await !adoptPendingReview(sessionID: sessionID),
               let current = prSessions.firstIndex(where: { $0.id == sessionID }) {
                prSessions[current].commentsUnavailable = true
            }
            await syncPendingComments(sessionID: sessionID)
            // Last: refreshCockpit suspends across several round trips,
            // and `index` above must never be used past an await — a
            // session closed mid-refresh would corrupt another session's
            // queue through the stale index (code-review catch).
            await refreshCockpit(sessionID: sessionID)
        } catch {
            lastError = "Could not refresh \(session.id): \(error.localizedDescription)"
        }
    }

    // MARK: - Recents

    func openRecent(_ item: RecentItem) {
        switch item.kind {
        case .file, .folder:
            guard let path = item.path else { return }
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                // No error-and-purge (spec §6): the entry stays, dimmed —
                // built for git branch switches and unmounted volumes,
                // where the file comes back. The notice offers removal.
                missingRecentIDs.insert(item.id)
                deadRecent = item
                return
            }
            missingRecentIDs.remove(item.id)
            add(url: url)
        case .pr:
            guard let ref = item.ref else { return }
            Task {
                do {
                    try await addPR("\(ref.owner)/\(ref.repo)#\(ref.number)")
                } catch {
                    lastError = error.localizedDescription
                }
            }
        }
    }

    func removeRecent(id: String) {
        recents.removeAll { $0.id == id }
        saveRecents()
    }

    func clearRecents() {
        recents.removeAll()
        saveRecents()
    }

    private func noteRecent(_ item: RecentItem) {
        recents.removeAll { $0.id == item.id }
        recents.insert(item, at: 0)
        let overflow = recents.filter { $0.kind == item.kind }.dropFirst(Self.recentsLimit)
        for stale in overflow { recents.removeAll { $0.id == stale.id } }
        saveRecents()
    }

    private func updateRecentPRStatus(ref: PullRequestRef, status: PRStatus) {
        guard let index = recents.firstIndex(where: { $0.ref == ref }) else { return }
        if recents[index].prStatus != status {
            recents[index].prStatus = status
            saveRecents()
        }
    }

    private func loadRecents() {
        guard let data = UserDefaults.pullmark.data(forKey: Self.recentsKey),
              let decoded = try? JSONDecoder().decode([RecentItem].self, from: data)
        else { return }
        recents = decoded
    }

    private func saveRecents() {
        if let data = try? JSONEncoder().encode(recents) {
            UserDefaults.pullmark.set(data, forKey: Self.recentsKey)
        }
    }

    /// Refreshes existing review comments and thread state, e.g. after
    /// posting, replying, or resolving.
    func reloadComments(sessionID: String) async {
        guard let index = prSessions.firstIndex(where: { $0.id == sessionID }) else { return }
        let ref = prSessions[index].ref
        guard let comments = try? await client.reviewComments(ref) else { return }
        let meta = (try? await client.reviewThreadMeta(ref)) ?? [:]
        if let current = prSessions.firstIndex(where: { $0.id == sessionID }) {
            prSessions[current].reviewComments = comments
            prSessions[current].threadMeta = meta
        }
    }

    /// Folds a just-posted reply into the loaded model without a refetch:
    /// GitHub's comment-list endpoint can lag a fresh write, so an
    /// immediate refetch may come back WITHOUT the comment the user just
    /// watched post — the created comment GitHub returned is the truth.
    func applyPostedReply(sessionID: String, comment: ReviewComment) {
        guard let index = prSessions.firstIndex(where: { $0.id == sessionID }),
              !prSessions[index].reviewComments.contains(where: { $0.id == comment.id })
        else { return }
        prSessions[index].reviewComments.append(comment)
    }

    /// Folds a confirmed edit into the loaded model — same lag rationale
    /// as applyPostedReply. (The "edited" byline arrives with the next
    /// meta refresh; the text itself must not wait or revert.)
    func applyCommentEdit(sessionID: String, commentID: Int, body: String) {
        guard let index = prSessions.firstIndex(where: { $0.id == sessionID }),
              let comment = prSessions[index].reviewComments.firstIndex(where: { $0.id == commentID })
        else { return }
        prSessions[index].reviewComments[comment].body = body
    }

    /// Removes a deleted comment locally — a lagging refetch would
    /// resurrect it. Thread grouping's deleted-root fallback keeps any
    /// surviving replies together.
    func applyCommentDelete(sessionID: String, commentID: Int) {
        guard let index = prSessions.firstIndex(where: { $0.id == sessionID }) else { return }
        prSessions[index].reviewComments.removeAll { $0.id == commentID }
    }

    /// Folds a confirmed resolve/unresolve into the loaded model — the
    /// GraphQL mutation succeeded; the meta flag is the only state that
    /// changed.
    func applyThreadResolved(sessionID: String, rootID: Int, resolved: Bool) {
        guard let index = prSessions.firstIndex(where: { $0.id == sessionID }) else { return }
        prSessions[index].threadMeta[rootID]?.isResolved = resolved
    }

    /// Folds a confirmed reaction write into the loaded model without a
    /// refetch: the REST rollup count and the viewer's reaction state move
    /// together, and the session is published once — the comment list and
    /// the meta its chips derive from can never disagree mid-update.
    func applyReaction(sessionID: String, commentID: Int, content: String, reacted: Bool) {
        guard let index = prSessions.firstIndex(where: { $0.id == sessionID }) else { return }
        var session = prSessions[index]
        guard let commentIndex = session.reviewComments.firstIndex(where: { $0.id == commentID })
        else { return }
        let rootID = CommentReactions.metaRoot(of: commentID, in: session.threadMeta)
        let viewerReacted = rootID.flatMap {
            session.threadMeta[$0]?.comments[commentID]?.viewerReacted
        } ?? []
        let updated = CommentReactions.applied(
            rollup: session.reviewComments[commentIndex].reactions ?? ReactionRollup(),
            viewerReacted: viewerReacted, content: content, reacted: reacted)
        session.reviewComments[commentIndex].reactions = updated.rollup
        if let rootID {
            session.threadMeta[rootID]?.comments[commentID]?.viewerReacted = updated.viewerReacted
        }
        prSessions[index] = session
    }

    /// FIFO write chain per comment id: a rapid double-toggle must reach
    /// GitHub in click order — two concurrent Tasks can invert an
    /// add/remove pair server-side, failing the second write and surfacing
    /// a spurious error for a state the user already left.
    private var reactionWriteChains: [Int: (task: Task<Void, Never>, generation: Int)] = [:]

    func serializeReactionWrite(commentID: Int,
                                _ operation: @escaping @MainActor () async -> Void) {
        let previous = reactionWriteChains[commentID]?.task
        let generation = (reactionWriteChains[commentID]?.generation ?? 0) + 1
        let task = Task { [weak self] in
            await previous?.value
            await operation()
            // Drop the bookkeeping once the chain drains (still the tail).
            if let self, self.reactionWriteChains[commentID]?.generation == generation {
                self.reactionWriteChains[commentID] = nil
            }
        }
        reactionWriteChains[commentID] = (task, generation)
    }

    func removePR(_ id: String) {
        prSessions.removeAll { $0.id == id }
        dropPRContentCache(sessionID: id)
        adoptionKnown.remove(id)
        pendingSyncGate.forget(id)
        switch selection {
        case .prOverview(let s):
            if s == id { selection = nil }
        case .prFile(let s, _):
            if s == id { selection = nil }
        default:
            break
        }
    }

    // MARK: - Pending review (GitHub is the source of truth — spec §4)

    /// One upload loop per PR (two quick adds can't race each other into
    /// duplicate comments); adds during a pass trigger another, and submit
    /// waits for in-flight runs — see PendingSyncGate.
    private let pendingSyncGate = PendingSyncGate()

    /// Sessions whose latest pending-review adoption succeeded. The create
    /// path of a sync may only run for a session in this set: when
    /// adoption state is unknown (identity resolution or the fetch failed
    /// with a token present), a pending review the app cannot see may
    /// exist server-side, and creating would 422 against it forever.
    private var adoptionKnown: Set<String> = []

    /// Queues a review comment and immediately syncs it into the viewer's
    /// pending review on GitHub, so the pending count is true by
    /// construction. On failure it stays queued (and on disk) for retry.
    func addPendingComment(sessionID: String, _ comment: PendingComment) {
        guard let index = prSessions.firstIndex(where: { $0.id == sessionID }) else { return }
        prSessions[index].queuedComments.append(comment)
        persistQueue(sessionID: sessionID)
        pendingSyncGate.noteChange(sessionID)
        Task { await syncPendingComments(sessionID: sessionID) }
    }

    /// Discards one pending comment — locally when it never reached GitHub,
    /// server-side (then re-adopted) when it did.
    func removePendingComment(sessionID: String, id: String) {
        guard let index = prSessions.firstIndex(where: { $0.id == sessionID }) else { return }
        if prSessions[index].queuedComments.contains(where: { $0.id == id }) {
            prSessions[index].queuedComments.removeAll { $0.id == id }
            persistQueue(sessionID: sessionID)
            return
        }
        guard let comment = prSessions[index].pendingReview?.comments
            .first(where: { $0.id == id }) else { return }
        guard let serverID = comment.serverID else {
            // Landed by the atomic create, id not echoed back yet (see
            // stateAfterCreate) — a server-side delete needs the id.
            lastError = "This comment is still syncing with GitHub — try discarding it again in a moment."
            return
        }
        let ref = prSessions[index].ref
        Task {
            do {
                try await client.deleteReviewComment(ref, commentID: serverID)
                await adoptPendingReview(sessionID: sessionID)
            } catch {
                lastError = "Could not discard the pending comment: \(error.localizedDescription)"
            }
        }
    }

    /// Fetches the viewer's pending review (if any) and reconciles the
    /// local queue against its comments — publishing both together so the
    /// unified list and its per-row upload state never disagree. Returns
    /// false when adoption state could not be established (callers decide
    /// how loudly to surface).
    @discardableResult
    func adoptPendingReview(sessionID: String) async -> Bool {
        // Demo mode: the fabricated pending review IS the truth — there is
        // no server to reconcile against, and adoption must never clear it.
        guard !DemoMode.active else { return true }
        guard let session = prSessions.first(where: { $0.id == sessionID }) else { return true }
        let ref = session.ref
        // Unauthenticated: no pending review can exist and no sync can run
        // — a clean, known absence.
        guard await client.authToken() != nil else {
            adoptionKnown.insert(sessionID)
            return true
        }
        // A token is present, so a pending review may exist server-side.
        // A failed identity resolution means its existence is unknown —
        // that must read as "unavailable" (banner), never as a silently
        // clean "no pending review".
        guard let viewer = await client.viewerIdentity()?.login else {
            adoptionKnown.remove(sessionID)
            return false
        }
        viewerLogin = viewer
        do {
            let reviews = try await client.reviews(ref)
            var state: PendingReviewState?
            if let pending = PendingReviewSync.pendingReview(in: reviews, viewer: viewer) {
                let comments = try await client.pendingReviewComments(ref, reviewID: pending.id)
                state = PendingReviewState(reviewID: pending.id, nodeID: pending.nodeId,
                                           commitID: pending.commitId, summary: pending.body,
                                           comments: comments)
            }
            guard let index = prSessions.firstIndex(where: { $0.id == sessionID }) else { return true }
            // Reviews-list lag guard: a review this app just created can be
            // missing from the list for a beat (read-after-write). Comments
            // only the create response vouches for (no server id yet) must
            // not be dropped — and dropping the review would re-arm the
            // create path into a guaranteed 422. Keep the local truth; a
            // later adoption that sees the review reconciles ids normally.
            if state == nil,
               let local = prSessions[index].pendingReview,
               local.comments.contains(where: { $0.serverID == nil }) {
                adoptionKnown.insert(sessionID)
                return true
            }
            let reconciled = PendingReviewSync.reconcile(
                server: state?.comments ?? [],
                previousServer: prSessions[index].pendingReview?.comments ?? [],
                queue: prSessions[index].queuedComments)
            state?.comments = reconciled.server
            prSessions[index].pendingReview = state
            prSessions[index].queuedComments = reconciled.queue
            persistQueue(sessionID: sessionID)
            adoptionKnown.insert(sessionID)
            return true
        } catch {
            adoptionKnown.remove(sessionID)
            return false
        }
    }

    /// Drains the local queue into the server-side pending review. When a
    /// sync for this session is already in flight, waits for it to finish
    /// (comments added mid-flight get one more pass via the gate) instead
    /// of silently doing nothing.
    func syncPendingComments(sessionID: String) async {
        // Demo mode: nothing uploads — the queued comment deliberately
        // stays "Not synced" so both sync states stay visible.
        guard !DemoMode.active else { return }
        await pendingSyncGate.run(sessionID) { [weak self] in
            await self?.performPendingSyncPass(sessionID: sessionID)
        }
    }

    /// One drain pass: one atomic REST create when no pending review
    /// exists, GraphQL adds (FIFO) when one does — see GitHubClient's
    /// API-mix note. Failures keep the remainder queued and surface; a
    /// 422 from racing an externally created pending review is healed by
    /// re-adopting and retrying once.
    ///
    /// The create path runs at most once per pass. A successful create is
    /// its own proof: the response carries the review and every sent
    /// comment was accepted with it, so the sent comments move into the
    /// adopted state directly (PendingReviewSync.stateAfterCreate).
    /// Re-fetching instead would race GitHub's lagging reviews list — the
    /// fetch misses the just-created review, the loop re-enters the create
    /// path, and the second create 422s ("one pending review per PR")
    /// though the first one succeeded.
    private func performPendingSyncPass(sessionID: String) async {
        var attemptsLeft = 2
        var createdThisPass = false
        while attemptsLeft > 0 {
            attemptsLeft -= 1
            guard let queued = prSessions.first(where: { $0.id == sessionID })?.queuedComments,
                  !queued.isEmpty else { return }
            // Adoption unknown: an unseen pending review may exist — never
            // run the create path against it. Re-adopt; if still unknown,
            // keep the queue and show the same banner as missing comments.
            if !adoptionKnown.contains(sessionID) {
                guard await adoptPendingReview(sessionID: sessionID) else {
                    if let index = prSessions.firstIndex(where: { $0.id == sessionID }) {
                        prSessions[index].commentsUnavailable = true
                    }
                    return
                }
            }
            guard let session = prSessions.first(where: { $0.id == sessionID }),
                  !session.queuedComments.isEmpty else { return }
            do {
                if let pending = session.pendingReview {
                    for comment in session.queuedComments {
                        try await client.addPendingComment(reviewNodeID: pending.nodeID,
                                                           comment: comment)
                    }
                    // Adoption moves the uploaded comments from the queue to
                    // the server list in one publish; anything it kept queued
                    // was not accepted (or arrived mid-sync) — loop once more.
                    await adoptPendingReview(sessionID: sessionID)
                } else if !createdThisPass {
                    let sent = session.queuedComments
                    let created = try await client.createReview(
                        session.ref, commitID: session.details.head.sha,
                        body: nil, event: nil, comments: sent)
                    createdThisPass = true
                    if let created,
                       let index = prSessions.firstIndex(where: { $0.id == sessionID }) {
                        let outcome = PendingReviewSync.stateAfterCreate(
                            review: created, sent: sent,
                            queue: prSessions[index].queuedComments,
                            fallbackCommitID: session.details.head.sha)
                        // One synchronous publish: the adopted list and the
                        // queue its rows are filtered against move together.
                        prSessions[index].pendingReview = outcome.state
                        prSessions[index].queuedComments = outcome.queue
                        persistQueue(sessionID: sessionID)
                        adoptionKnown.insert(sessionID)
                    } else {
                        // Response shape drift: the review exists but wasn't
                        // decodable. Adopt to find it — quietly, and without
                        // ever re-entering the create path this pass.
                        await adoptPendingReview(sessionID: sessionID)
                    }
                } else {
                    // A create already ran this pass but no pending review
                    // is visible yet (reviews-list lag). Adopt-only, quiet:
                    // the comments are safe server-side or still queued for
                    // the next pass — a second create would 422.
                    await adoptPendingReview(sessionID: sessionID)
                    if prSessions.first(where: { $0.id == sessionID })?.pendingReview == nil {
                        return
                    }
                }
                guard let after = prSessions.first(where: { $0.id == sessionID }),
                      !after.queuedComments.isEmpty, attemptsLeft > 0 else { return }
            } catch {
                // The create may have lost to a review started elsewhere
                // (one pending review per user) — adopt it and retry as adds.
                await adoptPendingReview(sessionID: sessionID)
                if let after = prSessions.first(where: { $0.id == sessionID }),
                   after.pendingReview != nil, !after.queuedComments.isEmpty,
                   attemptsLeft > 0 { continue }
                let count = prSessions.first(where: { $0.id == sessionID })?
                    .queuedComments.count ?? 0
                if count > 0 {
                    lastError = "Could not upload \(count) pending comment\(count == 1 ? "" : "s") "
                        + "to GitHub — kept locally for retry. \(error.localizedDescription)"
                }
                return
            }
        }
    }

    /// Submits the review: the server-side pending review when one exists
    /// (after draining the queue — never silently dropping comments that
    /// failed to upload), otherwise a one-shot create-and-submit.
    func submitReview(sessionID: String, event: String, summary: String?) async throws {
        // Waits out any in-flight sync (the gate) then drains what's left
        // — mid-upload comments must never read as "could not be uploaded".
        await syncPendingComments(sessionID: sessionID)
        guard var session = prSessions.first(where: { $0.id == sessionID }) else {
            throw MessageError(message: "The PR session is no longer available.")
        }
        guard session.queuedComments.isEmpty else {
            let count = session.queuedComments.count
            throw MessageError(message: "\(count) comment\(count == 1 ? "" : "s") could not be "
                + "uploaded to GitHub, so the review was not submitted. Retry when you're back online.")
        }
        // Adoption unknown (e.g. identity resolution failed): a pending
        // review the app cannot see may exist, and the create path would
        // submit past it — establish the truth or refuse.
        if session.pendingReview == nil, !adoptionKnown.contains(sessionID) {
            guard await adoptPendingReview(sessionID: sessionID),
                  let refreshed = prSessions.first(where: { $0.id == sessionID }) else {
                throw MessageError(message: "Could not check GitHub for an existing pending review, "
                    + "so the review was not submitted. Check your connection and try again.")
            }
            session = refreshed
        }
        if let pending = session.pendingReview {
            // The events endpoint documents body as required for COMMENT and
            // REQUEST_CHANGES; an empty string satisfies it when the review
            // carries only comments.
            let body = summary ?? (event == "APPROVE" ? nil : "")
            try await client.submitReview(session.ref, reviewID: pending.reviewID,
                                          event: event, body: body)
        } else {
            try await client.createReview(session.ref, commitID: session.details.head.sha,
                                          body: summary, event: event, comments: [])
        }
        clearPendingState(sessionID: sessionID)
        await reloadComments(sessionID: sessionID)
        // The viewer's own verdict must show in the header without
        // waiting out the 60s tick.
        await refreshCockpit(sessionID: sessionID)
    }

    // MARK: - Conversation fold-ins (spec: pr-cockpit)

    /// All conversation writes fold the API's echo into the model
    /// locally — the comments list lags fresh writes (0.31.0 lesson;
    /// never refetch on mutation). Network calls live in
    /// ThreadCardActions, same as the review-thread family.
    func applyPostedConversationComment(sessionID: String, comment: IssueComment) {
        guard let index = prSessions.firstIndex(where: { $0.id == sessionID }),
              !prSessions[index].issueComments.contains(where: { $0.id == comment.id })
        else { return }
        prSessions[index].issueComments.append(comment)
        prSessions[index].conversationUnavailable = false
    }

    func applyConversationCommentEdit(sessionID: String, commentID: Int, body: String) {
        guard let index = prSessions.firstIndex(where: { $0.id == sessionID }),
              let at = prSessions[index].issueComments.firstIndex(where: { $0.id == commentID })
        else { return }
        prSessions[index].issueComments[at].body = body
        prSessions[index].conversationMeta[commentID]?.edited = true
    }

    func applyConversationCommentDelete(sessionID: String, commentID: Int) {
        guard let index = prSessions.firstIndex(where: { $0.id == sessionID }) else { return }
        prSessions[index].issueComments.removeAll { $0.id == commentID }
    }

    /// Conversation twin of applyReaction below: issue comments and
    /// review verdict cards key their meta directly by their own id —
    /// no thread-root indirection.
    func applyConversationReaction(sessionID: String, commentID: Int, content: String,
                                   reacted: Bool, isReview: Bool) {
        guard let index = prSessions.firstIndex(where: { $0.id == sessionID }) else { return }
        var session = prSessions[index]
        if isReview {
            let updated = CommentReactions.applied(
                rollup: session.reviewReactions[commentID] ?? ReactionRollup(),
                viewerReacted: session.reviewMeta[commentID]?.viewerReacted ?? [],
                content: content, reacted: reacted)
            session.reviewReactions[commentID] = updated.rollup
            session.reviewMeta[commentID]?.viewerReacted = updated.viewerReacted
        } else {
            guard let at = session.issueComments.firstIndex(where: { $0.id == commentID })
            else { return }
            let updated = CommentReactions.applied(
                rollup: session.issueComments[at].reactions ?? ReactionRollup(),
                viewerReacted: session.conversationMeta[commentID]?.viewerReacted ?? [],
                content: content, reacted: reacted)
            session.issueComments[at].reactions = updated.rollup
            session.conversationMeta[commentID]?.viewerReacted = updated.viewerReacted
        }
        prSessions[index] = session
    }

    /// Discards the pending review server-side (GitHub's "Abandon review")
    /// along with the local queue and persisted summary.
    func abandonPendingReview(sessionID: String) async {
        guard let session = prSessions.first(where: { $0.id == sessionID }) else { return }
        do {
            if let pending = session.pendingReview {
                try await client.deletePendingReview(session.ref, reviewID: pending.reviewID)
            }
            clearPendingState(sessionID: sessionID)
        } catch {
            lastError = "Could not abandon the review: \(error.localizedDescription)"
        }
    }

    private func clearPendingState(sessionID: String) {
        guard let index = prSessions.firstIndex(where: { $0.id == sessionID }) else { return }
        prSessions[index].pendingReview = nil
        prSessions[index].queuedComments = []
        persistQueue(sessionID: sessionID)
        PendingReviewStore.saveSummary(nil, ref: prSessions[index].ref)
    }

    private func persistQueue(sessionID: String) {
        guard let session = prSessions.first(where: { $0.id == sessionID }) else { return }
        PendingReviewStore.saveQueue(session.queuedComments, ref: session.ref,
                                     headSHA: session.details.head.sha)
    }
}

/// Delivers menu commands to whichever detail view owns the state they act
/// on. A plain `.onChange` inline in those views pushed SwiftUI's type
/// checker over its limit, so it lives here as a modifier.
struct DocumentCommandHandler: ViewModifier {
    @ObservedObject var state: AppState
    let handle: (DocumentCommandRequest?) -> Void

    func body(content: Content) -> some View {
        content.onChange(of: state.documentCommand) { handle($0) }
    }
}
