# Task Report

## Summary

- Added `orchd autopilot` for fully autonomous spawn/check/merge execution.
- Added `orchd resume` + continuation prompt for retrying failed tasks in-place.
- Added `needs_input` task state (via `.orchd_needs_input.md`) and made autopilot treat it as terminal.
- Improved `orchd plan` parsing to support multi-line `DESCRIPTION`/`ACCEPTANCE` blocks.
- Made plan JSONL fallback portable (no `grep -oP`) and made `spawn --all` continue on per-task failures.
- Updated CI ShellCheck coverage, README, and smoke tests accordingly.

## Files Modified/Created

- .github/workflows/ci.yml
- README.md
- TASK_REPORT.md
- bin/orchd
- lib/cmd/autopilot.sh
- lib/cmd/resume.sh
- lib/cmd/plan.sh
- lib/cmd/spawn.sh
- lib/cmd/check.sh
- lib/cmd/board.sh
- templates/continue.prompt
- templates/kickoff.prompt
- tests/config_get.sh (file mode)
- tests/smoke.sh

## Tests Run

- ./tests/config_get.sh
- bash tests/smoke.sh (run from a non-orchd directory)
- shellcheck --exclude=SC1091 bin/orchd lib/core.sh lib/runner.sh lib/cmd/*.sh tests/*.sh

## Risks/Notes

- `orchd autopilot` is designed to run long-lived; run it inside `tmux`/systemd for 24/7 operation.
- Autopilot retries failed tasks with bounded attempts/backoff (`autopilot_retry_limit`, `autopilot_retry_backoff`), then marks tasks `needs_input`.
