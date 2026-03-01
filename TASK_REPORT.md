# Task Report

## Summary

- Prevented TASK_REPORT.md merge conflicts:
  - Ignore agent artifacts in .gitignore by default (TASK_REPORT.md, .orchd_needs_input.md).
  - Archive TASK_REPORT.md into `.orchd/tasks/<task-id>/` during `orchd check` so evidence survives worktree cleanup.
  - Auto-resolve merge conflicts caused only by TASK_REPORT.md.
- Improved conflict-state ergonomics: `orchd merge <task>` detects manually merged conflict tasks and marks them merged.
- Updated worker guidance to keep TASK_REPORT.md local (not committed).
- Made smoke tests robust to existing tmux sessions.

- Added optional per-task `LINT_CMD`/`TEST_CMD`/`BUILD_CMD` in plans; `orchd check` uses these as overrides (task > global config > auto-detect).

## Files Modified/Created

- WORKER.md
- lib/core.sh
- lib/cmd/check.sh
- lib/cmd/init.sh
- lib/cmd/merge.sh
- tests/smoke.sh
- ORCHESTRATOR.md
- lib/cmd/check.sh
- lib/cmd/plan.sh
- lib/core.sh
- templates/plan.prompt

## Tests Run

- ./tests/smoke.sh
- ./tests/config_get.sh

## Risks/Notes

- TASK_REPORT.md validation is intentionally minimal (presence of EVIDENCE/CMD/RESULT/OUTPUT + rollback keyword).
