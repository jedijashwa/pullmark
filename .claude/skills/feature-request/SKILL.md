---
name: feature-request
description: Turn a feature idea into a complete, researched spec and a GitHub issue — deliberately stopping before any implementation or release. Use when someone has an idea worth pinning down.
---

# Feature request → spec → issue

Take an idea (one sentence is enough) through a brainstorming-style
session to a complete spec. The output is a committed spec document and
a linked GitHub issue. **This skill never implements and never
releases** — it ends when the spec is on record.

## Process

1. **Understand the ask.** Restate the idea; identify who wants it and
   the moment the itch strikes (the trigger context matters — e.g. "on
   entering full screen" shaped a whole design once). Ask the requester
   clarifying questions one round at a time; treat their suggestions as
   leads to investigate, not as the spec ("take criticism as things to
   look into, not absolute truth").
2. **Research.** Dispatch the feature-researcher agent: prior art in
   respected apps, the relevant literature with numbers, naming
   conventions, presentation patterns. Polished curated options beat
   utilitarian knobs — a raw number field is almost never the answer.
3. **Map the blast radius.** Check how the feature interacts with the
   app's existing surfaces: theming, zoom, blame, diffs, commenting,
   editing, exports, Quick Look, persistence, menus and shortcuts.
   Name each interaction in the spec with its intended behavior.
4. **Write the spec** to `docs/specs/<slug>.md`:
   - Motivation (who, when, why now)
   - Research summary with sources
   - The design: options, names, defaults, where each control lives
   - Interactions with existing features, one line each
   - Out of scope (explicitly)
   - Open questions for implementation time
5. **Check it in without releasing**: branch → `git add docs/specs/…`
   → PR titled `Spec: <feature>` → rebase-merge on approval.
6. **Open the issue**: `gh issue create` summarizing the spec and
   linking the committed file; note that the implementing PR should say
   "Closes #N". Creating the issue is a GitHub write — confirm with the
   human before posting.

Then stop. Implementation is a separate, separately-approved effort.
