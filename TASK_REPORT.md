# Task Report

## Summary of Changes

- Hardened `orchd plan` parsing by making JSONL text extraction tolerant (jq path + python fallback for multiple event shapes).
- Made Python quality detection and worktrees venv-aware: prefer `.venv/bin/*` and optionally symlink `.venv` into worktrees.
- Added `pytest` `test_cmd` validation to catch missing paths early, with "did you mean" suggestions.
- Reduced stuck-agent false positives by writing an explicit exit marker file (`.orchd/logs/<task>.exit`) and reading it first.
- Reduced commit noise by staging `docs/memory/*` into the merge commit (instead of a separate memory-only commit).
- Added `orchd reconcile` to repair task status/worktree fields against git and local reality.

## Files Modified/Created

- Modified: `bin/orchd`
- Modified: `lib/core.sh`
- Modified: `lib/runner.sh`
- Modified: `lib/cmd/plan.sh`
- Modified: `lib/cmd/check.sh`
- Modified: `lib/cmd/merge.sh`
- Modified: `lib/cmd/spawn.sh`
- Modified: `lib/cmd/resume.sh`
- Modified: `tests/smoke.sh`
- Added: `lib/cmd/reconcile.sh`

## Tests Run

EVIDENCE:
- CMD: `bash tests/config_get.sh`
  RESULT: PASS
  OUTPUT: `=== Results: 11 passed, 0 failed, 11 total ===`
- CMD: `bash tests/smoke.sh`
  RESULT: PASS
  OUTPUT: `=== Results: 119 passed, 0 failed, 119 total ===`

## Risks/Notes

- `pytest` arg validation is best-effort; it intentionally skips globs and nodeid suffixes (`::...`).
- Memory updates are staged into merge commits only when `docs/memory` has no tracked local changes; otherwise they are updated but left unstaged.

## Rollback Note

- Trigger rollback if: merges start leaving repos in merge-in-progress state unexpectedly, or `orchd check` starts false-failing valid pytest commands.
- Revert with: `git revert <sha>`.
