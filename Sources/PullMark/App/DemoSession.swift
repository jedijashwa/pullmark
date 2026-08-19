import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

/// The curated content behind `PM_DEMO=1` (see DemoMode): a fictional
/// documentation repo — "Meridian", an imaginary open-source weather
/// station — with one staged pull request exercising the whole review
/// wave: threads (replied, resolved, outdated), reactions (some
/// viewer-owned), an edited comment, and a pending review with mixed
/// uploaded/queued comments. Everything here is invented; nothing traces
/// to a real person, repo, or brand.
///
/// This file is DATA, not product logic. It is only ever reached behind
/// `DemoMode.active` checks (AppState fabricates the session from it;
/// GitHubClient serves file content, blame, and history from it instead
/// of the network).
enum DemoSession {
    // MARK: - Identity

    static let owner = "meridian-instruments"
    static let repo = "meridian-docs"
    static let number = 128
    static let ref = PullRequestRef(owner: owner, repo: repo, number: number)

    /// The "signed-in" demo user — authors the pending review and one
    /// thread reply, owns some reactions.
    static let viewerLogin = "sam-ortega"
    static let prAuthor = "priya-raman"
    static let reviewer = "tobias-lund"

    static let headSHA = "b7e4c9a1f0d2e8b3a6c5d4e7f8a9b0c1d2e3f4a5"
    static let baseSHA = "3f8a2b7c6d5e4f3a2b1c0d9e8f7a6b5c4d3e2f1a"

    // MARK: - Documents

    static let gettingStartedPath = "docs/getting-started.md"
    static let calibrationPath = "docs/calibration.md"
    static let exportFormatsPath = "docs/export-formats.md"
    static let firmwarePath = "firmware/anemometer.cpp"

    /// A local-only draft carrying margin notes — the agent-review loop
    /// the feature was built for, ready for screenshots. Deliberately
    /// NOT in headTexts: it must never leak into the PR fixture, whose
    /// diffs and cockpit are curated separately.
    static let siteSurveyDraft = """
    # Site Survey Guide (draft)

    Where you mount the pod decides what your numbers mean. This guide
    walks a new site from "looks fine" to measured, repeatable placement.

    <!-- note @sam-ortega: Draft for the 1.3 docs — leaving placement notes inline, address and delete as you go. -->

    ## Picking a spot

    Radiation shields help, but nothing rescues a sensor mounted over
    asphalt. Grass or gravel below, two meters of clearance around, and
    morning sun exposure make a defensible default.

    <!-- note @elena-fisk: "defensible default" reads like legal copy — say what the tradeoff actually is. -->

    ## Height and clearance

    Mount the pod at 1.5 m for garden sites and 2 m for rooftops. Keep
    the anemometer arm above the roofline's turbulence layer — a rule of
    thumb is 1.3× the height of the nearest obstruction.

    ## Recording the survey

    Photograph the site from all four compass points and log the mount
    height in the station's site profile. Future you, comparing a
    suspicious trend, will want to know exactly what changed and when.
    """

    static let gettingStartedBase = """
    # Getting Started

    Meridian is an open-source weather station you assemble yourself: a
    sensor pod, a base station, and this documentation.

    ## What's in the kit

    - Base station with the display board
    - Outdoor sensor pod (temperature, humidity, pressure)
    - Mounting bracket and stainless fasteners
    - USB-C cable and wall adapter

    ## First boot

    1. Insert the sensor batteries.
    2. Plug in the base station.
    3. Wait for the pairing chime.

    The display shows live readings within a minute of pairing.

    ## Where to go next

    - [Calibration](calibration.md) tunes the sensors to your site.
    """

    static let gettingStartedHead = """
    # Getting Started

    Meridian is an open-source weather station you assemble yourself: a
    sensor pod, a base station, and this documentation.

    ## What's in the kit

    - Base station with the display board
    - Outdoor sensor pod (temperature, humidity, pressure)
    - Anemometer arm with three-cup rotor
    - Mounting bracket and stainless fasteners
    - USB-C cable and wall adapter

    ## First boot

    1. Insert the sensor batteries.
    2. Plug in the base station.
    3. Hold the pair button until the ring pulses blue.
    4. Wait for the pairing chime.

    The display shows live readings within a minute of pairing.

    ## Where to go next

    - [Calibration](calibration.md) tunes the sensors to your site.
    - [Export formats](export-formats.md) covers getting data out.
    """

    static let calibrationBase = """
    # Sensor Calibration

    Factory calibration gets you close. Site calibration gets you honest
    numbers — every rooftop, balcony, and garden biases the sensors in
    its own way.

    ## When to calibrate

    Calibrate after first assembly, after replacing a sensor, and once a
    season thereafter.

    ## Temperature offset

    Place a reference thermometer beside the pod, wait ten minutes, and
    compare:

    ```meridian
    calibrate temp --reference 21.4
    ```

    The offset is stored on the pod and survives battery changes.

    ## Reading the drift log

    The base station keeps a drift log you can print:

    ```meridian
    drift --since 30d
    ```

    Small daily drift is normal; a step change usually means condensation
    in the housing.
    """

    static let calibrationHead = """
    # Sensor Calibration

    Factory calibration gets you close. Site calibration gets you honest
    numbers — every rooftop, balcony, and garden biases the sensors in
    its own way.

    ## When to calibrate

    Calibrate after first assembly, after replacing a sensor, and once a
    season thereafter. The cycle is short:

    ```mermaid
    flowchart LR
        A[Assemble] --> B[Warm up 10 min]
        B --> C{Reference match?}
        C -- yes --> D[Log baseline]
        C -- no --> E[Apply offset]
        E --> B
    ```

    ## Temperature offset

    Place a reference thermometer beside the pod, wait ten minutes, and
    compare:

    ```meridian
    calibrate temp --reference 21.4
    ```

    The offset is stored on the pod and survives battery changes.

    ## Humidity offsets

    Humidity sensors age faster than the rest of the pod. Check them
    against the salt test twice a year:

    | Solution | Expected RH | Acceptable range |
    | --- | --- | --- |
    | Lithium chloride | 11% | 9–13% |
    | Magnesium chloride | 33% | 31–35% |
    | Sodium chloride | 75% | 73–77% |

    Apply the measured offset with:

    ```meridian
    calibrate humidity --reference 75.0
    ```

    ## Reading the drift log

    The base station keeps a drift log you can print:

    ```meridian
    drift --since 30d
    ```

    Small daily drift is normal; a step change usually means condensation
    in the housing.
    """

    static let exportFormatsHead = """
    # Export Formats

    Every reading the station has ever taken can leave the station. Three
    formats cover the common destinations.

    ## CSV

    The default. One row per reading, one file per sensor:

    ```meridian
    export csv --sensor humidity --since 2026-01-01
    ```

    | Column  | Type     | Notes                                 |
    | ------- | -------- | ------------------------------------- |
    | `ts`    | ISO 8601 | Station-local time                    |
    | `value` | float    | Unit follows the sensor               |
    | `flags` | string   | `E` estimated, `C` post-calibration   |

    ## JSON Lines

    For piping into anything programmable. Each line is a self-contained
    object, so a broken transfer still parses up to the break.

    ## Home dashboards

    The station speaks MQTT out of the box:

    1. Point it at your broker in **Settings → Integrations**.
    2. Subscribe to `meridian/<station-id>/#`.
    3. Readings arrive as they are taken.

    No cloud account, no telemetry — your data stays on your network.
    """

    /// Head-revision content by repo path (what `fileContent` serves for
    /// the head SHA, and what the demo local files contain).
    static let headTexts: [String: String] = [
        gettingStartedPath: gettingStartedHead,
        calibrationPath: calibrationHead,
        exportFormatsPath: exportFormatsHead,
    ]

    /// Merge-base content by repo path (served for the base SHA).
    static let baseTexts: [String: String] = [
        gettingStartedPath: gettingStartedBase,
        calibrationPath: calibrationBase,
    ]

    /// Offline stand-in for the contents API: head text at the head SHA,
    /// base text at the merge-base SHA. Nil for anything else — the
    /// caller surfaces the same error a real 404 would.
    static func fileContent(path: String, at sha: String) -> String? {
        if sha == headSHA { return headTexts[path] }
        if sha == baseSHA { return baseTexts[path] }
        return nil
    }

    // MARK: - Patches (real unified diffs of base → head, generated with
    // git and embedded verbatim; DemoSessionTests verifies every hunk
    // line against the texts above)

    static let gettingStartedPatch = """
    @@ -7,6 +7,7 @@ sensor pod, a base station, and this documentation.

     - Base station with the display board
     - Outdoor sensor pod (temperature, humidity, pressure)
    +- Anemometer arm with three-cup rotor
     - Mounting bracket and stainless fasteners
     - USB-C cable and wall adapter

    @@ -14,10 +15,12 @@ sensor pod, a base station, and this documentation.

     1. Insert the sensor batteries.
     2. Plug in the base station.
    -3. Wait for the pairing chime.
    +3. Hold the pair button until the ring pulses blue.
    +4. Wait for the pairing chime.

     The display shows live readings within a minute of pairing.

     ## Where to go next

     - [Calibration](calibration.md) tunes the sensors to your site.
    +- [Export formats](export-formats.md) covers getting data out.
    """

    static let calibrationPatch = """
    @@ -7,7 +7,16 @@ its own way.
     ## When to calibrate

     Calibrate after first assembly, after replacing a sensor, and once a
    -season thereafter.
    +season thereafter. The cycle is short:
    +
    +```mermaid
    +flowchart LR
    +    A[Assemble] --> B[Warm up 10 min]
    +    B --> C{Reference match?}
    +    C -- yes --> D[Log baseline]
    +    C -- no --> E[Apply offset]
    +    E --> B
    +```

     ## Temperature offset

    @@ -20,6 +29,23 @@ calibrate temp --reference 21.4

     The offset is stored on the pod and survives battery changes.

    +## Humidity offsets
    +
    +Humidity sensors age faster than the rest of the pod. Check them
    +against the salt test twice a year:
    +
    +| Solution | Expected RH | Acceptable range |
    +| --- | --- | --- |
    +| Lithium chloride | 11% | 9–13% |
    +| Magnesium chloride | 33% | 31–35% |
    +| Sodium chloride | 75% | 73–77% |
    +
    +Apply the measured offset with:
    +
    +```meridian
    +calibrate humidity --reference 75.0
    +```
    +
     ## Reading the drift log

     The base station keeps a drift log you can print:
    """

    /// A brand-new file's patch is one all-additions hunk.
    static let exportFormatsPatch: String = {
        let lines = exportFormatsHead.components(separatedBy: "\n")
        return "@@ -0,0 +1,\(lines.count) @@\n"
            + lines.map { "+" + $0 }.joined(separator: "\n")
    }()

    static let files: [PullRequestFile] = [
        PullRequestFile(filename: gettingStartedPath, status: "modified",
                        additions: 4, deletions: 1,
                        patch: gettingStartedPatch, previousFilename: nil),
        PullRequestFile(filename: calibrationPath, status: "modified",
                        additions: 27, deletions: 1,
                        patch: calibrationPatch, previousFilename: nil),
        PullRequestFile(filename: exportFormatsPath, status: "added",
                        additions: 33, deletions: 0,
                        patch: exportFormatsPatch, previousFilename: nil),
        // A non-Markdown file so the overview's honesty lines ("1 other
        // file not shown", comments on hidden files) have something real
        // to count. Never rendered, so no patch is needed.
        PullRequestFile(filename: firmwarePath, status: "modified",
                        additions: 24, deletions: 6,
                        patch: nil, previousFilename: nil),
    ]

    // MARK: - Pull request

    static let details = PullRequestDetails(
        number: number,
        title: "Document sensor calibration and data export",
        body: """
        The calibration guide only covered temperature. This adds humidity
        offsets (the salt test), a quick calibration-cycle diagram, and a
        new export-formats page.

        - **New:** `docs/export-formats.md` — CSV, JSON Lines, MQTT
        - Humidity offsets table with the three reference solutions
        - First-boot steps now mention the pair button

        The firmware side of the anemometer change rides along so the kit
        list and the shipped hardware stay in step.
        """,
        state: "open",
        draft: false,
        merged: false,
        head: PullRequestDetails.CommitRef(sha: headSHA, ref: "docs/calibration-guide"),
        base: PullRequestDetails.CommitRef(sha: baseSHA, ref: "main"),
        htmlUrl: URL(string: "https://github.com/\(owner)/\(repo)/pull/\(number)")!,
        user: PullRequestDetails.User(login: prAuthor)
    )

    // MARK: - Review conversations

    // Comment ids (REST databaseIds elsewhere in the app).
    static let threadReplyRootID = 9001      // multi-comment thread, calibration.md
    static let threadReplyID = 9002
    static let threadResolvedRootID = 9101   // resolved, getting-started.md
    static let threadOutdatedRootID = 9201   // outdated, calibration.md
    static let hiddenFileCommentID = 9301    // firmware file (not shown in PullMark)

    static let reviewComments: [ReviewComment] = [
        // Unresolved thread on the salt-test table (RIGHT line 41 =
        // "| Sodium chloride | 75% | 73–77% |"). Root is edited and
        // carries reactions, one of them the viewer's.
        ReviewComment(id: threadReplyRootID, path: calibrationPath,
                      body: "Should we mention how long the salt jars need to "
                          + "equilibrate? Mine took closer to eight hours before "
                          + "the reading settled.",
                      line: 41, side: "RIGHT", startLine: nil, originalLine: 41,
                      subjectType: nil, inReplyToId: nil,
                      pullRequestReviewId: inlineReviewID,
                      user: ReviewComment.User(login: reviewer),
                      createdAt: "2026-07-27T09:24:00Z",
                      htmlUrl: nil,
                      diffHunk: "@@ -38,5 +38,6 @@\n"
                          + " | Salt | Expected RH | Acceptable |\n"
                          + " | ---- | ----------- | ---------- |\n"
                          + "+| Sodium chloride | 75% | 73–77% |",
                      reactions: ReactionRollup(plusOne: 2, eyes: 1)),
        ReviewComment(id: threadReplyID, path: calibrationPath,
                      body: "Good call — eight to twelve depending on jar volume. "
                          + "I'll add a note under the table.",
                      line: 41, side: "RIGHT", startLine: nil, originalLine: 41,
                      subjectType: nil, inReplyToId: threadReplyRootID,
                      pullRequestReviewId: inlineReviewID,
                      user: ReviewComment.User(login: viewerLogin),
                      createdAt: "2026-07-27T10:02:00Z",
                      htmlUrl: nil,
                      reactions: ReactionRollup(heart: 1)),
        // Resolved thread on the new pairing step (RIGHT line 18).
        ReviewComment(id: threadResolvedRootID, path: gettingStartedPath,
                      body: "The pairing chime is easy to miss in a loud room — "
                          + "worth saying the ring also turns solid green.",
                      line: 18, side: "RIGHT", startLine: nil, originalLine: 18,
                      subjectType: nil, inReplyToId: nil,
                      pullRequestReviewId: inlineReviewID,
                      user: ReviewComment.User(login: reviewer),
                      createdAt: "2026-07-26T15:40:00Z",
                      htmlUrl: nil,
                      reactions: ReactionRollup(hooray: 1)),
        // Outdated thread: the line it anchored to moved in a later push
        // (line nil, originalLine kept — GitHub's outdated shape).
        ReviewComment(id: threadOutdatedRootID, path: calibrationPath,
                      body: "This intro paragraph ran long in the first draft — "
                          + "flagging in case the trim dropped the balcony example "
                          + "on purpose.",
                      line: nil, side: "RIGHT", startLine: nil, originalLine: 10,
                      subjectType: nil, inReplyToId: nil,
                      pullRequestReviewId: inlineReviewID,
                      user: ReviewComment.User(login: prAuthor),
                      createdAt: "2026-07-25T11:12:00Z",
                      htmlUrl: nil,
                      diffHunk: "@@ -8,4 +8,5 @@\n"
                          + " sensor once a season.\n"
                          + "+Calibrating on a balcony overstates drift on gusty\n"
                          + "+days, so the intro walks through an indoor first pass.",
                      reactions: ReactionRollup()),
        // A comment on a file PullMark doesn't render — feeds the
        // overview's "review comments on files not shown" line, and the
        // review discussion list when that experiment is on.
        ReviewComment(id: hiddenFileCommentID, path: firmwarePath,
                      body: "Debounce interval seems aggressive for gusty sites.",
                      line: 42, side: "RIGHT", startLine: nil, originalLine: 42,
                      subjectType: nil, inReplyToId: nil,
                      pullRequestReviewId: inlineReviewID,
                      user: ReviewComment.User(login: reviewer),
                      createdAt: "2026-07-27T08:05:00Z",
                      htmlUrl: nil,
                      diffHunk: "@@ -36,9 +36,9 @@ void anemometer_isr() {\n"
                          + "     const uint32_t now = micros();\n"
                          + "-    if (now - last_edge < 2000) {\n"
                          + "+    if (now - last_edge < DEBOUNCE_US) {\n"
                          + "         return;\n"
                          + "     }",
                      reactions: ReactionRollup()),
    ]

    /// GraphQL-shaped thread state: resolution, per-comment node ids,
    /// viewer reactions, edited flags. Keyed by thread root id like the
    /// real adoption path.
    static let threadMeta: [Int: ThreadMeta] = [
        threadReplyRootID: ThreadMeta(
            nodeID: "PMDEMO_THREAD_A", isResolved: false,
            comments: [
                threadReplyRootID: ReviewCommentMeta(
                    nodeID: "PMDEMO_C9001",
                    viewerReacted: ["+1"],
                    edited: true,
                    reactors: ["+1": ReactorRoster(logins: [viewerLogin, prAuthor],
                                                   totalCount: 2),
                               "eyes": ReactorRoster(logins: [reviewer],
                                                     totalCount: 1)]),
                threadReplyID: ReviewCommentMeta(
                    nodeID: "PMDEMO_C9002",
                    reactors: ["heart": ReactorRoster(logins: [reviewer],
                                                      totalCount: 1)]),
            ]),
        threadResolvedRootID: ThreadMeta(
            nodeID: "PMDEMO_THREAD_B", isResolved: true,
            comments: [
                threadResolvedRootID: ReviewCommentMeta(nodeID: "PMDEMO_C9101"),
            ]),
        threadOutdatedRootID: ThreadMeta(
            nodeID: "PMDEMO_THREAD_C", isResolved: false,
            comments: [
                threadOutdatedRootID: ReviewCommentMeta(nodeID: "PMDEMO_C9201"),
            ]),
        hiddenFileCommentID: ThreadMeta(
            nodeID: "PMDEMO_THREAD_D", isResolved: false,
            comments: [
                hiddenFileCommentID: ReviewCommentMeta(nodeID: "PMDEMO_C9301"),
            ]),
    ]

    // MARK: - Pending review (the viewer's, unsubmitted)

    /// Two comments GitHub has "accepted" (server ids → yellow Pending
    /// tag) …
    static let uploadedPendingComments: [PendingComment] = [
        PendingComment(serverID: 9_900_101,
                       path: calibrationPath,
                       lineStart: 40, lineEnd: 40, side: "RIGHT",
                       body: "Magnesium chloride is hard to source food-grade — "
                           + "worth pointing at the pool-supply kind?"),
        PendingComment(serverID: 9_900_102,
                       path: exportFormatsPath,
                       lineStart: 29, lineEnd: 31, side: "RIGHT",
                       body: "Love this. Could we show one sample topic and "
                           + "payload here?"),
    ]

    /// … and one still queued locally ("Not synced" in the popover).
    static let queuedPendingComments: [PendingComment] = [
        PendingComment(serverID: nil,
                       path: gettingStartedPath,
                       lineStart: 10, lineEnd: 10, side: "RIGHT",
                       body: "The kit photos still show the two-cup rotor — "
                           + "flagging so we swap the image before release."),
    ]

    static let pendingSummary =
        "Reads well overall — a few small sourcing and imagery notes."

    static func makePendingReview() -> PendingReviewState {
        PendingReviewState(reviewID: 9_900_001,
                           nodeID: "PMDEMO_REVIEW",
                           commitID: headSHA,
                           summary: pendingSummary,
                           comments: uploadedPendingComments)
    }

    // MARK: - Cockpit (spec: pr-cockpit)

    static let approver = "elena-fisk"
    static let botLogin = "docs-ci"

    private static func demoAvatar(_ login: String) -> URL? {
        avatarURIs[login].flatMap(URL.init(string:))
    }

    /// Where the demo PR stands: changes requested (Tobias), one
    /// approval (Elena), the viewer's own review awaited plus a team —
    /// every strip state on screen at once. Checks are settled green
    /// with one skip; no detail links (demo mode is offline).
    static let cockpit: PRCockpitState = {
        var state = PRCockpitState()
        state.reviewDecision = .changesRequested
        state.reviewers = [
            ReviewerState(login: reviewer, avatarUrl: demoAvatar(reviewer),
                          approved: false, submittedAt: "2026-08-15T09:41:00Z"),
            ReviewerState(login: approver, avatarUrl: demoAvatar(approver),
                          approved: true, submittedAt: "2026-08-16T15:20:00Z"),
        ]
        state.reviewRequests = [
            ReviewRequestEntry(name: viewerLogin, avatarUrl: demoAvatar(viewerLogin),
                               isTeam: false),
            ReviewRequestEntry(name: "docs-guild", avatarUrl: nil, isTeam: true),
        ]
        state.checks = [
            CheckItem(name: "build", group: "CI", state: .passed,
                      detailsUrl: nil, isRequired: true, durationLabel: "1m 32s"),
            CheckItem(name: "docs-links", group: "CI", state: .passed,
                      detailsUrl: nil, isRequired: false, durationLabel: "48s"),
            CheckItem(name: "spellcheck", group: "CI", state: .skipped,
                      detailsUrl: nil, isRequired: false, durationLabel: nil),
            CheckItem(name: "license/cla", group: nil, state: .passed,
                      detailsUrl: nil, isRequired: false, durationLabel: nil),
        ]
        state.checksTotal = state.checks.count
        return state
    }()

    static let issueCommentReadyID = 9501
    static let issueCommentViewerID = 9502
    static let issueCommentBotID = 9503
    static let reviewChangesID = 9601
    static let reviewApprovedID = 9602
    /// The empty-COMMENTED review that submitted the inline threads —
    /// the timeline's "tobias-lund reviewed" anchor they nest under.
    static let inlineReviewID = 9600

    static let issueComments: [IssueComment] = [
        IssueComment(id: issueCommentReadyID,
                     body: "Ready for a first pass — the humidity table is the "
                         + "part I'm least sure about.",
                     user: .init(login: prAuthor, avatarUrl: demoAvatar(prAuthor)),
                     createdAt: "2026-08-14T16:05:00Z", htmlUrl: nil,
                     reactions: ReactionRollup(heart: 2)),
        IssueComment(id: issueCommentViewerID,
                     body: "Reading through this afternoon.",
                     user: .init(login: viewerLogin, avatarUrl: demoAvatar(viewerLogin)),
                     createdAt: "2026-08-15T11:12:00Z", htmlUrl: nil),
        IssueComment(id: issueCommentBotID,
                     body: "Link check passed: 42 links, 0 broken.",
                     user: .init(login: botLogin, avatarUrl: demoAvatar(botLogin),
                                 type: "Bot"),
                     createdAt: "2026-08-16T15:24:00Z", htmlUrl: nil),
    ]

    static let conversationReviews: [PullRequestReview] = [
        PullRequestReview(id: inlineReviewID, nodeId: "PRR_demo9600",
                          user: .init(login: reviewer, avatarUrl: demoAvatar(reviewer)),
                          body: "", state: "COMMENTED", commitId: headSHA,
                          submittedAt: "2026-07-27T09:30:00Z", htmlUrl: nil),
        PullRequestReview(id: reviewChangesID, nodeId: "PRR_demo9601",
                          user: .init(login: reviewer, avatarUrl: demoAvatar(reviewer)),
                          body: "The salt-test table lists two of the three "
                              + "reference solutions — add the 75% RH row and "
                              + "this is good to go.",
                          state: "CHANGES_REQUESTED", commitId: headSHA,
                          submittedAt: "2026-08-15T09:41:00Z", htmlUrl: nil),
        PullRequestReview(id: reviewApprovedID, nodeId: "PRR_demo9602",
                          user: .init(login: approver, avatarUrl: demoAvatar(approver)),
                          body: "", state: "APPROVED", commitId: headSHA,
                          submittedAt: "2026-08-16T15:20:00Z", htmlUrl: nil),
    ]

    static let conversationMeta: [Int: ReviewCommentMeta] = [
        issueCommentReadyID: ReviewCommentMeta(
            nodeID: "IC_demo9501", viewerReacted: ["heart"], edited: false,
            reactors: ["heart": ReactorRoster(logins: [viewerLogin, reviewer],
                                              totalCount: 2)]),
        issueCommentViewerID: ReviewCommentMeta(nodeID: "IC_demo9502"),
        issueCommentBotID: ReviewCommentMeta(nodeID: "IC_demo9503"),
    ]

    static let reviewMeta: [Int: ReviewCommentMeta] = [
        inlineReviewID: ReviewCommentMeta(nodeID: "PRR_demo9600"),
        reviewChangesID: ReviewCommentMeta(
            nodeID: "PRR_demo9601", viewerReacted: [], edited: false,
            reactors: ["+1": ReactorRoster(logins: [prAuthor], totalCount: 1)]),
        reviewApprovedID: ReviewCommentMeta(nodeID: "PRR_demo9602"),
    ]

    static let reviewReactions: [Int: ReactionRollup] = [
        reviewChangesID: ReactionRollup(plusOne: 1),
    ]

    // MARK: - Session assembly

    /// The fabricated PR session, exactly as `addPR` would have built it
    /// from live responses.
    static func makeSession() -> PRSession {
        var session = PRSession(ref: ref, details: details,
                                mergeBaseSHA: baseSHA, files: files)
        session.reviewComments = reviewComments
        session.threadMeta = threadMeta
        session.pendingReview = makePendingReview()
        session.queuedComments = queuedPendingComments
        session.cockpit = cockpit
        session.issueComments = issueComments
        session.reviews = conversationReviews
        session.conversationMeta = conversationMeta
        session.reviewMeta = reviewMeta
        session.reviewReactions = reviewReactions
        return session
    }

    // MARK: - Local documents

    /// Writes the head-revision docs into a fresh temp folder and returns
    /// them as sidebar entries — real files, so the local-file pipeline
    /// (rendering, watching, outline) works untouched. Temp-dir only:
    /// purgeable, never inside a real repo.
    static func installLocalDocs() -> [LocalFile] {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PullMark Demo", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var docs: [LocalFile] = []
        var texts = [(path: String, text: String)]()
        for path in [gettingStartedPath, calibrationPath, exportFormatsPath] {
            guard let text = headTexts[path] else { continue }
            texts.append((path, text))
        }
        texts.append(("docs/site-survey-draft.md", siteSurveyDraft))
        for (path, text) in texts {
            let name = (path as NSString).lastPathComponent
            let url = root.appendingPathComponent(name)
            guard (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil
            else { continue }
            docs.append(LocalFile(url: url, displayName: name, resourceRoot: root))
        }
        return docs
    }

    // MARK: - Blame & history (feeds the existing avatar pipeline with
    // locally generated data-URI avatars — no network fetches)

    struct Author {
        let login: String
        let name: String
        let initials: String
        let color: (red: CGFloat, green: CGFloat, blue: CGFloat)
    }

    static let authors: [String: Author] = [
        prAuthor: Author(login: prAuthor, name: "Priya Raman", initials: "PR",
                         color: (0.72, 0.32, 0.44)),
        reviewer: Author(login: reviewer, name: "Tobias Lund", initials: "TL",
                         color: (0.30, 0.38, 0.70)),
        viewerLogin: Author(login: viewerLogin, name: "Sam Ortega", initials: "SO",
                            color: (0.22, 0.56, 0.50)),
        approver: Author(login: approver, name: "Elena Fisk", initials: "EF",
                         color: (0.58, 0.44, 0.24)),
        botLogin: Author(login: botLogin, name: "Docs CI", initials: "DC",
                         color: (0.45, 0.45, 0.50)),
    ]

    /// login → data-URI avatar, generated once per process.
    static let avatarURIs: [String: String] = authors.mapValues {
        DemoAvatars.dataURI(initials: $0.initials, red: $0.color.red,
                            green: $0.color.green, blue: $0.color.blue)
    }

    private static func commit(sha: String, author: Author, daysAgo: Double,
                               summary: String) -> BlameCommit {
        BlameCommit(sha: sha,
                    authorName: author.name,
                    authorEmail: nil,
                    date: Date().addingTimeInterval(-daysAgo * 86_400),
                    summary: summary,
                    userAvatarUrl: avatarURIs[author.login],
                    actorAvatarUrl: nil,
                    url: nil)
    }

    static var headCommit: BlameCommit {
        commit(sha: headSHA, author: authors[prAuthor]!, daysAgo: 2,
               summary: "Document sensor calibration and data export")
    }
    static var walkthroughCommit: BlameCommit {
        commit(sha: "8c21d4f7a9b0e3c6d5f8a1b4c7d0e3f6a9b2c5d8",
               author: authors[reviewer]!, daysAgo: 123,
               summary: "Getting started: first-boot walkthrough")
    }
    static var importCommit: BlameCommit {
        commit(sha: "5d9e8f7a6b5c4d3e2f1a0b9c8d7e6f5a4b3c2d1e",
               author: authors[viewerLogin]!, daysAgo: 415,
               summary: "Initial documentation import")
    }

    /// Per-line blame at the head revision. Ranges cover every line of
    /// each doc (verified by DemoSessionTests), with the PR's own commit
    /// on the lines it changed.
    static func blameRanges(path: String) -> [BlameRange] {
        let head = headCommit, mid = walkthroughCommit, old = importCommit
        switch path {
        case gettingStartedPath:
            return [BlameRange(start: 1, end: 9, commit: mid),
                    BlameRange(start: 10, end: 10, commit: head),
                    BlameRange(start: 11, end: 17, commit: mid),
                    BlameRange(start: 18, end: 19, commit: head),
                    BlameRange(start: 20, end: 25, commit: old),
                    BlameRange(start: 26, end: 26, commit: head)]
        case calibrationPath:
            return [BlameRange(start: 1, end: 8, commit: old),
                    BlameRange(start: 9, end: 19, commit: head),
                    BlameRange(start: 20, end: 31, commit: mid),
                    BlameRange(start: 32, end: 47, commit: head),
                    BlameRange(start: 48, end: 58, commit: old)]
        case exportFormatsPath:
            return [BlameRange(start: 1, end: 33, commit: head)]
        default:
            return []
        }
    }

    /// File history for the History panel, newest first.
    static func historyCommits() -> [BlameCommit] {
        [headCommit, walkthroughCommit, importCommit]
    }

    /// Commits on the PR branch (splits the History panel).
    static let prCommitSHAs: [String] = [headSHA]
}

/// Colored-initials avatars rendered in-process (CoreGraphics + CoreText)
/// and embedded as PNG data URIs, so the demo feeds the exact pipeline
/// real GitHub avatar URLs use — with zero network.
enum DemoAvatars {
    static func dataURI(initials: String, red: CGFloat, green: CGFloat,
                        blue: CGFloat) -> String {
        guard let png = pngData(initials: initials, red: red, green: green,
                                blue: blue) else { return "" }
        return "data:image/png;base64," + png.base64EncodedString()
    }

    static func pngData(initials: String, red: CGFloat, green: CGFloat,
                        blue: CGFloat, size: Int = 64) -> Data? {
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: size, height: size,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: size, height: size)
        context.setFillColor(CGColor(colorSpace: space,
                                     components: [red, green, blue, 1]) ?? .black)
        // A filled circle on transparency, like GitHub's rounded avatars.
        context.fillEllipse(in: bounds)

        let font = CTFontCreateWithName("Helvetica-Bold" as CFString,
                                        CGFloat(size) * 0.42, nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(colorSpace: space,
                                                     components: [1, 1, 1, 1]) ?? .white,
        ]
        let attributed = CFAttributedStringCreate(nil, initials as CFString,
                                                  attributes as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attributed)
        let textBounds = CTLineGetImageBounds(line, context)
        context.textPosition = CGPoint(
            x: bounds.midX - textBounds.midX,
            y: bounds.midY - textBounds.midY)
        CTLineDraw(line, context)

        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
