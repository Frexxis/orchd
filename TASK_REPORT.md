# Task Report

## Summary

- Ensured agent policy docs are present inside each worktree on spawn/resume (workers can always read AGENTS/WORKER docs).
- Made `orchd check` validate TASK_REPORT.md has evidence + rollback note.
- Fixed autopilot terminal condition so failed tasks are retryable (no premature exit during backoff).
- Added a merge lock to prevent concurrent merges from corrupting git state.
- Standardized blocker protocol in kickoff prompt: use `.orchd_needs_input.md`.

## Files Modified/Created

- lib/cmd/autopilot.sh
- lib/cmd/check.sh
- lib/cmd/merge.sh
- lib/cmd/resume.sh
- lib/cmd/spawn.sh
- templates/kickoff.prompt

## Tests Run

- ./tests/smoke.sh
- ./tests/config_get.sh

## Risks/Notes

- TASK_REPORT.md validation is intentionally minimal (presence of EVIDENCE/CMD/RESULT/OUTPUT + rollback keyword).
