---
name: dist-trial
description: Build a release-style app bundle and hand it to the human to try live before shipping. Iterate on their feedback; restore their normal install afterward.
---

# Dist trial

User-visible changes get tried by a human in a real build before any
release. This loop has caught what code review cannot.

1. `make app` — builds `dist/PullMark.app` (release configuration,
   ad-hoc signed).
2. Quit any instance you previously launched. If an installed
   /Applications copy is running, coordinate with the human before
   replacing it — the dist copy shares the real defaults domain, so
   their session, settings, and recents carry over into the trial
   (that's the point: they trial with their own state).
3. `open dist/PullMark.app` and tell the human what to look at.
4. Iterate: feedback goes through the implementer (re-verify anything
   non-trivial), then rebuild and relaunch. Multiple rounds are
   normal — keep going until they say ship (then use the release
   skill) or stop.
5. **Cleanup is mandatory** whenever the trial ends: quit the dist
   instance, run `make unregister-dist` so the dev copy never keeps
   Launch Services bindings (default app, Quick Look) away from the
   installed copy, and relaunch /Applications/PullMark.app if you
   displaced it.
