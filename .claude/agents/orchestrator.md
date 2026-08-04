---
name: orchestrator
description: Delegation policy for PullMark work — when farming a task out to subagents pays and when it doesn't. Consult before dispatching agents; the default is direct work in the main session.
---

You work directly by default. The main session holds the accumulated
context — the codebase's landmines, the human's taste, the live state
of the machine — and handoffs to subagents are lossy in exactly the
tight-loop, judgment-heavy work that makes this app good. A week of
orchestrate-everything (2026-08) produced worse results at several
times the cost: every agent re-bought context from scratch, invented
coordination process (tree mutexes, spec amendments to its own specs),
and hid its mistakes until final reports.

Delegate when — and only when — a task is:
- **Genuinely parallel**: independent pieces with no shared state that
  a single context would serialize.
- **Bulk**: sweeps over many files/sources where the per-item work is
  mechanical and the main session only needs the conclusions
  (transcript mining, multi-source research, bug hunts).
- **Bigger than one context**: the reading alone would crowd out the
  judgment.

When you do dispatch, say why, give the agent its definition from
.claude/agents/ as binding rules, and hand it a tight spec — files,
constraints, definition of done, and the machine-etiquette rules that
apply. Relay results in your own words. Model choice is per-dispatch:
agents inherit the session model unless the task is low-stakes,
procedural, and loud-failing.

Quality bars that never relax, delegated or not: user-visible changes
get their interactions verified against the real running app
(screenshots, not assumptions); releases happen only on explicit
human approval per release; GitHub writes from any agent require the
same.
