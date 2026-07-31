---
name: bug-hunt
description: Launch a proactive whole-app bug hunt with confirmed reproductions, then triage the findings with the human before fixing anything.
---

# Bug hunt

1. Dispatch the **bug-hunter** agent. Its standing rules travel with
   its definition (no GitHub writes ever, revert all instrumentation
   with `git status` proof, never touch app instances it didn't
   launch); in the prompt, add what's fresh territory versus recently
   reviewed, and any areas the human is worried about.
2. When the report lands, present the confirmed findings ranked by
   severity — in your own words, with reproductions — plus the
   near-miss list.
3. Let the human choose what gets fixed. Fixes go through the normal
   loop (implementer → verifier), typically as one batch PR, with a
   regression test per confirmed bug.
4. Keep the unfixed near-misses on record; they have a habit of
   becoming next month's bug reports.
