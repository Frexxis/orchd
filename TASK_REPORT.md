# Task Report

## Summary

- Hardened the new Memory Bank, Idea Queue, and Fleet features after a multi-agent review.
- Fixed queue drain safety in autopilot:
  - Queue items are no longer popped when runner is unavailable.
  - Queue draining now considers in-progress items and supports queue-only startup (`orchd autopilot` can plan from queue when task list is empty).
- Fixed memory writeback behavior:
  - Preserve worker-authored lesson files (`docs/memory/lessons/{task_id}.md`) instead of overwriting.
  - Keep mechanical progress updates and auto-commit memory changes when `docs/memory` is clean.
- Removed `pipefail` hazards in planning context collection by replacing `find | head` with bounded `awk` selection.
- Fixed fleet path parsing for whitespace-containing paths (trim edges only, preserve internal spaces).
- Improved fleet daemon reliability checks (verify PID is alive after start).
- Implemented real time-window filtering for `fleet brief [hours]` using log timestamps.
- Hardened memory status char counting when no lesson files exist.
- Normalized UX: `orchd spawn --help` now exits successfully.
- Updated docs and CI for consistency:
  - README command/behavior alignment (`await`, `plan --runner`, autopilot daemon flags, testing wording, memory/fleet behavior wording).
  - CI ShellCheck now includes `lib/cmd/state.sh` and `lib/cmd/await.sh`.
- Expanded smoke tests with targeted regressions for:
  - queue drain behavior when runner is unavailable,
  - fleet paths containing spaces,
  - spawn help exit behavior.

## Files Modified/Created

- `.github/workflows/ci.yml`
- `README.md`
- `bin/orchd`
- `lib/core.sh`
- `lib/cmd/autopilot.sh`
- `lib/cmd/fleet.sh`
- `lib/cmd/memory.sh`
- `lib/cmd/merge.sh`
- `lib/cmd/plan.sh`
- `lib/cmd/spawn.sh`
- `tests/smoke.sh`

## Tests Run

- `shellcheck --exclude=SC1091 bin/orchd lib/*.sh lib/cmd/*.sh tests/smoke.sh`
- `bash tests/smoke.sh` -> `109 passed, 0 failed`

EVIDENCE:
- CMD: `shellcheck --exclude=SC1091 bin/orchd lib/*.sh lib/cmd/*.sh tests/smoke.sh`
  RESULT: PASS
  OUTPUT: No findings.
- CMD: `bash tests/smoke.sh`
  RESULT: PASS
  OUTPUT: `=== Results: 109 passed, 0 failed, 109 total ===`

## Rollback Note

- Trigger rollback if: queue ideas start getting stuck in `[>]`, fleet paths with spaces regress, or merge starts leaving unexpected dirty `docs/memory` state on clean repos.
- Revert with: `git revert <this-change-sha>` (or selectively revert affected files: `lib/cmd/autopilot.sh`, `lib/core.sh`, `lib/cmd/merge.sh`, `lib/cmd/fleet.sh`, `lib/cmd/plan.sh`).

## Risks/Notes

- Memory auto-commit in merge runs only when `docs/memory` has no pre-existing local changes; when local edits exist, memory is still updated but auto-commit is skipped to avoid mixing with user edits.
