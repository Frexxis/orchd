# Task Report

## Summary

- Added agent policy docs, refresh command, and review-mode prompt support.
- Added doctor command and auto-detect quality commands to reduce config needs.
- Updated templates, README, and smoke tests to cover new utilities.

## Files Modified/Created

- AGENTS.md
- CLAUDE.md
- ORCHESTRATOR.md
- WORKER.md
- README.md
- bin/orchd
- lib/core.sh
- lib/cmd/check.sh
- lib/cmd/init.sh
- lib/cmd/doctor.sh
- lib/cmd/refresh_docs.sh
- lib/cmd/review.sh
- templates/plan.prompt
- templates/kickoff.prompt
- templates/review.prompt
- tests/smoke.sh
- TASK_REPORT.md

## Tests Run

- bash tests/config_get.sh
- ./tests/smoke.sh
- shellcheck --exclude=SC1091 bin/orchd lib/core.sh lib/runner.sh lib/cmd/init.sh lib/cmd/plan.sh lib/cmd/review.sh lib/cmd/spawn.sh lib/cmd/board.sh lib/cmd/check.sh lib/cmd/merge.sh lib/cmd/doctor.sh lib/cmd/refresh_docs.sh tests/config_get.sh tests/smoke.sh

## Risks/Notes

- Review prompt context includes full diffs; very large diffs may hit model/context limits.
- Auto-detected lint/test/build commands are best-effort; override via .orchd.toml for edge cases.
