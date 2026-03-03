# Task Report

## Summary

- Added true autonomous mode via ideation:
  - New `orchd ideate` command generates the next backlog from `docs/memory/` + codebase context.
  - New `orchd autopilot --continuous` runs ideate -> plan -> execute cycles until ideation returns `PROJECT_COMPLETE`.
  - Continuous mode works with the daemon: `orchd autopilot --daemon --continuous [poll_seconds]`.
- Added `templates/ideate.prompt` to enforce a strict, parseable ideation output format.
- Added `.orchd.toml` defaults under `[ideate]` (max ideas, cooldown, max cycles, failure cap) and display them in `orchd doctor`.
- Hardened CLI/test ergonomics:
  - `tests/smoke.sh` `assert_output_contains` now uses `grep -q --` (patterns starting with `-` are safe).
  - Added smoke coverage for `ideate` parsing and `autopilot --continuous` help.
- Autopilot continuous-mode robustness:
  - Ideation failures no longer terminate autopilot/daemon immediately; it waits and retries until success, `PROJECT_COMPLETE`, or the configured failure cap.
- Critical fixes from PR review (P1/P2 issues):
  - **Fixed**: `task_count > 0` check was incorrectly counting all tasks (including merged), causing in-progress ideas to be marked complete prematurely. Now only counts active (pending/running) tasks.
  - **Fixed**: `runner == "none"` in continuous mode now returns error code 3 (fatal) instead of 1, preventing infinite retry loops when no AI runner is configured.
  - **Fixed**: `_ideate_parse_output` now handles the last line even when output lacks a trailing newline (using `|| [[ -n "$line" ]]` pattern).

## Files Modified/Created

- `.github/workflows/ci.yml`
- `ORCHESTRATOR.md`
- `README.md`
- `bin/orchd`
- `lib/core.sh`
- `lib/cmd/autopilot.sh`
- `lib/cmd/doctor.sh`
- `lib/cmd/init.sh`
- `lib/cmd/ideate.sh`
- `orchestrator-runbook.md`
- `templates/ideate.prompt`
- `tests/smoke.sh`

## Tests Run

- `shellcheck --exclude=SC1091 bin/orchd lib/*.sh lib/cmd/*.sh tests/smoke.sh`
- `bash tests/smoke.sh` -> `=== Results: 114 passed, 0 failed, 114 total ===`

EVIDENCE:
- CMD: `shellcheck --exclude=SC1091 bin/orchd lib/*.sh lib/cmd/*.sh tests/smoke.sh`
  RESULT: PASS
  OUTPUT: No findings.
- CMD: `bash tests/smoke.sh`
  RESULT: PASS
  OUTPUT: `=== Results: 114 passed, 0 failed, 114 total ===`

## Risks/Notes

- Continuous mode depends on the orchestrator runner producing output that matches `templates/ideate.prompt`. If it drifts, ideation may fail/loop until `ideate.max_consecutive_failures` is hit.
- `autopilot --continuous` includes guardrails: cooldown, max cycles, and failure cap (configurable under `[ideate]`).

## Rollback Note

- Trigger rollback if: continuous autopilot fails to stop on `PROJECT_COMPLETE`, or starts consuming queue items without planning new tasks.
- Revert with: `git revert <sha>` (or selectively revert `lib/cmd/autopilot.sh`, `lib/cmd/ideate.sh`, `templates/ideate.prompt`, `bin/orchd`).
