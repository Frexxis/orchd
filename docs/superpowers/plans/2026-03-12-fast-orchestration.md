# Fast Orchestration Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in fast orchestration profile that reduces idle wait time, increases worker parallelism, and trims duplicate verification work.

**Architecture:** Add profile-aware config helpers in shared core utilities, then route `autopilot`, `check`, `merge`, `init`, and `doctor` through those helpers. Keep existing behavior available through explicit `balanced` and `safe` settings, and cover fast-mode behavior with shell regressions.

**Tech Stack:** Bash, git worktrees, shell smoke tests, Go project quality commands

---

## Chunk 1: Profile-Aware Config Foundation

### Task 1: Add effective profile helpers and config scaffolding

**Files:**
- Modify: `lib/core.sh`
- Modify: `lib/cmd/init.sh`
- Modify: `lib/cmd/doctor.sh`
- Test: `tests/config_get.sh`
- Test: `tests/smoke.sh`

- [ ] **Step 1: Write failing regression coverage for profile-aware config reporting**

Add shell assertions that expect `doctor` to surface a configured orchestrator profile and its effective verification settings.

- [ ] **Step 2: Run the targeted regression test and verify it fails**

Run: `./tests/config_get.sh && ./tests/smoke.sh`
Expected: FAIL because the new profile fields are not reported yet.

- [ ] **Step 3: Implement minimal profile-aware config helpers**

Add shared helpers that:
- resolve orchestrator profile (`safe`, `balanced`, `fast`)
- return explicit config first
- otherwise fall back to profile defaults

Use these helpers in `doctor` and initialize the new keys in `init`.

- [ ] **Step 4: Run targeted tests and verify they pass**

Run: `./tests/config_get.sh && ./tests/smoke.sh`
Expected: PASS with doctor showing configured and effective fast settings.

## Chunk 2: Event-Driven Autopilot

### Task 2: Replace fixed sleep behavior with await-driven waiting

**Files:**
- Modify: `lib/cmd/autopilot.sh`
- Test: `tests/smoke.sh`

- [ ] **Step 1: Write a failing smoke test for fast autopilot responsiveness settings**

Add a smoke assertion that a fast-profile repo uses reduced effective polling/backoff values and still completes the done-task autopilot flow.

- [ ] **Step 2: Run the targeted smoke test and verify it fails**

Run: `./tests/smoke.sh`
Expected: FAIL because autopilot still uses the old waiting defaults.

- [ ] **Step 3: Implement await-driven waiting with profile-aware defaults**

Update `autopilot` to:
- use effective poll and backoff helpers
- wait through `cmd_await` instead of raw `sleep` where appropriate
- preserve timeout-based loop progress when nothing changes

- [ ] **Step 4: Run targeted smoke tests and verify they pass**

Run: `./tests/smoke.sh`
Expected: PASS with no regression in existing autopilot flows.

## Chunk 3: Fast Verification Lane

### Task 3: Add fast-mode quality and merge verification controls

**Files:**
- Modify: `lib/cmd/check.sh`
- Modify: `lib/cmd/merge.sh`
- Modify: `README.md`
- Test: `tests/smoke.sh`

- [ ] **Step 1: Write failing smoke tests for fast verification behavior**

Add shell coverage that expects:
- fast verification to skip redundant build execution when test coverage already exists
- fast post-merge policy to skip merge-time rerun when configured

- [ ] **Step 2: Run the targeted smoke test and verify it fails**

Run: `./tests/smoke.sh`
Expected: FAIL because `check` and `merge` still use strict repeated verification.

- [ ] **Step 3: Implement minimal fast verification behavior**

Update `check` and `merge` to honor effective verification settings while keeping strict mode unchanged.

- [ ] **Step 4: Run the full verification suite and verify it passes**

Run: `go test ./... && ./tests/config_get.sh && ./tests/smoke.sh`
Expected: PASS.

- [ ] **Step 5: Update user-facing documentation**

Document the new profile and verification knobs in `README.md` with examples for speed-focused users.
