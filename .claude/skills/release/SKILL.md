---
name: release
description: Ship a versioned release through the standard runbook. Requires that a human has explicitly approved shipping this specific release.
---

# Release

Precondition: the human explicitly said to ship this release. If that
hasn't happened, stop and ask — releases are outward-facing and every
one gets its own approval.

Run the release **inline in the main session** — the process is
script-backed and the judgment that remains (changelog voice,
screenshot review, failure recovery) needs the context this session
already holds. Follow `.claude/agents/release-manager.md` as the
runbook; the two scripts do the mechanical work:

- `./scripts/make-release.sh X.Y.Z` — the build/sign/notarize/publish
  pipeline. Run it in the background (notarization waits on Apple)
  and keep working until it reports.
- `./scripts/verify-release.sh X.Y.Z` — every mechanical
  post-release check as one PASS/FAIL table. Read the table, not the
  world: only a FAIL row warrants investigation.

Features bump the minor, fixes the patch. Dispatch the
release-manager agent (no model downgrade — recovery takes judgment)
only if the human asks for the release to run hands-off in the
background.

When done, report the release URL, the cask version transition, the
verify table's outcome, and anything left in a partial state.
