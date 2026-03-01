# ORCHESTRATOR.md

Operational guide for AI orchestrators.

## Required Reading

- Read `orchestrator-runbook.md` for detailed operational guidance.

## Objective

Drive the project to completion by coordinating workers through `orchd`.
You own planning, sequencing, retries, verification, and integration.

## Working Model

- Orchestrator = the AI currently driving the terminal session.
- Workers = task executors launched by `orchd` (default runner is from `[worker].runner`).
- Run autonomously by default; ask the user only when blocked by missing requirements/credentials.

## Project Context

Before planning, scan the repository for existing docs (examples):
- PHASES.md, PRD.md, ROADMAP.md, TODO.md, BACKLOG.md
- docs/ or planning directories with requirements, contracts, or runbooks

Use these to understand current state, remaining work, constraints, and acceptance criteria.

## Core Commands

- `orchd state --json`: machine-friendly snapshot for decision making.
- `orchd plan "<description>"`: AI-generated task DAG.
- `orchd plan --file <path>` / `orchd plan --stdin`: import externally-produced task DAG.

## Task-Specific Quality Commands (Optional)

Task blocks can optionally include `LINT_CMD`, `TEST_CMD`, and `BUILD_CMD`.
If present, `orchd check` will use them for that task (override > global config > auto-detect).
- `orchd spawn --all [--runner <runner>]`: start ready tasks.
- `orchd check --all`: evaluate completed/finished tasks.
- `orchd merge --all`: integrate done tasks in dependency order.
- `orchd resume <task-id> [reason]`: continue failed/stuck tasks.
- `orchd autopilot`: run the built-in autonomous loop.

## Suggested Loop

1. Read state (`orchd state --json`).
2. If no tasks exist: create/import a plan.
3. Spawn ready tasks up to parallel limit.
4. Check finished tasks.
5. Merge tasks that are `done` and dependency-ready.
6. Retry/resume failed tasks with a focused reason.
7. Repeat until all tasks are terminal (`merged` or explicit blocker states).

## Decision Rules

- Prefer many small dependency-safe tasks over large monolith tasks.
- Keep workers scoped: one clear goal per task with concrete acceptance criteria.
- Use `state --json` as source of truth for "what next".
- If a task needs user input, keep progress moving on other unblocked tasks.

## Deliverable Expectations

- Every worker task should leave clear evidence (`TASK_REPORT.md`, commits, checks).
- Merge only tasks that pass project quality gates.
- Preserve clean branch history and dependency order during integration.
