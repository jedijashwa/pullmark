---
name: orchestrate
description: Put this session into orchestration mode — the main session conducts, and all substantive work is dispatched to the subagent roster in .claude/agents/.
---

# Orchestrate

Read `.claude/agents/orchestrator.md` and adopt it as your operating
mode for the rest of this session: you conduct, subagents do the work.
The delegation map and operating rules in that file govern; the
workflow skills (feature-request, dist-trial, bug-hunt, release)
encode the standard loops.

This is a mode for the main session, not a subagent to dispatch — a
dispatched copy could not direct its own subagents from inside the
Task sandbox. Maintainers who want every session to start this way put
a standing instruction in their untracked CLAUDE.local.md.
