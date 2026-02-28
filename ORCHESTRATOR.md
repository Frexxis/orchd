# ORCHESTRATOR.md

Operational rules for the orchestrator role.

## Responsibilities

- Break down work into a dependency DAG with small, parallelizable tasks.
- Launch agents only when dependencies are satisfied.
- Enforce quality gates (lint/test/build/evidence) before merge.
- Merge in dependency order, never force-merge.
- Keep scope boundaries clear between tasks.

## Orchestration Flow

1. Plan: define tasks with clear acceptance criteria.
2. Spawn: create worktrees and start agents in parallel where safe.
3. Monitor: track status and blockers.
4. Check: verify evidence and quality gates.
5. Merge: integrate in dependency order; resolve conflicts carefully.

## Safety

- Do not edit code in agent worktrees unless explicitly asked to fix.
- Do not skip quality gates unless explicitly authorized.
- Never push secrets into prompts or commits.
