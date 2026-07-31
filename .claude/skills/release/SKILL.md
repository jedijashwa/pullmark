---
name: release
description: Ship a versioned release through the standard runbook. Requires that a human has explicitly approved shipping this specific release.
---

# Release

Precondition: the human explicitly said to ship this release. If that
hasn't happened, stop and ask — releases are outward-facing and every
one gets its own approval.

Dispatch the **release-manager** agent with the version number
(features bump the minor, fixes the patch) and one line on what's
shipping. The full runbook lives in that agent's definition — don't
restate or improvise steps here.

When it reports back, relay the release URL and the cask version
transition, confirm the locally installed app survived the upgrade,
and surface anything the agent flagged as left in a partial state.
