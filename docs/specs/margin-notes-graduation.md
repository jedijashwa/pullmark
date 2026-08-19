# Margin notes graduate to beta

Margin notes leave the alpha tier: **on by default**, wearing the BETA
badge, with a one-time intro dialog the first time someone actually
reaches for the feature. The dialog says what notes are, that the
feature is experimental, links the docs, offers Turn Off / Keep Using —
and makes "tell your agent about this" a one-click copy.

## Motivation

Margin notes are PullMark's sharpest differentiator: comment on any
local Markdown document the way you'd comment on a PR, with the notes
saved into the file itself where an agent can read and resolve them.
The feature has proven itself in daily use, but as an alpha it sits
behind two switches ("Show alpha features" **and** the enable toggle),
so almost nobody meets it. Graduation inverts the discovery problem:
the affordances are simply there, and the first real interaction —
not an update announcement — is the moment the app explains itself.

The distribution wave that follows this one is written around margin
notes; it needs the feature to be reachable out of the box.

## The graduation

- `pm.marginNotesEnabled` defaults to **true** (absent = on). An
  explicit `false` written during the alpha era still wins — nobody
  who opted out is re-opted in.
- The Settings section moves out from behind the "Show alpha features"
  switch and is always visible in Settings ▸ Experimental, wearing the
  purple **BETA** badge. `alphaFeatureCount` 1→0,
  `betaFeatureCount` 0→1.
- The "Show alpha features" switch hides entirely while the alpha
  roster is empty — a control that reveals nothing only confuses
  (Josh's trial call, 2026-08-19). The stored flag survives, so the
  switch returns with its old value when an alpha feature ships.
- The `settings/experimental/margin-notes` deep link keeps working;
  its alpha-prompt detour (arming the alpha-contract dialog first) is
  no longer needed for this anchor and is removed.
- What the toggle gates is unchanged: authoring affordances only.
  Documents containing notes always render them, exactly as today.

## The first-use intro

**Trigger contract.** With the intro unseen, any *write action* shows
the intro first — passive viewing of bubbles never does:

- the hover bubble on a block (and on list items / table rows via
  nested targets),
- ⌥⌘M / Edit ▸ Add Margin Note / File Margin Note… / the toolbar
  palette item,
- Edit or Delete on an existing bubble (the cold-start case: an agent
  left notes in your file and your first contact is a bubble).

**Keep Using resumes the exact action clicked** — the composer opens
on that block, the edit opens on that note, the delete deletes — no
second click. **Turn Off** flips the feature off, marks the intro
seen, shows the standard notice ("Margin notes are off — turn them
back on in Settings ▸ Experimental."), and the page re-renders without
authoring affordances (existing notes still render). **Esc / close**
means "not now": nothing happens, the intro stays unseen, the next
write action asks again.

**Presentation.** A compact sheet on the document window — not an
alert; it carries a link and a copy control:

- Title row: "Margin Notes" + BETA badge.
- Two short paragraphs: what a note is (saved into the file itself as
  `<!-- note @you: … -->`, rendered as a bubble pinned to its spot, an
  ordinary HTML comment that stays out of rendered Markdown — never
  claim other tools "can't see" notes; source views show them and
  other tools may render them someday), and that the feature is
  experimental
  — beta, its design may still shift. Link: *How margin notes work* →
  pullmark.app/docs/experimental/margin-notes/.
- A "Tell your agent" row: one sentence plus a **Copy** button that
  copies `MarginNotes.agentInstructions` — the same snippet Settings
  copies — so "address the margin notes in this file" becomes a
  complete handoff.
- Buttons: **Turn Off** (secondary) and **Keep Using** (default).

**Wiring.** Native entries (⌥⌘M, menu items, toolbar) already funnel
through `LocalFileView.openNoteComposer` — the gate lives there, and
Keep Using proceeds into `proxy.openNoteComposer` with the requested
file-level flag. Page entries are armed after each page load via
`__pmSetNoteIntroPending(true)` — deliberately NOT a payload field:
the page reloads whenever its HTML changes, so carrying intro state in
the payload would let the seen-flip re-render the very page holding
the stashed action. While armed, the bubble / Edit / Delete handlers
stash the requested action and post `noteIntroRequested` over the
bridge instead of acting; Swift shows the sheet and resolves the page
with `__pmNoteIntroResolved(proceed)` — `true` runs the stashed action
and disarms, `false` (Esc) drops the stash and stays armed. Turn Off
needs no page-side resolution: the enabled flip re-renders the page
without authoring chrome. A page still armed after the intro was
settled elsewhere (another window, Settings) posts as usual and Swift
resolves it `true` immediately — self-healing, no dialog. A file
change landing while the sheet is up reloads the page and drops the
stash; the benign worst case is one extra click.

## Seen-state and migration

- New key `pm.marginNotesIntroSeen` (absent = false).
- Launch migration: if defaults already hold an explicit
  `marginNotesEnabled` value, seed the intro as seen — alpha-era users
  made their choice with the full Settings explanation in front of
  them. Runs once; never overwrites an existing seen value.
- Interacting with the Settings enable toggle also marks the intro
  seen, in either direction — the section says everything the dialog
  would.

## Interactions with existing features

- **View ▸ Hide Margin Notes** — unchanged; authoring guards
  (comparison, source view, hidden notes) still bail to notices before
  the intro gate is ever consulted.
- **PM_DEMO / demo fixtures** — the demo domain gets the same
  defaults; trials scrub the seen flag to meet the dialog cold.
- **Quick Look / previews / PR views** — never carry authoring, so
  never trigger the intro (`noteAuthoring` stays local-file-only).
- **Keyboard customization** — ⌥⌘M and friends unchanged; they simply
  work out of the box now.
- **Menu help strings** — "Turn on margin notes in Settings →
  Experimental" remains accurate for the explicitly-off state.
- **Review discussion precedent** — same graduation treatment on the
  site (level change called out on the experimental page).

## Out of scope

- Any new margin-notes capability (attributes, threading, resolve
  states) — graduation changes reach, not the feature.
- The marketing/SEO push and site screenshots built around margin
  notes — that's the distribution wave, next.
- A General-tab home for the section — it stays in Experimental while
  the beta badge applies.

## Verification

- Unit tests: launch migration (fresh suite; explicit true, explicit
  false, already-seen, clean install), payload flag plumbing.
- Render harness: with `noteIntroPending`, affordances render but the
  first write action posts `noteIntroRequested`; resolved-true resumes.
- Dist trial in the PM_DEMO domain with the seen flag scrubbed: meet
  the dialog cold from each trigger path, judged for feel — then the
  standard full-strength design review before ship.
