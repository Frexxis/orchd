# Task Report

## Summary

- Added `orchd plan --help` output (was incorrectly treated as a description and invoked the planner).
- Added Codex runner flag support via `.orchd.toml` (`codex_flags`) and defaulted to write-enabled mode.
- Documented runner sandbox note in `orchd --help` and `.orchd.toml` template.

## Files Modified/Created

- bin/orchd
- lib/cmd/init.sh
- lib/cmd/plan.sh
- lib/runner.sh

## Tests Run

- ./tests/smoke.sh
- ./tests/config_get.sh

## Risks/Notes

- TASK_REPORT.md validation is intentionally minimal (presence of EVIDENCE/CMD/RESULT/OUTPUT + rollback keyword).
