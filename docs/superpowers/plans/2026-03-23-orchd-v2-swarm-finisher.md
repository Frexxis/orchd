# orchd v2 Swarm Finisher Plan

> **For agentic workers:** REQUIRED: keep the Bash kernel stable while implementing this plan. Favor small, test-backed slices. Do not collapse provider choice into product logic; user-configured runners remain first-class.

**Goal:** turn `orchd` from a capable AI task orchestrator into a provider-agnostic, throughput-first, always-on swarm controller that finishes whole software projects with minimal idle time and minimum-sufficient verification.

**Architecture:** keep a deterministic kernel for task state, dependency ordering, worktrees, locks, merge policy, and quality gate execution; add a swarm policy layer for role routing, runner fallback, adaptive verification, recovery, replanning, and project-finisher behavior. Optimize for merged work and forward progress, not maximum ceremony.

**Tech Stack:** Bash (`bin/orchd`, `lib/*.sh`, `lib/cmd/*.sh`), Go TUI (`cmd/orchd-tui`), tmux, git worktrees, shell smoke/config tests, GitHub Actions.

---

## Product Direction

### North Star

- User chooses available runners/providers.
- `orchd` chooses role assignment, work allocation, retry policy, and verification depth.
- The system never idles while productive action exists.
- Verification is proportional to risk and blast radius.
- Failed work is routed, retried, split, or de-risked before asking the human.

### Core Principles

- **Provider-agnostic:** product logic reasons about roles/capabilities, not hardcoded vendor assumptions.
- **Throughput-first:** maximize merged tasks and reduced cycle time, not process heaviness.
- **Recoverability-first:** failures are expected; fast recovery matters more than perfect first pass.
- **Cheap checks first:** smoke/targeted verification before expensive full-suite execution.
- **Deterministic kernel, agentic policy:** state/merge/locks stay deterministic; routing/replanning/recovery can be AI-guided.
- **Never globally block:** missing runner/provider for one role should degrade gracefully, not stop the project.

### Non-Goals

- Full rewrite of the Bash core before proving v2 policies.
- Mandatory use of Claude, Codex, or any single provider.
- Full lint/test/build on every task by default.
- Turning merge decisions into free-form LLM behavior.

---

## Target Capability Model

### Swarm Roles

- `architect`: clarify scope, boundaries, milestones
- `planner`: generate and revise task DAGs
- `builder`: execute implementation tasks
- `reviewer`: inspect risky or broad diffs
- `recovery`: rescue failed/stuck work
- `merger`: prepare and validate merge-ready work
- `scout`: find next work, unblock paths, and follow-on ideas

### Runner Capabilities

Examples of tags the routing layer should understand:

- `long_context`
- `fast_patch`
- `strong_review`
- `cheap_execution`
- `tool_heavy`
- `spec_reasoning`
- `interactive_resume`

### Config Direction

`orchd` should evolve from one runner preference to user-configured role routing, for example:

```toml
[swarm.policy]
optimize_for = "speed"      # speed | balanced | quality | cost
allow_fallback = true
idle_policy = "never_idle"
verification_policy = "adaptive"

[swarm.roles]
planner = ["claude", "codex", "opencode"]
builder = ["codex", "claude", "opencode"]
reviewer = ["claude", "codex"]
recovery = ["claude", "opencode"]
merger = ["codex", "claude"]

[swarm.capabilities.claude]
tags = ["long_context", "strong_review", "spec_reasoning", "interactive_resume"]

[swarm.capabilities.codex]
tags = ["fast_patch", "tool_heavy"]

[swarm.capabilities.opencode]
tags = ["cheap_execution", "fast_patch"]
```

---

## File Map (Planned Changes)

- Modify: `README.md` (v2 positioning, role routing, adaptive verification, finisher mode)
- Modify: `ORCHESTRATOR.md` (role-aware orchestration loop)
- Modify: `WORKER.md` (lighter verification defaults with risk escalation rules)
- Modify: `orchestrator-runbook.md` (swarm control plane guidance)
- Modify: `bin/orchd` (new command wiring)
- Modify: `lib/core.sh` (shared config/state helpers while gradually extracting modules)
- Modify: `lib/runner.sh` (runner metadata, capability introspection, role fallback)
- Modify: `lib/cmd/init.sh` (new config scaffold for swarm policy)
- Modify: `lib/cmd/plan.sh` (task metadata: size/risk/blast-radius/file hints)
- Modify: `lib/cmd/spawn.sh` (role-aware spawn selection)
- Modify: `lib/cmd/check.sh` (adaptive verification engine)
- Modify: `lib/cmd/merge.sh` (merge policy tied to risk profile)
- Modify: `lib/cmd/resume.sh` (recovery-aware retry/resume flow)
- Modify: `lib/cmd/autopilot.sh` (throughput-first scheduler and fallback behavior)
- Modify: `lib/cmd/orchestrate.sh` (swarm policy orchestration and never-idle loop)
- Modify: `lib/cmd/state.sh` (new routing/recovery/verification fields)
- Modify: `lib/cmd/idea.sh` (project-finisher backlog signals)
- Modify: `lib/cmd/ideate.sh` (follow-on work generation after scope completion)
- Modify: `lib/cmd/fleet.sh` (fleet-wide swarm policy support)
- Create: `lib/swarm.sh` (role routing, capability matching, fallback selection)
- Create: `lib/verify.sh` (verification tiers and command selection)
- Create: `lib/recovery.sh` (failure classification and retry matrix)
- Create: `lib/decision_trace.sh` (human-readable scheduler decisions)
- Modify: `templates/plan.prompt` (throughput-first planning constraints)
- Modify: `templates/kickoff.prompt` (role + risk + verification expectations)
- Modify: `templates/continue.prompt` (recovery context)
- Modify: `templates/orchestrator.prompt` (never-idle, role-aware orchestration)
- Create: `templates/recovery.prompt` (failed-task rescue instructions)
- Create: `templates/reviewer.prompt` (targeted review role)
- Modify: `cmd/orchd-tui/state.go` (new swarm fields)
- Modify: `cmd/orchd-tui/view.go` (routing, risk, and throughput panels)
- Modify: `cmd/orchd-tui/types.go` (state models for routing/recovery/verification)
- Create: `tests/swarm_smoke.sh` (v2 swarm behavior)
- Modify: `tests/smoke.sh` (routing, finisher, verification regressions)
- Modify: `tests/config_get.sh` (config precedence for swarm fields)

---

## Delivery Strategy

- Phase order is strict: **routing -> scheduler -> adaptive verification -> recovery -> finisher -> telemetry**.
- Preserve current behavior behind flags/default-safe modes until each phase proves out.
- Keep the current Bash kernel operational while moving logic into `lib/swarm.sh`, `lib/verify.sh`, and `lib/recovery.sh`.
- Every behavior change should have one primary regression test path: config, smoke, swarm smoke, or Go TUI tests.
- If a phase grows too large, split a follow-up plan instead of inflating scope.

---

## Backlog Overview

### P0 - Must Land for v2 Identity

- Role-based routing and fallback
- Never-idle scheduler decisions
- Adaptive verification tiers
- Failure classification and recovery policy
- Finisher mode backbone

### P1 - Strongly Recommended for v2 Launch

- Decision trace and scheduler explainability
- Reviewer swarm for risky changes
- TUI support for routing/risk/recovery state
- Fleet support for swarm policy

### P2 - Follow-On Enhancements

- Historical runner scoring from real outcomes
- Automatic task splitting for oversized failures
- Conflict prediction from file-hint overlap
- Multi-project throughput optimization heuristics

---

## Chunk 1: Provider-Agnostic Role Routing

### Task 1: Swarm Config Schema and Capability Parsing

**Files:**
- Modify: `lib/core.sh`
- Modify: `lib/cmd/init.sh`
- Modify: `README.md`
- Test: `tests/config_get.sh`

- [ ] **Step 1: Add failing config regression coverage**

Add tests for:
- `swarm.policy.optimize_for`
- `swarm.roles.planner`
- `swarm.capabilities.<runner>.tags`
- fallback to legacy `worker.runner`

- [ ] **Step 2: Run config tests and verify failure**

Run: `bash tests/config_get.sh`
Expected: FAIL on missing/incorrect swarm key resolution

- [ ] **Step 3: Extend config parsing helpers**

Implement support for list-like role fields and capability tags while preserving backward compatibility.

- [ ] **Step 4: Update init template defaults**

Add safe defaults:
- legacy behavior still works with one runner
- swarm config is scaffolded but optional

- [ ] **Step 5: Re-run tests and verify pass**

Run: `bash tests/config_get.sh`
Expected: PASS for both legacy and new config shapes

- [ ] **Step 6: Commit**

```bash
git add lib/core.sh lib/cmd/init.sh tests/config_get.sh README.md
git commit -m "feat: add swarm config schema and provider-agnostic defaults"
```

### Task 2: Role Router and Runner Fallback Engine

**Files:**
- Create: `lib/swarm.sh`
- Modify: `bin/orchd`
- Modify: `lib/runner.sh`
- Test: `tests/smoke.sh`

- [ ] **Step 1: Add failing smoke coverage for role routing**

Cases:
- planner role chooses first available configured runner
- missing preferred runner falls back to next available runner
- no configured runner for role falls back to legacy `worker.runner`

- [ ] **Step 2: Run smoke tests and verify failure**

Run: `bash tests/smoke.sh`
Expected: FAIL because role routing is not yet implemented

- [ ] **Step 3: Implement router helpers**

```bash
# lib/swarm.sh
swarm_select_runner_for_role() { :; }
swarm_runner_has_capability() { :; }
swarm_role_candidates() { :; }
```

- [ ] **Step 4: Integrate with runner execution paths**

Use router output for planning, orchestration, build, review, and recovery roles while preserving current single-runner flows.

- [ ] **Step 5: Re-run smoke tests and verify pass**

Run: `bash tests/smoke.sh`
Expected: PASS with deterministic role-to-runner selection

- [ ] **Step 6: Commit**

```bash
git add lib/swarm.sh bin/orchd lib/runner.sh tests/smoke.sh
git commit -m "feat: route swarm roles across user-selected runners"
```

### Task 3: State Surface for Routing Decisions

**Files:**
- Modify: `lib/cmd/state.sh`
- Modify: `README.md`
- Test: `tests/smoke.sh`

- [ ] **Step 1: Add failing JSON assertions**

Expose in `orchd state --json`:
- selected runner per task/role
- routing reason
- fallback status

- [ ] **Step 2: Run smoke suite and verify failure**

Run: `bash tests/smoke.sh`
Expected: FAIL on missing routing fields

- [ ] **Step 3: Implement state rendering**

Add machine-friendly routing fields without breaking existing JSON consumers.

- [ ] **Step 4: Re-run tests and verify pass**

Run: `bash tests/smoke.sh`
Expected: PASS with routing metadata in state output

- [ ] **Step 5: Commit**

```bash
git add lib/cmd/state.sh tests/smoke.sh README.md
git commit -m "feat: surface routing decisions in state snapshots"
```

## Chunk 2: Never-Idle Scheduler and Throughput Control

### Task 4: Scheduler Decision Engine

**Files:**
- Create: `lib/decision_trace.sh`
- Modify: `lib/cmd/autopilot.sh`
- Modify: `lib/cmd/orchestrate.sh`
- Test: `tests/swarm_smoke.sh`

- [ ] **Step 1: Add failing swarm-smoke scenario**

Scenario should prove the scheduler prefers productive action in this order:
- merge ready work
- check finished work
- spawn ready work
- recover resumable failures
- ideate/plan next work
- only wait when nothing actionable exists

- [ ] **Step 2: Run failing swarm smoke**

Run: `bash tests/swarm_smoke.sh`
Expected: FAIL before decision engine exists

- [ ] **Step 3: Implement a single decision selector**

```bash
scheduler_next_action() { :; }
scheduler_decision_reason() { :; }
```

- [ ] **Step 4: Wire decision tracing into autopilot/orchestrate**

Every tick should log one explicit reason for acting or waiting.

- [ ] **Step 5: Re-run tests and verify pass**

Run: `bash tests/swarm_smoke.sh`
Expected: PASS with explicit non-idle decision order

- [ ] **Step 6: Commit**

```bash
git add lib/decision_trace.sh lib/cmd/autopilot.sh lib/cmd/orchestrate.sh tests/swarm_smoke.sh
git commit -m "feat: add never-idle scheduler decision engine"
```

### Task 5: Ready-Task Scoring for Throughput

**Files:**
- Modify: `lib/swarm.sh`
- Modify: `lib/cmd/spawn.sh`
- Modify: `lib/cmd/autopilot.sh`
- Test: `tests/swarm_smoke.sh`

- [ ] **Step 1: Add failing priority-order tests**

Scoring inputs should include:
- task size
- risk
- dependency depth
- file overlap risk
- verification cost

- [ ] **Step 2: Run tests and verify failure**

Run: `bash tests/swarm_smoke.sh`
Expected: FAIL because selection is not score-based yet

- [ ] **Step 3: Implement scoring helpers**

```bash
swarm_score_task_for_spawn() { :; }
swarm_sort_ready_tasks() { :; }
```

- [ ] **Step 4: Apply deterministic sort in spawn paths**

Use identical ordering rules in `spawn --all` and automated loops.

- [ ] **Step 5: Re-run tests and verify pass**

Run: `bash tests/swarm_smoke.sh`
Expected: PASS with stable, throughput-oriented order

- [ ] **Step 6: Commit**

```bash
git add lib/swarm.sh lib/cmd/spawn.sh lib/cmd/autopilot.sh tests/swarm_smoke.sh
git commit -m "feat: prioritize ready tasks by throughput score"
```

## Chunk 3: Adaptive Verification Instead of Heavy Default Gates

### Task 6: Verification Tier Model

**Files:**
- Create: `lib/verify.sh`
- Modify: `lib/cmd/check.sh`
- Modify: `README.md`
- Test: `tests/smoke.sh`

- [ ] **Step 1: Add failing coverage for verification tiers**

Required tiers:
- `smoke`
- `targeted`
- `full`

Assertions:
- low-risk tasks default to `smoke`
- medium-risk tasks choose `targeted`
- high-risk tasks escalate to `full`

- [ ] **Step 2: Run smoke tests and verify failure**

Run: `bash tests/smoke.sh`
Expected: FAIL on missing tier behavior

- [ ] **Step 3: Implement verification planner**

```bash
verify_select_tier() { :; }
verify_select_commands() { :; }
verify_tier_reason() { :; }
```

- [ ] **Step 4: Wire tiers into `orchd check`**

Preserve task command overrides and existing auto-detection rules.

- [ ] **Step 5: Re-run tests and verify pass**

Run: `bash tests/smoke.sh`
Expected: PASS with tier-appropriate command execution

- [ ] **Step 6: Commit**

```bash
git add lib/verify.sh lib/cmd/check.sh tests/smoke.sh README.md
git commit -m "feat: add adaptive verification tiers for throughput-first checks"
```

### Task 7: Risk and Blast-Radius Metadata from Planning

**Files:**
- Modify: `templates/plan.prompt`
- Modify: `lib/cmd/plan.sh`
- Modify: `templates/kickoff.prompt`
- Test: `tests/smoke.sh`

- [ ] **Step 1: Add failing parser fixtures**

Plan fields to support:
- `SIZE`
- `RISK`
- `BLAST_RADIUS`
- `FILE_HINTS`
- `RECOMMENDED_VERIFICATION`

- [ ] **Step 2: Run tests and verify failure**

Run: `bash tests/smoke.sh`
Expected: FAIL because metadata is not parsed/stored

- [ ] **Step 3: Extend planner prompt and parser**

Ensure old plans still parse cleanly.

- [ ] **Step 4: Inject metadata into kickoff context**

Workers should understand intended speed/risk tradeoff for the task.

- [ ] **Step 5: Re-run tests and verify pass**

Run: `bash tests/smoke.sh`
Expected: PASS with metadata visible in task state and kickoff prompt

- [ ] **Step 6: Commit**

```bash
git add templates/plan.prompt lib/cmd/plan.sh templates/kickoff.prompt tests/smoke.sh
git commit -m "feat: add risk metadata for adaptive verification and scheduling"
```

### Task 8: Merge Policy by Risk Tier

**Files:**
- Modify: `lib/cmd/merge.sh`
- Modify: `lib/verify.sh`
- Test: `tests/swarm_smoke.sh`

- [ ] **Step 1: Add failing merge-policy tests**

Examples:
- low-risk task can merge after smoke+targeted evidence
- high-risk task requires broader verification or review marker

- [ ] **Step 2: Run tests and verify failure**

Run: `bash tests/swarm_smoke.sh`
Expected: FAIL before risk-aware merge rules

- [ ] **Step 3: Implement merge gating logic**

Use stored verification tier, risk, and reviewer outcome where applicable.

- [ ] **Step 4: Re-run tests and verify pass**

Run: `bash tests/swarm_smoke.sh`
Expected: PASS with risk-aware merge acceptance

- [ ] **Step 5: Commit**

```bash
git add lib/cmd/merge.sh lib/verify.sh tests/swarm_smoke.sh
git commit -m "feat: gate merges by risk-aware verification policy"
```

## Chunk 4: Recovery Swarm and Replanning

### Task 9: Failure Classification Engine

**Files:**
- Create: `lib/recovery.sh`
- Modify: `lib/cmd/check.sh`
- Modify: `lib/cmd/resume.sh`
- Test: `tests/swarm_smoke.sh`

- [ ] **Step 1: Add failing failure-class tests**

Classes:
- `lint_failure`
- `test_failure`
- `build_failure`
- `merge_conflict`
- `infra_flake`
- `scope_confusion`
- `needs_input`

- [ ] **Step 2: Run tests and verify failure**

Run: `bash tests/swarm_smoke.sh`
Expected: FAIL until class metadata exists

- [ ] **Step 3: Implement classifier and policy matrix**

```bash
recovery_classify_failure() { :; }
recovery_policy_for_class() { :; }
```

- [ ] **Step 4: Store class + next action in task state**

Needed for scheduler and TUI explainability.

- [ ] **Step 5: Re-run tests and verify pass**

Run: `bash tests/swarm_smoke.sh`
Expected: PASS with class-specific next actions

- [ ] **Step 6: Commit**

```bash
git add lib/recovery.sh lib/cmd/check.sh lib/cmd/resume.sh tests/swarm_smoke.sh
git commit -m "feat: classify task failures for swarm recovery policies"
```

### Task 10: Recovery Prompt and Alternate Runner Escalation

**Files:**
- Create: `templates/recovery.prompt`
- Modify: `lib/cmd/resume.sh`
- Modify: `lib/swarm.sh`
- Test: `tests/swarm_smoke.sh`

- [ ] **Step 1: Add failing resume/recovery tests**

Cases:
- infra flake retries same runner
- repeated implementation failure escalates to alternate runner
- needs_input does not auto-retry

- [ ] **Step 2: Run tests and verify failure**

Run: `bash tests/swarm_smoke.sh`
Expected: FAIL without recovery prompt flow

- [ ] **Step 3: Implement recovery-specific resume path**

Resume should inject:
- failure class
- exact failing evidence
- changed verification expectation
- alternate runner when policy says escalate

- [ ] **Step 4: Re-run tests and verify pass**

Run: `bash tests/swarm_smoke.sh`
Expected: PASS with policy-specific resume behavior

- [ ] **Step 5: Commit**

```bash
git add templates/recovery.prompt lib/cmd/resume.sh lib/swarm.sh tests/swarm_smoke.sh
git commit -m "feat: add recovery-aware resume flow with runner escalation"
```

### Task 11: Planner Re-entry and Task Splitting

**Files:**
- Modify: `lib/cmd/plan.sh`
- Modify: `lib/cmd/orchestrate.sh`
- Modify: `templates/orchestrator.prompt`
- Test: `tests/swarm_smoke.sh`

- [ ] **Step 1: Add failing replanning tests**

Cases:
- oversized failed task is split into smaller tasks
- completed scope with pending opportunities triggers next-wave ideation

- [ ] **Step 2: Run tests and verify failure**

Run: `bash tests/swarm_smoke.sh`
Expected: FAIL until replanning hooks exist

- [ ] **Step 3: Implement safe re-entry path**

Allow the orchestrator to create follow-up tasks without corrupting current task state.

- [ ] **Step 4: Re-run tests and verify pass**

Run: `bash tests/swarm_smoke.sh`
Expected: PASS with deterministic task-splitting/replanning behavior

- [ ] **Step 5: Commit**

```bash
git add lib/cmd/plan.sh lib/cmd/orchestrate.sh templates/orchestrator.prompt tests/swarm_smoke.sh
git commit -m "feat: add replanning and task-splitting for stalled work"
```

## Chunk 5: Project Finisher Mode

### Task 12: Scope-Completion and Next-Phase Logic

**Files:**
- Modify: `lib/cmd/ideate.sh`
- Modify: `lib/cmd/idea.sh`
- Modify: `README.md`
- Test: `tests/swarm_smoke.sh`

- [ ] **Step 1: Add failing finisher-mode tests**

Cases:
- when the original scope is done, `orchd` chooses either `PROJECT_COMPLETE` or next-phase work based on policy
- no actionable work yields a real terminal completion, not passive waiting

- [ ] **Step 2: Run tests and verify failure**

Run: `bash tests/swarm_smoke.sh`
Expected: FAIL before finisher rules exist

- [ ] **Step 3: Implement `finish` policy helpers**

Introduce clear distinction between:
- scope complete
- backlog available
- improvement opportunities
- true project completion

- [ ] **Step 4: Re-run tests and verify pass**

Run: `bash tests/swarm_smoke.sh`
Expected: PASS with deterministic completion behavior

- [ ] **Step 5: Commit**

```bash
git add lib/cmd/ideate.sh lib/cmd/idea.sh tests/swarm_smoke.sh README.md
git commit -m "feat: add project-finisher completion and next-phase logic"
```

### Task 13: New `orchd finish` Entry Point

**Files:**
- Modify: `bin/orchd`
- Modify: `lib/cmd/autopilot.sh`
- Modify: `README.md`
- Test: `tests/smoke.sh`

- [ ] **Step 1: Add failing CLI coverage**

Command expectations:
- `orchd finish`
- `orchd finish --daemon`
- `orchd finish --status|--stop|--logs`

- [ ] **Step 2: Run smoke tests and verify failure**

Run: `bash tests/smoke.sh`
Expected: FAIL before command wiring exists

- [ ] **Step 3: Wire `finish` as a dedicated throughput-first mode**

This mode should strongly prefer:
- adaptive verification
- aggressive recovery
- follow-on work generation until terminal completion policy says stop

- [ ] **Step 4: Re-run tests and verify pass**

Run: `bash tests/smoke.sh`
Expected: PASS with new command help and mode behavior

- [ ] **Step 5: Commit**

```bash
git add bin/orchd lib/cmd/autopilot.sh tests/smoke.sh README.md
git commit -m "feat: add finish mode for project-completion swarm loops"
```

## Chunk 6: Telemetry, TUI, and Rollout Safety

### Task 14: Swarm Decision and Recovery Telemetry

**Files:**
- Modify: `lib/cmd/state.sh`
- Modify: `lib/decision_trace.sh`
- Modify: `README.md`
- Test: `tests/swarm_smoke.sh`

- [ ] **Step 1: Add failing telemetry assertions**

Need fields for:
- last scheduler decision
- recovery class
- verification tier
- fallback count
- idle-avoidance reason

- [ ] **Step 2: Run tests and verify failure**

Run: `bash tests/swarm_smoke.sh`
Expected: FAIL on missing telemetry fields

- [ ] **Step 3: Implement task and project-level telemetry fields**

Keep output concise and machine-friendly.

- [ ] **Step 4: Re-run tests and verify pass**

Run: `bash tests/swarm_smoke.sh`
Expected: PASS with usable telemetry payloads

- [ ] **Step 5: Commit**

```bash
git add lib/cmd/state.sh lib/decision_trace.sh tests/swarm_smoke.sh README.md
git commit -m "feat: expose scheduler and recovery telemetry for swarm mode"
```

### Task 15: TUI Swarm Panels

**Files:**
- Modify: `cmd/orchd-tui/state.go`
- Modify: `cmd/orchd-tui/types.go`
- Modify: `cmd/orchd-tui/view.go`
- Test: `go test ./cmd/orchd-tui/...`

- [ ] **Step 1: Add failing Go tests for swarm state rendering**

Show:
- runner/role routing
- task risk and verification tier
- recovery class
- last decision reason

- [ ] **Step 2: Run Go tests and verify failure**

Run: `go test ./cmd/orchd-tui/...`
Expected: FAIL before new fields are modeled/rendered

- [ ] **Step 3: Implement state decoding and views**

Avoid clutter; prefer one compact throughput panel and one selected-task swarm detail panel.

- [ ] **Step 4: Re-run Go tests and verify pass**

Run: `go test ./cmd/orchd-tui/...`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add cmd/orchd-tui/state.go cmd/orchd-tui/types.go cmd/orchd-tui/view.go cmd/orchd-tui/*_test.go
git commit -m "feat: add swarm routing and recovery panels to TUI"
```

### Task 16: Rollout Flags and Safe Migration Path

**Files:**
- Modify: `README.md`
- Modify: `ORCHESTRATOR.md`
- Modify: `orchestrator-runbook.md`
- Test: `tests/smoke.sh`

- [ ] **Step 1: Add failing docs/smoke assertions**

Required docs references:
- `swarm_mode = off|observe|on`
- `verification_policy = adaptive`
- `finish` mode
- role routing examples

- [ ] **Step 2: Run tests and verify failure**

Run: `bash tests/smoke.sh`
Expected: FAIL until docs are updated

- [ ] **Step 3: Document safe rollout**

Suggested rollout:
- `swarm_mode = off` -> legacy behavior
- `swarm_mode = observe` -> routing + telemetry only
- `swarm_mode = on` -> full policy enforcement

- [ ] **Step 4: Re-run tests and verify pass**

Run: `bash tests/smoke.sh`
Expected: PASS with updated docs references

- [ ] **Step 5: Commit**

```bash
git add README.md ORCHESTRATOR.md orchestrator-runbook.md tests/smoke.sh
git commit -m "docs: add swarm v2 rollout guide and migration path"
```

---

## Final Validation Wave

### Task 17: End-to-End Swarm Finisher Validation

**Files:**
- Modify: `tests/swarm_smoke.sh`
- Modify: `TASK_REPORT.md`

- [ ] **Step 1: Add one integrated scenario**

Scenario should cover:
- role-based routing
- adaptive verification
- one recoverable failure
- one fallback to alternate runner
- merge of mixed-risk tasks
- terminal completion or next-phase ideation

- [ ] **Step 2: Run the full suite**

Run:
- `bash tests/config_get.sh`
- `bash tests/smoke.sh`
- `bash tests/swarm_smoke.sh`
- `go test ./...`

- [ ] **Step 3: Capture evidence and risks**

Update `TASK_REPORT.md` with concise evidence, rollback criteria, and any rollout risks.

- [ ] **Step 4: Commit release-candidate wave**

```bash
git add tests/swarm_smoke.sh TASK_REPORT.md
git commit -m "test: validate orchd v2 swarm finisher flow"
```

---

## Execution Notes

- Keep commit boundaries aligned with one task at a time.
- Prefer additive modules over risky in-place rewrites of `lib/core.sh`.
- Preserve `worker.runner` compatibility until at least one release after `swarm.roles` lands.
- If verification throughput regresses, tune tier thresholds before expanding automation.
- If runner fallback causes surprising behavior, surface the reason in `state --json` and TUI before changing policy.

## Success Criteria (Plan Acceptance)

- `orchd` can route roles across user-selected runners without hard provider coupling.
- scheduler leaves no idle tick while actionable work exists.
- low-risk tasks no longer pay full-suite cost by default.
- failed tasks are classified and recovered automatically in common cases.
- `orchd finish` can drive a project to terminal completion or explicit next-phase ideation.
- core smoke/config/Go tests remain stable during rollout.
