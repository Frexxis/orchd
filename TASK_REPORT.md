Summary of changes

- Extended `orchd state --json` with project-level swarm telemetry: scheduler decisions, orchestrator route/reminder metadata, finisher state, and richer per-task review/merge/split fields.
- Added automatic risky-merge reviewer support in the merge path, refactored review execution into reusable helpers, and added `templates/reviewer.prompt` while preserving the legacy review prompt path.
- Upgraded the Go TUI to understand and render swarm/routing/recovery/review/finisher data in task detail and project stats views.
- Expanded fleet and doctor visibility to surface finisher state and last scheduler action across projects.
- Updated rollout/docs for `orchd finish`, `swarm_mode` migration guidance, `auto_review`, and v2 telemetry surfaces across `README.md`, `ORCHESTRATOR.md`, `WORKER.md`, and `orchestrator-runbook.md`.
- Added end-to-end-ish regression coverage for scheduler/orchestrator telemetry, reviewer-assisted risky merge behavior, integrated finisher flow, and updated docs assertions.
- Stabilized sticky orchestrator reminders by avoiding scheduler timestamp churn when the decision itself has not changed.

Files modified/created

- `README.md`
- `ORCHESTRATOR.md`
- `WORKER.md`
- `orchestrator-runbook.md`
- `lib/core.sh`
- `lib/decision_trace.sh`
- `lib/cmd/state.sh`
- `lib/cmd/review.sh`
- `lib/cmd/merge.sh`
- `lib/cmd/fleet.sh`
- `lib/cmd/doctor.sh`
- `lib/cmd/init.sh`
- `templates/reviewer.prompt`
- `cmd/orchd-tui/types.go`
- `cmd/orchd-tui/model.go`
- `cmd/orchd-tui/view.go`
- `cmd/orchd-tui/state_test.go`
- `cmd/orchd-tui/view_test.go`
- `tests/swarm_smoke.sh`
- `tests/smoke.sh`
- `TASK_REPORT.md`

Evidence

EVIDENCE:
- CMD: bash -n lib/core.sh lib/decision_trace.sh lib/cmd/state.sh lib/cmd/review.sh lib/cmd/merge.sh lib/cmd/fleet.sh lib/cmd/doctor.sh lib/cmd/init.sh tests/swarm_smoke.sh tests/smoke.sh
  RESULT: PASS
  OUTPUT: Shell syntax check passed for all edited shell files.

EVIDENCE:
- CMD: bash tests/config_get.sh
  RESULT: PASS
  OUTPUT: 24 passed, 0 failed, 24 total.

EVIDENCE:
- CMD: bash tests/swarm_smoke.sh
  RESULT: PASS
  OUTPUT: 54 passed, 0 failed, 54 total.

EVIDENCE:
- CMD: bash tests/smoke.sh
  RESULT: PASS
  OUTPUT: 199 passed, 0 failed, 199 total.

EVIDENCE:
- CMD: go test ./...
  RESULT: PASS
  OUTPUT: Go packages passed, including `cmd/orchd-tui` swarm rendering/state tests.

Rollback note

- Trigger rollback if `state --json` telemetry causes orchestration loops to churn, if risky tasks stop merging despite approved review/targeted verification, if sticky orchestrator wake-ups regress, or if TUI/fleet state views become misleading after scheduler or finisher updates.
- How to revert: revert the commit containing the telemetry/review/TUI/docs/test wave, or restore the touched files to the previous revision and re-run `bash tests/config_get.sh`, `bash tests/swarm_smoke.sh`, `bash tests/smoke.sh`, and `go test ./...`.

Risks/notes

- Automatic reviewer behavior currently activates at merge time when risky merge policy can be satisfied by review approval; it does not add a separate always-on reviewer queue before every risky task completes.
- `swarm_mode` rollout guidance is documented, but current compatibility still relies on existing v2-safe defaults rather than a newly enforced runtime mode switch.
- The new scheduler telemetry intentionally avoids updating timestamps when the decision has not changed, so downstream consumers should treat `updated_at` as a semantic-change marker, not a heartbeat.

---

Incremental update: review/resume regression fix

Summary of changes

- Fixed built-in review runners so task reviews execute from the task worktree instead of the base project checkout.
- Fixed `orchd resume` so non-failed resumes keep the task's current runner and do not get retagged onto the recovery route.
- Added smoke coverage for both regressions.

Files modified/created

- `lib/cmd/review.sh`
- `lib/cmd/resume.sh`
- `tests/swarm_smoke.sh`
- `TASK_REPORT.md`

Evidence

EVIDENCE:
- CMD: bash -n lib/cmd/review.sh lib/cmd/resume.sh tests/swarm_smoke.sh
  RESULT: PASS
  OUTPUT: Shell syntax check passed for the updated review, resume, and swarm smoke scripts.

EVIDENCE:
- CMD: bash tests/swarm_smoke.sh
  RESULT: PASS
  OUTPUT: 59 passed, 0 failed, 59 total.

Rollback note

- Trigger rollback if `orchd review --task` reads files from the wrong checkout again, or if resuming a `done` task switches from its stored runner to the recovery runner.
- How to revert: revert the commit containing this regression fix, then rerun `bash tests/swarm_smoke.sh`.

Risks/notes

- The new review regression test exercises the built-in `claude` path as the proxy for built-in runner cwd behavior; the same worktree fix was applied to `codex`, `opencode`, and `aider`.

---

Incremental update: README onboarding polish and v2 release notes

Summary of changes

- Simplified the top of `README.md` so new users see a shorter install -> init -> plan -> finish path first.
- Added a clearer "Before You Start", "Simple Mental Model", and "Typical First Run" onboarding flow so advanced orchestration concepts are no longer the first thing a new user has to parse.
- Added `docs/releases/2026-03-24-orchd-v2.md` with release highlights, a GitHub release body, and short/long announcement copy for sharing orchd v2.

Files modified/created

- `README.md`
- `docs/releases/2026-03-24-orchd-v2.md`
- `TASK_REPORT.md`

Evidence

EVIDENCE:
- CMD: bash tests/smoke.sh
  RESULT: PASS
  OUTPUT: 199 passed, 0 failed, 199 total.

Rollback note

- Trigger rollback if the simplified README misrepresents the recommended workflow, if new users are pushed toward an incomplete happy path, or if the release-note copy diverges from shipped v2 behavior.
- How to revert: revert the commit containing the onboarding/release-notes update, then rerun `bash tests/smoke.sh`.

Risks/notes

- This wave is docs-only; it changes onboarding and release communication, not runtime behavior.
- The install story is still source-first; packaging remains a follow-on improvement even with a much clearer first-run path.

---

Incremental update: agent-first orchestration onboarding

Summary of changes

- Added `orchd agent-prompt` so users can generate a copy-paste orchestrator/worker/reviewer prompt for an external coding agent instead of manually driving the CLI.
- Repositioned the top of `README.md` around the real primary flow: open an external agent, paste the orchestrator prompt, and let that agent use orchd.
- Updated `ORCHESTRATOR.md` and the v2 release note doc so generated/refreshable orchd docs now explicitly describe the agent-first handoff model.
- Added smoke coverage for raw-repo and initialized-repo `agent-prompt` usage plus help/docs visibility.

Files modified/created

- `bin/orchd`
- `lib/cmd/agent_prompt.sh`
- `README.md`
- `ORCHESTRATOR.md`
- `docs/releases/2026-03-24-orchd-v2.md`
- `tests/smoke.sh`
- `TASK_REPORT.md`

Evidence

EVIDENCE:
- CMD: bash -n bin/orchd lib/cmd/agent_prompt.sh tests/smoke.sh
  RESULT: PASS
  OUTPUT: Shell syntax check passed for the new agent-prompt command and updated smoke coverage.

EVIDENCE:
- CMD: bash tests/smoke.sh
  RESULT: PASS
  OUTPUT: 206 passed, 0 failed, 206 total.

Rollback note

- Trigger rollback if `orchd agent-prompt` generates misleading handoff text, if the README over-rotates toward agent-mediated usage and hides the direct CLI path too much, or if help/docs regressions make command discovery worse.
- How to revert: revert the commit containing the agent-first onboarding wave, then rerun `bash tests/smoke.sh`.

Risks/notes

- This wave improves onboarding and the agent handoff surface, but does not yet add a single-command runtime wrapper like `orchd run "goal"`.
- The primary workflow is now documented as agent-first, while the direct CLI path remains available for power users and debugging.
