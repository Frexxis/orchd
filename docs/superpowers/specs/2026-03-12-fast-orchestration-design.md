# Fast Orchestration Design

## Goal

Make `orchd` finish projects faster by reducing orchestration idle time, increasing safe parallelism, and avoiding duplicate verification work when the user explicitly chooses a speed-focused workflow.

## Problem

Current orchestration favors safety over throughput:

- `autopilot` waits on fixed polling intervals instead of reacting quickly to finished agents.
- default parallelism is conservative.
- `check` and `merge` can rerun expensive full-repo verification for every task.
- retries use long backoff windows that leave the pipeline idle.

These behaviors are individually reasonable, but together they make worker execution feel fast and orchestration feel slow.

## Design Overview

Introduce an explicit orchestration profile system with a new `fast` mode.

Profiles affect operational defaults, not the user's explicit config. Existing repositories keep current behavior unless they opt into a faster profile. New repositories can still default to the current balanced behavior while exposing the faster lane clearly.

The first version of `fast` mode focuses on three high-value changes:

1. event-driven waiting in `autopilot` using `orchd await --all`
2. higher effective parallelism and shorter retry backoff
3. lighter verification policy for `check` and `merge`

## Configuration Model

Add a new orchestrator setting:

- `orchestrator.profile = "balanced" | "fast" | "safe"`

Profile rules:

- explicit user config still wins
- profile values only fill in missing settings
- old configs without a profile behave like `balanced`

Target profile defaults:

- `safe`: current conservative behavior
- `balanced`: near-current behavior with small responsiveness improvements
- `fast`: aggressive waiting, higher concurrency, lighter repeated checks

## Fast Profile Behavior

### Waiting

- `autopilot` stops relying on the end-of-loop fixed `sleep`
- it uses `orchd await --all --timeout <poll>` so agent exits wake the loop early
- if nothing changes, timeout preserves the periodic heartbeat

### Concurrency

- higher effective default for `max_parallel`
- intended target: `8` in fast mode unless the repo config overrides it

### Retries

- lower default retry backoff in fast mode
- intended target: `10` seconds base backoff instead of `60`

### Quality Gates

Add a verification mode:

- `quality.verification_profile = "strict" | "fast"`

Behavior:

- `strict`: keep current `lint + test + build` gate behavior
- `fast`: prefer `test`, skip `build` when a `test` command is available, and avoid paying for redundant full-repo verification on every task

This keeps a correctness signal while removing the most repetitive cost.

### Post-Merge Verification

Add:

- `quality.post_merge_test = "always" | "never"`

Behavior:

- `always`: current behavior
- `never`: skip merge-time rerun because the task was already validated during `check`

Fast profile defaults to `never`.

## Command Surface

No new top-level command is required for the first version.

Users enable fast execution through config, and `orchd doctor` should clearly show:

- configured profile
- effective parallelism
- effective autopilot poll
- effective retry backoff
- effective verification profile
- effective post-merge test policy

## Files Affected

- `lib/core.sh` for profile-aware config helpers
- `lib/cmd/autopilot.sh` for event-driven waiting and fast defaults
- `lib/cmd/check.sh` for lighter fast verification behavior
- `lib/cmd/merge.sh` for optional post-merge test skipping
- `lib/cmd/init.sh` for new config keys
- `lib/cmd/doctor.sh` for effective profile reporting
- `README.md` for user-facing docs
- `tests/smoke.sh` and `tests/config_get.sh` for regression coverage

## Risks

- fast mode can ship code with weaker per-task guarantees if a repo relies on build failures more than test failures
- higher concurrency can increase resource pressure on smaller machines
- changing defaults globally would be risky, so fast behavior should stay opt-in

## Success Criteria

- users can opt into a documented fast profile without manual patching
- `autopilot` reacts to finished work faster than fixed-interval sleeping
- smoke tests cover the new fast-profile behavior
- existing balanced behavior remains compatible for repos that do not opt in
