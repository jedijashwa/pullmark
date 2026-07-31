# Open Quickly: On This Mac

Give ⌘K a second result tier that finds Markdown files and folders
anywhere in the home directory — so a pasted relative link resolves
even when its folder was never opened.

## Motivation

Open Quickly (⌘K) fuzzy-matches only what is already in memory: open
files, opened-folder contents, PR files, the review-request inbox,
recents, and the active document's headings. The single route to an
unopened file on disk is typing an exact absolute or `~` path.

The trigger scenario: copy a relative link like `docs/guide/setup.md`
out of a document, paste it into ⌘K while that folder isn't open —
nothing matches, and the only recourse is manually typing the path
prefix until the direct-destination row appears. An adjacent silent
failure feeds the same itch: clicking a relative link in a rendered
document that points outside the file's resource root is dropped with
no open and no error, which is part of why links get copied and
pasted into ⌘K in the first place.

No mainstream editor's quick-open reaches outside its
project/vault/library — this borrows a *launcher* capability into an
editor surface, which is differentiation, and means launcher
conventions are the design guide.

## Research summary

Feature-researcher survey, July 2026:

- **Launchers treat disk results as a deliberate, lower-trust tier.**
  Alfred requires a spacebar prefix or keyword to search files at
  all; LaunchBar hands whole-disk search off to Spotlight; Raycast
  blends file results into root search but below apps/commands, from
  its own gitignore-respecting index ([Alfred spacebar
  trick](https://www.alfredapp.com/blog/tips-and-tricks/spacebar-trick/),
  [Raycast file search](https://manual.raycast.com/file-search),
  [LaunchBar](https://www.obdev.at/products/launchbar/features.html)).
- **VS Code ⌘P and Xcode Open Quickly are workspace-scoped**, and
  their top user complaints are about *unwanted* out-of-scope results
  leaking in ([vscode#44126](https://github.com/Microsoft/vscode/issues/44126),
  [Apple forums 736808](https://developer.apple.com/forums/thread/736808))
  — supporting a clearly labeled, visually separated tier over silent
  blending. Obsidian is vault-only; iA Writer searches its Library
  locations only.
- **The Safari address-bar lesson**: instant local results render on
  top and async suggestions append *below*; when async arrival moves
  the selection, users file it as a bug. The rule: a slower tier only
  ever appends, and never touches the current selection.
- **Spotlight indexes Markdown *names*, not content** — macOS ships
  no Markdown content importer, long-standing and unchanged
  ([Terpstra](https://brettterpstra.com/2011/10/18/fixing-spotlight-indexing-of-markdown-content/)).
  Name matching is exactly what this feature needs.
- **Paths are not queryable.** `NSMetadataQuery` predicates match
  file names (`kMDItemFSName`), and a result's path is retrievable
  but not predicable ([Apple metadata query
  guide](https://developer.apple.com/library/archive/documentation/Carbon/Conceptual/SpotlightQuery/Concepts/QueryingMetadata.html))
  — so multi-segment fragments require a name query plus client-side
  path filtering (design below).
- **Metadata queries never trigger TCC prompts**: results inside
  Desktop/Documents/Downloads are silently filtered by the app's
  existing permissions; the standard prompt fires on first file
  *open* — the same posture as today's direct-path row
  ([TCC analysis](https://cedowens.medium.com/spotlighting-your-tcc-access-permissions-ec6628d7a876)).
- Debounce guidance clusters at 200–300 ms for web search;
  PullMark's own Search All Files debounces at 150 ms against local
  data — the in-house number carries.

## The design

### 1. Presentation: the "On This Mac" tier

- Tier 1 (everything the palette shows today) stays flat, headerless,
  and visually unchanged. Below it, disk results appear under the
  palette's first section header: **"On This Mac"** — Finder's own
  phrase for the scope; honest about source without exposing the
  implementation (and "Spotlight" would be wrong on machines with
  index exclusions).
- Rows reuse the existing shape: SF Symbol icon (`doc.text` /
  `folder`), title = file or folder name, subtitle = abbreviated
  parent directory.
- Row budget: the 12-row total stands. The tier shows up to **5**
  rows when tier 1 has matches and expands to fill unused rows when
  tier 1 is empty — which is precisely the pasted-path scenario,
  where the found file should be immediately hittable.

### 2. Matching

- The tier activates when the query's last path component is **≥3
  characters or a complete Markdown filename** — short fragments
  make the index return noise (Alfred's narrow-default philosophy).
- Query construction: split the query on `/`; the Spotlight
  predicate targets only the **last component** —
  `kMDItemFSName ==[c]` when it carries a known Markdown extension
  (`md`, `markdown`, `mdown`, `mkd`, `mdx` — extension globs, not
  UTIs, which are unreliable for these), otherwise
  `kMDItemFSName LIKE[cd] "*fragment*"` — plus a type clause
  limiting results to those extensions or folders.
- **Multi-segment fragments filter client-side**: keep results whose
  path's trailing components equal the query's components,
  case-insensitively, whole-component-wise. `docs/guide/setup.md`
  matches `~/repos/proj/docs/guide/setup.md` and nothing shallower.
  Spotlight cannot do this in the predicate; the app does it after.
- Ranking within the tier: exact-filename matches first, then the
  existing subsequence scorer applied to the path suffix, then most
  recently modified. **No disk result ever outranks a tier-1 row** —
  cross-tier promotion is what reintroduces selection jank, and in
  the pasted-path case tier 1 is empty anyway.
- Dedup: results whose standardized path equals an open file, the
  direct-destination row, or a visible recent are dropped from the
  tier.

### 3. Async behavior

- 150 ms debounce (matching Search All Files), then a **one-shot
  `NSMetadataQuery`** scoped to the user's home directory
  (`NSMetadataQueryUserHomeScope`): stopped after initial gathering,
  re-issued per keystroke, in-flight results discarded when stale —
  the same guard pattern the direct-destination resolver already
  uses. All handling off the main thread.
- Results **only ever append below** existing rows; their arrival
  never reorders tier 1 and never moves the selection. If a refresh
  replaces tier-2 rows while the selection is inside them, the
  selection clamps rather than jumping to the top.
- App-side exclusions beyond the index's own: any path containing a
  hidden component, `/node_modules/`, or living under `~/Library`.

### 4. Opening a result

- A **file** opens exactly like any ad-hoc open: it lands in the
  Files section, is noted as a recent, and is selected. Nothing else
  is added.
- A **folder** opens exactly like Open Folder: it becomes a sidebar
  root (a tree root once the sidebar-navigator work lands) — this is
  why folders are matched at all: a pasted partial path can open the
  folder you meant.

### 5. Out-of-root relative links stop failing silently

Clicking a relative link in a rendered local document whose target
escapes the file's resource root currently does nothing. Instead, the
click opens ⌘K pre-filled with the link's path — where the On This
Mac tier resolves it. One mechanism serves both the paste flow and
the click flow, and the silent failure becomes a visible, usually
one-keystroke recovery.

### 6. Setting

One toggle in Settings ▸ General, default **on**: **"Search this Mac
from Open Quickly."** Whole-disk filename results appearing in a
screenshot-able palette is a legitimate quiet-mode concern (demos,
screen sharing). No scope pickers or exclusion editors.

## Interactions with existing features

- **Direct-destination row**: unchanged and still instant; exact
  absolute/`~` paths never wait on the index. The tier dedups
  against it.
- **Search All Files (⇧⌘F)**: unchanged — content search stays over
  open sources only (Spotlight has no Markdown content index).
- **Recents**: opened disk results enter recents through the normal
  path; dead-recents behavior comes from the sidebar-navigator spec.
- **Sidebar-navigator spec (#32)**: folder results become tree
  roots; no other coupling — this feature ships independently
  before or after.
- **Keyboard settings**: no new shortcuts; ⌘K and palette navigation
  are untouched. The palette placeholder gains "…or search this
  Mac" phrasing at implementation's discretion.
- **TCC**: no new prompt surface — queries never prompt; opening a
  protected-folder result prompts exactly as the direct-path row
  does today. Files in not-yet-granted protected folders are
  silently absent from the tier (documented support note).
- **Zoom/theming/exports/Quick Look/editing/blame**: untouched —
  the palette is native chrome.
- **Multi-window**: the query runs per palette invocation; nothing
  is shared or cached across windows.

## Out of scope

- Markdown *content* search via Spotlight, and shipping a PullMark
  mdimporter to enable it (worth its own spec if ever wanted).
- Scope or exclusion configuration UI.
- Non-Markdown file results.
- Index-health detection or warnings (machines with Spotlight
  disabled simply get an empty tier).
- Any change to Search All Files.

## Open questions for implementation time

- Empirically spot-check with `mdfind`: whether `~/Library` results
  actually surface in home-scope queries (drives whether the
  app-side filter is belt-and-braces or load-bearing), and whether
  a result cap needs the C-level `MDQuerySetMaxCount` or client-side
  truncation suffices.
- Section-header styling in a previously headerless list, and
  whether folder rows use `folder` or a filled variant to read as
  "will add a sidebar root" (design-reviewer pass).
- Whether the out-of-root link handoff pre-selects the palette's
  first result for a pure Return-to-open flow.
- Whether a one-line footer hint about protected folders is wanted
  if "file exists but doesn't appear" turns up in practice.

## Verification notes

The implementing PR should demonstrate live: pasting a multi-segment
relative path for a file in a never-opened folder surfaces it under
"On This Mac" and Return opens it; a folder fragment opens the folder
as a sidebar root; tier-2 arrival never moves the selection while
arrowing; results in a TCC-protected folder are absent until access
is granted and present after; the settings toggle empties the tier;
an out-of-root link click opens the pre-filled palette.

The implementing PR should say "Closes #ISSUE" (issue number filled
in once the issue exists).
