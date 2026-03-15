# Throughput-First Orchestration Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Increase `orchd` project delivery throughput (more merged tasks and commits per day) without replacing the Bash core.

**Architecture:** Add a throughput control plane around the current `plan -> spawn -> check -> merge` loop: first measure, then remove hot-path overhead, then add smarter scheduling/recovery/quality profiles. Keep orchestration behavior deterministic and file-based, with small isolated changes in `lib/cmd/*`, `lib/core.sh`, templates, tests, and TUI stats rendering.

**Tech Stack:** Bash (`bin/orchd`, `lib/*.sh`), Go TUI (`cmd/orchd-tui`), tmux, git worktrees, shell test harness (`tests/*.sh`), GitHub Actions.

---

## File Map (Planned Changes)

- Modify: `lib/core.sh` (config/task caches, metric helpers)
- Create: `lib/metrics.sh` (metrics schema, event writer, rollups)
- Modify: `bin/orchd` (source `lib/metrics.sh`, command wiring)
- Modify: `lib/cmd/state.sh` (single-pass state computation, metrics summary exposure)
- Modify: `lib/cmd/autopilot.sh` (tick-local caches, scoring, dynamic parallelism, recovery)
- Modify: `lib/cmd/spawn.sh` (priority/score-aware spawn selection)
- Modify: `lib/cmd/check.sh` (quality profiles + evidence instrumentation)
- Modify: `lib/cmd/merge.sh` (merge-train metrics and conflict classification)
- Modify: `lib/cmd/plan.sh` (small-task and conflict-aware plan constraints)
- Modify: `templates/plan.prompt` (throughput-oriented planning rules)
- Modify: `templates/kickoff.prompt` (focused context and dependency delta block)
- Modify: `cmd/orchd-tui/state.go` (metrics file loading)
- Modify: `cmd/orchd-tui/view.go` (throughput stats cards)
- Create: `tests/throughput_smoke.sh` (end-to-end throughput behavior smoke)
- Modify: `tests/smoke.sh` (new command/profile coverage)
- Modify: `README.md` (new knobs, profiles, KPIs, rollout)
- Create: `docs/metrics.md` (metric dictionary and SLO/KPI guide)

## Delivery Strategy

- Phase order is strict: **measure -> optimize -> schedule -> recover -> harden -> rollout**.
- Each task is intentionally small, independently verifiable, and commit-friendly.
- Use TDD-style workflow for every behavior change: write failing test, implement minimal fix, verify pass, commit.

## Chunk 1: Baseline and Observability Foundation

### Task 1: Metrics Event Schema and Writer

**Files:**
- Create: `lib/metrics.sh`
- Modify: `bin/orchd`
- Modify: `lib/core.sh`
- Test: `tests/throughput_smoke.sh`

- [ ] **Step 1: Write failing smoke test for metrics event emission**

```bash
# tests/throughput_smoke.sh (new test case)
# Assert: running an autopilot tick writes .orchd/metrics/events.jsonl
test -f ".orchd/metrics/events.jsonl"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/throughput_smoke.sh`
Expected: FAIL with missing `.orchd/metrics/events.jsonl`

- [ ] **Step 3: Implement minimal metrics writer**

```bash
# lib/metrics.sh
metrics_emit() {
  # args: event_type task_id status duration_ms details_json
  # append one JSON line to .orchd/metrics/events.jsonl
}
```

- [ ] **Step 4: Wire metrics library into main runtime**

Run edits:
- Source `lib/metrics.sh` from `bin/orchd`
- Add `metrics_init` call in project-required command paths

- [ ] **Step 5: Re-run test and verify pass**

Run: `bash tests/throughput_smoke.sh`
Expected: PASS; metrics file exists and contains valid JSONL lines

- [ ] **Step 6: Commit**

```bash
git add lib/metrics.sh bin/orchd lib/core.sh tests/throughput_smoke.sh
git commit -m "feat: add metrics event pipeline for orchestration telemetry"
```

### Task 2: KPI Rollups and CLI Surface

**Files:**
- Modify: `lib/cmd/state.sh`
- Modify: `lib/metrics.sh`
- Modify: `README.md`
- Test: `tests/smoke.sh`

- [ ] **Step 1: Add failing test for KPI fields in `orchd state --json`**

```bash
# tests/smoke.sh add assertion
# jq-like string check for throughput fields
grep -q '"kpi"' /tmp/orchd-state.json
grep -q '"merged_tasks_per_day"' /tmp/orchd-state.json
```

- [ ] **Step 2: Run smoke suite to verify failure**

Run: `bash tests/smoke.sh`
Expected: FAIL on missing `kpi` object

- [ ] **Step 3: Add rollup computation helpers**

```bash
# lib/metrics.sh
metrics_rollup_today() { :; }
metrics_rollup_window_hours() { :; }
```

- [ ] **Step 4: Expose KPI object from `state --json`**

Implement fields:
- `merged_tasks_per_day`
- `cycle_time_p50_seconds`
- `cycle_time_p90_seconds`
- `first_pass_check_success_rate`

- [ ] **Step 5: Re-run tests and verify pass**

Run: `bash tests/smoke.sh`
Expected: PASS with new KPI fields in JSON output

- [ ] **Step 6: Commit**

```bash
git add lib/cmd/state.sh lib/metrics.sh tests/smoke.sh README.md
git commit -m "feat: expose throughput KPIs in state snapshot"
```

## Chunk 2: Hot-Path Performance and Low-Latency State

### Task 3: Config and Task Cache Primitives (Tick-Scoped)

**Files:**
- Modify: `lib/core.sh`
- Modify: `lib/cmd/autopilot.sh`
- Test: `tests/throughput_smoke.sh`

- [ ] **Step 1: Add failing test for repeated expensive reads**

```bash
# instrumentation test checks that repeated config_get/task_list_ids
# calls within one tick do not exceed baseline count.
```

- [ ] **Step 2: Verify failing behavior**

Run: `bash tests/throughput_smoke.sh`
Expected: FAIL due high repeated read count

- [ ] **Step 3: Implement tick-local caches**

```bash
# lib/core.sh
cache_tick_begin() { :; }
cache_tick_end() { :; }
config_get_cached() { :; }
task_list_ids_cached() { :; }
task_field_cached() { :; }
```

- [ ] **Step 4: Use caches in autopilot hot loop**

Replace repeated `task_list_ids` and `config_get` calls with cached variants inside each iteration.

- [ ] **Step 5: Re-run tests and verify pass**

Run: `bash tests/throughput_smoke.sh`
Expected: PASS with reduced repeated read counters

- [ ] **Step 6: Commit**

```bash
git add lib/core.sh lib/cmd/autopilot.sh tests/throughput_smoke.sh
git commit -m "perf: add tick-scoped caches for config and task state"
```

### Task 4: Single-Pass `state --json` Refactor

**Files:**
- Modify: `lib/cmd/state.sh`
- Test: `tests/smoke.sh`

- [ ] **Step 1: Add failing parity test**

Write test asserting old/new output parity for core fields while measuring command duration target.

- [ ] **Step 2: Run test and confirm fail**

Run: `bash tests/smoke.sh`
Expected: FAIL until single-pass output path is implemented

- [ ] **Step 3: Refactor JSON path to one full task scan**

Requirements:
- Precompute per-task status/alive/dependency flags once
- Reuse in both counters and JSON serialization
- Avoid duplicate `runner_is_alive` calls per task

- [ ] **Step 4: Verify correctness and speed target**

Run: `bash tests/smoke.sh`
Expected: PASS; output schema unchanged plus KPI additions

- [ ] **Step 5: Commit**

```bash
git add lib/cmd/state.sh tests/smoke.sh
git commit -m "perf: make state json generation single-pass"
```

## Chunk 3: Throughput-Oriented Planning and Scheduling

### Task 5: Planner Rules for Small, Parallel, Low-Conflict Tasks

**Files:**
- Modify: `templates/plan.prompt`
- Modify: `lib/cmd/plan.sh`
- Modify: `README.md`
- Test: `tests/smoke.sh`

- [ ] **Step 1: Add failing parser test for new optional fields**

Add plan fixture with optional fields (example):
- `SIZE: xs|s|m|l`
- `RISK: low|med|high`
- `FILE_HINTS: path1,path2`

- [ ] **Step 2: Run test to confirm current parser drops fields**

Run: `bash tests/smoke.sh`
Expected: FAIL on missing parsed metadata files under `.orchd/tasks/<id>/`

- [ ] **Step 3: Extend planner prompt and parser**

Implement:
- Prompt constraints for small task size and reduced dependency edges
- Parser support for optional fields without breaking existing format

- [ ] **Step 4: Verify backward compatibility**

Run: `bash tests/smoke.sh`
Expected: PASS for both old format and new optional metadata format

- [ ] **Step 5: Commit**

```bash
git add templates/plan.prompt lib/cmd/plan.sh tests/smoke.sh README.md
git commit -m "feat: add throughput-focused planning metadata and constraints"
```

### Task 6: Ready-Queue Scoring and Priority Spawn

**Files:**
- Modify: `lib/cmd/spawn.sh`
- Modify: `lib/cmd/autopilot.sh`
- Modify: `lib/core.sh`
- Test: `tests/throughput_smoke.sh`

- [ ] **Step 1: Add failing test for selection order**

Create fixture with multiple ready tasks and expected score order.

- [ ] **Step 2: Run failing test**

Run: `bash tests/throughput_smoke.sh`
Expected: FAIL because current selection is first-found, not score-based

- [ ] **Step 3: Implement score function**

```bash
# score weights (initial)
# +3 small size, +2 low risk, +2 no deps, +1 quality task near completion
task_score_ready() { :; }
```

- [ ] **Step 4: Use score sorting in spawn/autopilot**

Apply to:
- `spawn --all`
- autopilot spawn phase

- [ ] **Step 5: Re-run tests**

Run: `bash tests/throughput_smoke.sh`
Expected: PASS with deterministic priority order

- [ ] **Step 6: Commit**

```bash
git add lib/cmd/spawn.sh lib/cmd/autopilot.sh lib/core.sh tests/throughput_smoke.sh
git commit -m "feat: prioritize ready queue by throughput score"
```

### Task 7: Dynamic Parallelism Controller

**Files:**
- Modify: `lib/cmd/autopilot.sh`
- Modify: `README.md`
- Test: `tests/throughput_smoke.sh`

- [ ] **Step 1: Write failing behavior test**

Assert effective parallelism adjusts with:
- high failure rate -> lower concurrency
- stable pass streak -> higher concurrency (up to configured max)

- [ ] **Step 2: Run test and verify fail**

Run: `bash tests/throughput_smoke.sh`
Expected: FAIL before controller logic

- [ ] **Step 3: Implement controller**

```bash
# autopilot effective slots
effective_parallel = clamp(min_slots, max_parallel, adaptive_slots)
```

Inputs:
- recent check pass/fail ratio
- conflict rate
- currently running tasks

- [ ] **Step 4: Validate behavior with tests**

Run: `bash tests/throughput_smoke.sh`
Expected: PASS; logs show slot adjustments per policy

- [ ] **Step 5: Commit**

```bash
git add lib/cmd/autopilot.sh tests/throughput_smoke.sh README.md
git commit -m "feat: add adaptive parallelism control for autopilot"
```

## Chunk 4: Auto-Recovery and Quality Throughput Gates

### Task 8: Failure Classification and Retry Policies

**Files:**
- Modify: `lib/cmd/check.sh`
- Modify: `lib/cmd/autopilot.sh`
- Modify: `lib/core.sh`
- Test: `tests/throughput_smoke.sh`

- [ ] **Step 1: Add failing tests for failure classes**

Classes:
- `lint_failure`
- `test_failure`
- `build_failure`
- `merge_conflict`
- `needs_input`
- `infra_flake`

- [ ] **Step 2: Run tests to confirm fail**

Run: `bash tests/throughput_smoke.sh`
Expected: FAIL due missing class metadata and policy actions

- [ ] **Step 3: Implement classifier + policy matrix**

Policy examples:
- infra_flake -> auto retry up to 2
- lint/test failure -> targeted `resume` with reason
- needs_input -> no auto-retry, mark blocked

- [ ] **Step 4: Validate with tests**

Run: `bash tests/throughput_smoke.sh`
Expected: PASS with correct policy transitions

- [ ] **Step 5: Commit**

```bash
git add lib/cmd/check.sh lib/cmd/autopilot.sh lib/core.sh tests/throughput_smoke.sh
git commit -m "feat: add failure classification and retry policy engine"
```

### Task 9: Quality Profiles (`quick`, `standard`, `strict`)

**Files:**
- Modify: `lib/cmd/check.sh`
- Modify: `README.md`
- Modify: `.orchd.toml` template path in `lib/cmd/init.sh` (if profile defaults are added)
- Test: `tests/smoke.sh`

- [ ] **Step 1: Add failing tests for profile behavior**

Assertions:
- `quick` skips expensive build by default
- `standard` preserves current behavior
- `strict` enforces full lint+test+build and no missing report sections

- [ ] **Step 2: Verify failures**

Run: `bash tests/smoke.sh`
Expected: FAIL before profile parsing/execution is implemented

- [ ] **Step 3: Implement profile selection and command mapping**

Support precedence:
1. task override command fields
2. selected profile commands
3. global quality defaults

- [ ] **Step 4: Verify profile matrix**

Run: `bash tests/smoke.sh`
Expected: PASS across all profile scenarios

- [ ] **Step 5: Commit**

```bash
git add lib/cmd/check.sh lib/cmd/init.sh tests/smoke.sh README.md
git commit -m "feat: introduce quality profiles for faster safe throughput"
```

## Chunk 5: UX, Documentation, and Rollout Guardrails

### Task 10: Throughput Dashboard in TUI Stats Tab

**Files:**
- Modify: `cmd/orchd-tui/state.go`
- Modify: `cmd/orchd-tui/types.go`
- Modify: `cmd/orchd-tui/view.go`
- Test: `cmd/orchd-tui/*_test.go`

- [ ] **Step 1: Add failing Go test for KPI decoding/rendering**

Add sample state JSON containing KPI block and assert rendered stats include KPI labels.

- [ ] **Step 2: Run Go tests to confirm fail**

Run: `go test ./cmd/orchd-tui/...`
Expected: FAIL on missing KPI fields

- [ ] **Step 3: Implement KPI model and render cards**

KPIs to show:
- merged/day
- cycle p50/p90
- first-pass success
- conflict rate

- [ ] **Step 4: Re-run Go tests**

Run: `go test ./cmd/orchd-tui/...`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add cmd/orchd-tui/state.go cmd/orchd-tui/types.go cmd/orchd-tui/view.go cmd/orchd-tui/*_test.go
git commit -m "feat: surface throughput KPIs in TUI stats"
```

### Task 11: Docs, Rollout Playbook, and Feature Flags

**Files:**
- Create: `docs/metrics.md`
- Modify: `README.md`
- Modify: `ORCHESTRATOR.md`
- Test: `tests/smoke.sh`

- [ ] **Step 1: Add failing smoke checks for docs references**

Assert README references new profile + KPI + adaptive scheduling knobs.

- [ ] **Step 2: Run smoke checks and verify fail**

Run: `bash tests/smoke.sh`
Expected: FAIL until documentation is updated

- [ ] **Step 3: Document rollout modes**

Modes:
- `throughput_mode = off` (safe default)
- `throughput_mode = observe` (metrics + scoring, no policy enforcement)
- `throughput_mode = on` (full behavior)

- [ ] **Step 4: Re-run smoke checks**

Run: `bash tests/smoke.sh`
Expected: PASS with updated docs and examples

- [ ] **Step 5: Commit**

```bash
git add docs/metrics.md README.md ORCHESTRATOR.md tests/smoke.sh
git commit -m "docs: add throughput rollout guide and KPI reference"
```

## Chunk 6: Final Verification and Release Readiness

### Task 12: End-to-End Throughput Validation Wave

**Files:**
- Modify: `tests/throughput_smoke.sh`
- Modify: `TASK_REPORT.md`

- [ ] **Step 1: Add end-to-end validation scenario**

Scenario:
- plan with 6+ tasks
- spawn/check/merge loop
- inject 1 recoverable failure + 1 conflict
- verify recovery policy and KPI updates

- [ ] **Step 2: Run full verification suite**

Run:
- `bash tests/config_get.sh`
- `bash tests/smoke.sh`
- `bash tests/throughput_smoke.sh`
- `go test ./...`

Expected: PASS for all commands.

- [ ] **Step 3: Capture evidence**

Update `TASK_REPORT.md` with commands, PASS/FAIL, brief outputs, rollback criteria, and risks.

- [ ] **Step 4: Commit release candidate changes**

```bash
git add tests/throughput_smoke.sh TASK_REPORT.md
git commit -m "test: validate throughput-first orchestration wave"
```

---

## Execution Notes

- Keep each commit small and reversible.
- Do not blend unrelated refactors while implementing this plan.
- If a chunk exceeds scope, split into a follow-up plan file instead of expanding complexity.
- If conflict rate increases during rollout, switch to `throughput_mode = observe` and collect another 24h baseline before enabling full mode.

## Success Criteria (Plan Acceptance)

- `merged tasks/day` improves at least 2x from baseline in representative runs.
- `cycle_time_p50` decreases by at least 40%.
- `first_pass_check_success_rate` improves by at least 25%.
- No regression in core smoke tests and no increase in permanent `needs_input` blockers.
