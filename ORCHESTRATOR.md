# ORCHESTRATOR.md

Operational guide for AI orchestrators.

## Required Reading

- Read `orchestrator-runbook.md` for detailed operational guidance.

## Memory Bank

Before planning or making decisions, read `docs/memory/` for project context:
- `projectbrief.md` -- Project goals, scope, and product context
- `activeContext.md` -- Current work focus, recent changes, active decisions
- `progress.md` -- What works, what's left, known issues
- `systemPatterns.md` -- Architecture, patterns, component relationships
- `techContext.md` -- Stack, dependencies, dev environment
- `lessons/` -- Per-task learnings from completed work

If `docs/memory/` does not exist, run `orchd memory init` or proceed without it.

## Objective

Drive the project to completion by coordinating workers through `orchd`.
You own planning, sequencing, retries, verification, and integration.

## Working Model

- Orchestrator = the AI currently driving the terminal session.
- Workers = task executors launched by `orchd` (default runner is from `[worker].runner`).
- Run autonomously by default; ask the user only when blocked by missing requirements/credentials.

## Primary User Flow

Most users will not drive orchd manually. They will open an external coding agent and tell it to orchestrate the repository with orchd.

Recommended handoff:

- `orchd agent-prompt orchestrator "<user goal>"`
- paste the printed prompt into the external agent
- let that agent run `orchd doctor`, `orchd state --json`, `orchd plan`, `orchd finish`, and follow-up commands as needed

When acting as the orchestrator, assume the human wants you to run orchd for them instead of asking them to manually step through the CLI.

## Project Context

Before planning, scan the repository for existing docs (examples):
- PHASES.md, PRD.md, ROADMAP.md, TODO.md, BACKLOG.md
- docs/ or planning directories with requirements, contracts, or runbooks

Use these to understand current state, remaining work, constraints, and acceptance criteria.

## Core Commands

- `orchd state --json`: machine-friendly snapshot for decision making.
- `orchd plan "<description>"`: AI-generated task DAG.
- `orchd plan --file <path>` / `orchd plan --stdin`: import externally-produced task DAG.
- `orchd orchestrate [poll]`: run the supervised AI orchestrator loop.
- `orchestrator.session_mode = attached`: for `opencode`, adopt an existing opencode chat session in the same project and send reminders into that same conversation.
- `orchestrator.session_mode = sticky`: for `opencode`, `codex`, or `claude`, inject reminders into a managed live session when interactive mode is available.
- `orchestrator.session_mode = resume`: for `claude`, continue the same managed Claude conversation across orchestrator turns.
- `orchestrator.stop_policy = needs_input_only`: keep nudging the orchestrator even after apparent completion; only stop on a real blocker or explicit user stop.
- `orchd orchestrate --once`: run one orchestrator turn without the supervisor loop.
- `orchd orchestrate --daemon [poll]`: keep the orchestrator alive in background.
- `orchd orchestrate --status|--stop|--logs`: manage the orchestrator daemon.

## Task-Specific Quality Commands (Optional)

Task blocks can optionally include `LINT_CMD`, `TEST_CMD`, and `BUILD_CMD`.
If present, `orchd check` will use them for that task (override > global config > auto-detect).
- `orchd spawn --all [--runner <runner>]`: start ready tasks.
- `orchd check --all`: evaluate completed/finished tasks.
- `orchd merge --all`: integrate done tasks in dependency order.
- `orchd resume <task-id> [reason]`: continue failed/stuck tasks.
- `orchd autopilot`: run the default supervised AI orchestrator loop.
- `orchd autopilot --ai-orchestrated`: explicit supervised AI orchestrator mode.
- `orchd autopilot --deterministic`: legacy deterministic spawn/check/merge loop.
- `orchd autopilot --continuous [poll]`: compatibility flag (implicit in AI mode; meaningful in deterministic mode).
- `orchd autopilot --daemon [poll]`: run autonomously in background (recommended for long runs).
- `orchd autopilot --status|--stop|--logs`: manage the daemon.
- `orchd finish`: deterministic finisher loop for project completion, follow-on ideation, and aggressive recovery.
- `orchd finish --daemon|--status|--stop|--logs`: manage the finisher daemon.
- `orchd ideate`: generate the next backlog from `docs/memory/` + codebase context.

## Continuous Autonomous Mode

For fully autonomous project development:

1. Define clear goals and scope in `docs/memory/projectbrief.md`.
2. Start either:
   - `orchd orchestrate --daemon 30` for an AI orchestrator that gets automatic system reminders and keeps resuming itself, or
   - `orchd autopilot` (default supervised AI mode), or
   - `orchd autopilot --deterministic --continuous` for the built-in deterministic loop.
3. orchd will keep cycling through orchestration decisions until completion.
4. Only stop when there is a genuine blocker or ideation outputs `PROJECT_COMPLETE`.

## Suggested Loop

1. Read state (`orchd state --json`).
2. If no tasks exist: create/import a plan.
3. Spawn ready tasks up to parallel limit.
4. Check finished tasks.
5. Merge tasks that are `done` and dependency-ready.
6. Retry/resume failed tasks with a focused reason.
7. When using the supervised AI orchestrator, let `orchd orchestrate` handle waits and continuation reminders.
8. Otherwise, when waiting manually, use `orchd await --all` instead of `sleep`.
9. Repeat until all tasks are terminal (`merged` or explicit blocker states) or the project is complete.

## Decision Rules

- Prefer many small dependency-safe tasks over large monolith tasks.
- Keep workers scoped: one clear goal per task with concrete acceptance criteria.
- Use `state --json` as source of truth for "what next".
- If a task needs user input, keep progress moving on other unblocked tasks.
- Watch `state --json` for scheduler, finisher, and review-gate telemetry; use it to explain why orchd is merging, waiting, splitting, or asking for review.

## Swarm Rollout

- `swarm_mode = "off"`: keep legacy expectations and validate runners/config.
- `swarm_mode = "observe"`: watch routing and telemetry first.
- `swarm_mode = "on"`: rely on adaptive verification, reviewer automation, recovery, and finisher behavior.

Even without an explicit rollout key, you can adopt v2 incrementally by using `orchd finish`, `orchd state --json`, and role-based runner config while keeping `worker.runner` compatibility.

## Deliverable Expectations

- Every worker task should leave clear evidence (`TASK_REPORT.md`, commits, checks).
- Merge only tasks that pass project quality gates.
- Preserve clean branch history and dependency order during integration.
