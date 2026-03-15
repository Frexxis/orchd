# Worker Lifecycle Hardening Plan

Goal: make `orchd` state transitions deterministic so `await`, `resume`, `check`, and `reconcile` behave consistently under stale sessions, missing exit markers, and mixed terminal/running states.

## Phase 1 (P0) - Safety-Critical Invariants

- [x] `await --all` blocks on live agents only (`status=running` and `agent_alive=true`).
- [x] Terminal tasks (`failed|done|merged|conflict|needs_input`) automatically clean stale live tmux sessions in reconciliation paths.
- [x] `resume` preflight kills stale session shells before launching the next attempt.
- [x] Quality gate no longer fails solely on missing `ORCHD_EXIT` marker if all other evidence gates pass.
- [x] Add regression tests for the scenarios above.

## Phase 2 (P1) - State Normalization

- [x] Add one canonical runtime-state helper shared by `state`, `board`, `await`, `reconcile`, and `autopilot`.
- [x] Normalize/clear attempt metadata at spawn/resume boundaries (`checked_at`, `needs_input_at`, prior failure markers).
- [x] Keep runner/session interpretation consistent across all commands (`alive`, `stale`, `exited`).

## Phase 3 (P1) - Needs Input Contract

- [x] Add structured `.orchd_needs_input.json` payload (while keeping markdown fallback for compatibility).
- [x] Distinguish worker-requested input from orchestration/system failures.
- [x] Surface structured `needs_input` in `state --json`.
- [x] Surface structured `needs_input` in TUI.

## Phase 4 (P2) - Prompt and Autopilot Hardening

- [x] Add strict execution mode flags to kickoff/continue contracts (`execution_only`, `no_planning`, `commit_required`).
- [x] Ensure autopilot retry/recovery logic uses normalized runtime state.
- [ ] Add richer telemetry for daemon reliability (heartbeat + decision trace).

## Validation

- `bash tests/config_get.sh`
- `bash tests/smoke.sh`
