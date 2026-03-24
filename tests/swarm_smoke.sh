#!/usr/bin/env bash
# swarm_smoke.sh - Focused scheduler and swarm behavior regressions
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
export ORCHD_LIB_DIR="$ROOT_DIR/lib"

die() {
	printf '%s\n' "$*" >&2
	return 1
}

# shellcheck source=../lib/core.sh
source "$ROOT_DIR/lib/core.sh"
# shellcheck source=../lib/runner.sh
source "$ROOT_DIR/lib/runner.sh"
# shellcheck source=../lib/swarm.sh
source "$ROOT_DIR/lib/swarm.sh"
# shellcheck source=../lib/verify.sh
source "$ROOT_DIR/lib/verify.sh"
# shellcheck source=../lib/recovery.sh
source "$ROOT_DIR/lib/recovery.sh"
# shellcheck source=../lib/decision_trace.sh
source "$ROOT_DIR/lib/decision_trace.sh"
# shellcheck source=../lib/cmd/merge.sh
source "$ROOT_DIR/lib/cmd/merge.sh"
# shellcheck source=../lib/cmd/plan.sh
source "$ROOT_DIR/lib/cmd/plan.sh"
# shellcheck source=../lib/cmd/resume.sh
source "$ROOT_DIR/lib/cmd/resume.sh"
# shellcheck source=../lib/cmd/review.sh
source "$ROOT_DIR/lib/cmd/review.sh"
# shellcheck source=../lib/cmd/autopilot.sh
source "$ROOT_DIR/lib/cmd/autopilot.sh"
# shellcheck source=../lib/cmd/spawn.sh
source "$ROOT_DIR/lib/cmd/spawn.sh"
# shellcheck source=../lib/cmd/orchestrate.sh
source "$ROOT_DIR/lib/cmd/orchestrate.sh"
# shellcheck source=../lib/cmd/state.sh
source "$ROOT_DIR/lib/cmd/state.sh"
# shellcheck source=../lib/cmd/ideate.sh
source "$ROOT_DIR/lib/cmd/ideate.sh"

PASS=0
FAIL=0
TOTAL=0

pass() {
	PASS=$((PASS + 1))
	TOTAL=$((TOTAL + 1))
	printf '  PASS: %s\n' "$1"
}

fail() {
	FAIL=$((FAIL + 1))
	TOTAL=$((TOTAL + 1))
	printf '  FAIL: %s\n' "$1" >&2
}

assert_eq() {
	local desc=$1
	local expected=$2
	local actual=$3
	if [[ "$actual" == "$expected" ]]; then
		pass "$desc"
	else
		fail "$desc (expected '$expected', got '$actual')"
	fi
}

cleanup() {
	if [[ -n "${TMP_SWARM_DIR:-}" ]] && [[ -d "$TMP_SWARM_DIR" ]]; then
		rm -rf "$TMP_SWARM_DIR"
	fi
}

trap cleanup EXIT

printf '=== swarm scheduler smoke tests ===\n\n'

TMP_SWARM_DIR=$(mktemp -d)
export PROJECT_ROOT="$TMP_SWARM_DIR/project"
export ORCHD_DIR="$TMP_SWARM_DIR/project/.orchd"
export TASKS_DIR="$ORCHD_DIR/tasks"
export LOGS_DIR="$ORCHD_DIR/logs"
mkdir -p "$PROJECT_ROOT" "$TASKS_DIR" "$LOGS_DIR"
cat >"$PROJECT_ROOT/.orchd.toml" <<'EOF'
custom_runner_cmd = "printf ok"

[swarm.roles]
recovery = ["custom", "codex"]
reviewer = ["custom"]
EOF

printf '[1] Shared scheduler decision priority\n'
assert_eq "merge beats lower-priority actions" "merge" "$(scheduler_next_action 1 2 3 4 5 false false)"
assert_eq "check beats spawn/recover/ideate" "check" "$(scheduler_next_action 0 2 3 4 5 false false)"
assert_eq "spawn beats recover/ideate" "spawn" "$(scheduler_next_action 0 0 3 4 5 false false)"
assert_eq "recover beats ideate" "recover" "$(scheduler_next_action 0 0 0 4 5 false false)"
assert_eq "ideate beats wait" "ideate" "$(scheduler_next_action 0 0 0 0 5 false false)"
assert_eq "blocked beats wait" "blocked" "$(scheduler_next_action 0 0 0 0 0 true false)"
assert_eq "complete beats all workless states" "complete" "$(scheduler_next_action 0 0 0 0 0 false true)"

printf '\n[2] Deterministic autopilot scheduler helper\n'
AUTOPILOT_TOTAL=4
AUTOPILOT_PENDING=1
AUTOPILOT_RUNNING=1
AUTOPILOT_DONE=1
AUTOPILOT_MERGED=0
AUTOPILOT_FAILED=1
AUTOPILOT_CONFLICT=0
AUTOPILOT_NEEDS_INPUT=0
AUTOPILOT_READY_MERGE=1
AUTOPILOT_READY_CHECK=1
AUTOPILOT_READY_SPAWN=1
AUTOPILOT_READY_RECOVER=1
assert_eq "autopilot helper prioritizes merge first" "merge" "$(_autopilot_next_action)"

AUTOPILOT_READY_MERGE=0
assert_eq "autopilot helper then prioritizes check" "check" "$(_autopilot_next_action)"

AUTOPILOT_READY_CHECK=0
assert_eq "autopilot helper then prioritizes spawn" "spawn" "$(_autopilot_next_action)"

AUTOPILOT_READY_SPAWN=0
assert_eq "autopilot helper then prioritizes recover" "recover" "$(_autopilot_next_action)"

AUTOPILOT_READY_RECOVER=0
AUTOPILOT_NEEDS_INPUT=1
AUTOPILOT_FAILED=0
AUTOPILOT_PENDING=0
AUTOPILOT_RUNNING=0
AUTOPILOT_DONE=0
AUTOPILOT_TOTAL=1
assert_eq "autopilot helper treats needs_input-only state as terminal" "complete" "$(_autopilot_next_action)"

mkdir -p "$TASKS_DIR/autopilot-no-runner-failed" "$TASKS_DIR/autopilot-no-runner-conflict"
printf 'failed\n' >"$TASKS_DIR/autopilot-no-runner-failed/status"
printf 'conflict\n' >"$TASKS_DIR/autopilot-no-runner-conflict/status"
_autopilot_collect_scheduler_state "none"
assert_eq "autopilot schedules failed/conflict tasks for recovery even without runner" "recover" "$(_autopilot_next_action)"
_autopilot_retry_failed "none" >/dev/null
assert_eq "autopilot converts failed task to needs_input when runner unavailable" "needs_input" "$(task_status "autopilot-no-runner-failed")"
assert_eq "autopilot converts conflict task to needs_input when runner unavailable" "needs_input" "$(task_status "autopilot-no-runner-conflict")"
_autopilot_collect_scheduler_state "none"
assert_eq "autopilot can complete after runnerless recovery fallback" "complete" "$(_autopilot_next_action)"

printf '\n[3] Orchestrator scheduler helper\n'
ORCH_STATE_TOTAL=3
ORCH_STATE_PENDING=0
ORCH_STATE_RUNNING=2
ORCH_STATE_DONE=1
ORCH_STATE_MERGED=0
ORCH_STATE_FAILED=0
ORCH_STATE_CONFLICT=0
ORCH_STATE_NEEDS_INPUT=0
ORCH_READY_SPAWN=0
ORCH_READY_CHECK=0
ORCH_READY_MERGE=1
ORCH_QUEUE_PENDING=0
ORCH_QUEUE_IN_PROGRESS=0
_orchestrate_refresh_scheduler_decision >/dev/null
assert_eq "orchestrator helper prioritizes merge" "merge" "$ORCH_SCHED_ACTION"

ORCH_READY_MERGE=0
ORCH_READY_CHECK=1
_orchestrate_refresh_scheduler_decision >/dev/null
assert_eq "orchestrator helper prioritizes check next" "check" "$ORCH_SCHED_ACTION"

ORCH_READY_CHECK=0
ORCH_STATE_DONE=0
ORCH_STATE_RUNNING=0
ORCH_STATE_PENDING=0
ORCH_STATE_MERGED=0
ORCH_STATE_FAILED=0
ORCH_STATE_CONFLICT=0
ORCH_STATE_NEEDS_INPUT=1
ORCH_STATE_TOTAL=1
_orchestrate_refresh_scheduler_decision >/dev/null
assert_eq "orchestrator helper marks blocked-only state" "blocked" "$ORCH_SCHED_ACTION"

printf '\n[4] Decision trace files\n'
scheduler_record_decision "autopilot" "merge" "merge-ready work exists"
assert_eq "autopilot decision action file written" "merge" "$(cat "$ORCHD_DIR/scheduler/autopilot.action")"
assert_eq "autopilot decision reason file written" "merge-ready work exists" "$(cat "$ORCHD_DIR/scheduler/autopilot.reason")"
scheduler_record_decision "orchestrate" "check" "completed worker sessions need checking"
mkdir -p "$ORCHD_DIR/orchestrator"
printf 'architect\n' >"$ORCHD_DIR/orchestrator/route_role"
printf 'claude\n' >"$ORCHD_DIR/orchestrator/selected_runner"
printf 'using preferred runner claude for role architect\n' >"$ORCHD_DIR/orchestrator/route_reason"
printf 'false\n' >"$ORCHD_DIR/orchestrator/route_fallback_used"
printf 'sticky\n' >"$ORCHD_DIR/orchestrator/session_mode"
printf 'CONTINUE\n' >"$ORCHD_DIR/orchestrator/last_result"
printf 'keep going\n' >"$ORCHD_DIR/orchestrator/last_reason"
printf 'reminder_sent\n' >"$ORCHD_DIR/orchestrator/last_idle_decision"
printf 'system reminder: state changed\n' >"$ORCHD_DIR/orchestrator/last_reminder_reason"
mkdir -p "$ORCHD_DIR/finish"
printf 'next_phase_available\n' >"$ORCHD_DIR/finish/state"
printf 'follow-on work exists\n' >"$ORCHD_DIR/finish/reason"
STATE_TELEMETRY_JSON=$(cd "$PROJECT_ROOT" && cmd_state --json)
STATE_TELEMETRY_RESULT=$(python -c 'import json, sys; data = json.load(sys.stdin); print("{}|{}|{}|{}".format(data["scheduler"]["last_action"], data["scheduler"]["orchestrate"]["action"], data["orchestrator"]["last_idle_decision"], data["finisher"]["state"]))' <<<"$STATE_TELEMETRY_JSON")
assert_eq "state json exposes scheduler/orchestrator/finisher telemetry" "check|check|reminder_sent|next_phase_available" "$STATE_TELEMETRY_RESULT"

printf '\n[5] Ready-task scoring order\n'
mkdir -p "$TASKS_DIR/score-fast" "$TASKS_DIR/score-risky" "$TASKS_DIR/score-heavy"
printf 'pending\n' >"$TASKS_DIR/score-fast/status"
printf 'pending\n' >"$TASKS_DIR/score-risky/status"
printf 'pending\n' >"$TASKS_DIR/score-heavy/status"
printf 'small\n' >"$TASKS_DIR/score-fast/size"
printf 'low\n' >"$TASKS_DIR/score-fast/risk"
printf 'smoke\n' >"$TASKS_DIR/score-fast/recommended_verification"

printf 'small\n' >"$TASKS_DIR/score-risky/size"
printf 'critical\n' >"$TASKS_DIR/score-risky/risk"
printf 'full\n' >"$TASKS_DIR/score-risky/recommended_verification"

printf 'large\n' >"$TASKS_DIR/score-heavy/size"
printf 'medium\n' >"$TASKS_DIR/score-heavy/risk"
printf 'targeted\n' >"$TASKS_DIR/score-heavy/recommended_verification"
printf 'api,ui,db\n' >"$TASKS_DIR/score-heavy/file_hints"

SORTED_READY=$(swarm_sort_ready_tasks score-heavy score-risky score-fast | paste -sd ',' -)
assert_eq "ready-task scoring prefers smaller safer cheaper work" "score-fast,score-heavy,score-risky" "$SORTED_READY"

SPAWN_ORDER_FILE="$TMP_SWARM_DIR/spawn-order.txt"
_spawn_single() {
	local task_id=$1
	local _runner=$2
	printf '%s\n' "$task_id" >>"$SPAWN_ORDER_FILE"
	return 0
}
_spawn_all_ready "codex" >/dev/null
assert_eq "spawn --all uses scored ready-task order" "score-fast,score-heavy,score-risky" "$(paste -sd ',' "$SPAWN_ORDER_FILE")"

printf '\n[6] Risk-aware merge gating\n'
mkdir -p "$TASKS_DIR/merge-low" "$TASKS_DIR/merge-high" "$TASKS_DIR/merge-review"
printf 'done\n' >"$TASKS_DIR/merge-low/status"
printf 'done\n' >"$TASKS_DIR/merge-high/status"
printf 'done\n' >"$TASKS_DIR/merge-review/status"
printf '2026-03-23T00:00:00Z\n' >"$TASKS_DIR/merge-low/checked_at"
printf '2026-03-23T00:00:00Z\n' >"$TASKS_DIR/merge-high/checked_at"
printf '2026-03-23T00:00:00Z\n' >"$TASKS_DIR/merge-review/checked_at"
printf 'low\n' >"$TASKS_DIR/merge-low/risk"
printf 'smoke\n' >"$TASKS_DIR/merge-low/verification_tier"
printf 'high\n' >"$TASKS_DIR/merge-high/risk"
printf 'targeted\n' >"$TASKS_DIR/merge-high/verification_tier"
printf 'high\n' >"$TASKS_DIR/merge-review/risk"
printf 'targeted\n' >"$TASKS_DIR/merge-review/verification_tier"
printf 'approved\n' >"$TASKS_DIR/merge-review/review_status"

if verify_merge_accepts_task "merge-low" >/dev/null; then
	pass "low-risk task passes merge gate with smoke verification"
else
	fail "low-risk task passes merge gate with smoke verification"
fi

if ! verify_merge_accepts_task "merge-high" >/dev/null; then
	pass "high-risk merge blocks without full verification"
else
	fail "high-risk merge blocks without full verification"
fi

if verify_merge_accepts_task "merge-review" >/dev/null; then
	pass "approved review can unblock risky merge policy"
else
	fail "approved review can unblock risky merge policy"
fi

task_prepare_new_attempt "merge-review"
assert_eq "new attempt clears stale review approval" "" "$(task_get "merge-review" "review_status" "")"
assert_eq "new attempt clears stale merge gate memo" "" "$(task_get "merge-review" "merge_gate_status" "")"
printf 'done\n' >"$TASKS_DIR/merge-review/status"
printf '2026-03-24T00:00:00Z\n' >"$TASKS_DIR/merge-review/checked_at"
printf 'high\n' >"$TASKS_DIR/merge-review/risk"
printf 'targeted\n' >"$TASKS_DIR/merge-review/verification_tier"
if ! verify_merge_accepts_task "merge-review" >/dev/null; then
	pass "stale review approval no longer satisfies later attempt"
else
	fail "stale review approval no longer satisfies later attempt"
fi

printf '\n[7] Failure classification and recovery policy\n'
mkdir -p "$TASKS_DIR/fail-test" "$TASKS_DIR/fail-flake" "$TASKS_DIR/fail-split"
printf 'failed\n' >"$TASKS_DIR/fail-test/status"
printf '2\n' >"$TASKS_DIR/fail-test/failure_streak"
printf '1\n' >"$TASKS_DIR/fail-test/attempts"
cat >"$TASKS_DIR/fail-test/check.txt" <<'EOF'
  [FAIL] tests failed
EOF
assert_eq "classifier detects test failures" "test_failure" "$(recovery_classify_failure "fail-test" "$TASKS_DIR/fail-test/check.txt")"
recovery_task_update_state "fail-test" "test_failure" "$TASKS_DIR/fail-test/check.txt"
assert_eq "repeated test failures escalate to alternate runner" "retry_alternate_runner" "$(task_get "fail-test" "recovery_policy" "")"

printf 'failed\n' >"$TASKS_DIR/fail-flake/status"
cat >"$TASKS_DIR/fail-flake/check.txt" <<'EOF'
  network timeout while contacting remote service
EOF
assert_eq "classifier detects infra flakes from transient text" "infra_flake" "$(recovery_classify_failure "fail-flake" "$TASKS_DIR/fail-flake/check.txt")"

printf 'failed\n' >"$TASKS_DIR/fail-split/status"
printf 'large\n' >"$TASKS_DIR/fail-split/size"
printf '2\n' >"$TASKS_DIR/fail-split/failure_streak"
printf '2\n' >"$TASKS_DIR/fail-split/attempts"
assert_eq "repeated large scope confusion triggers split policy" "replan_split" "$(recovery_policy_for_class "fail-split" "scope_confusion")"

detect_runner() {
	printf 'custom\n'
}

swarm_runner_is_available() {
	case "$1" in
	custom | codex)
		return 0
		;;
	esac
	return 1
}

printf 'retry_alternate_runner\n' >"$TASKS_DIR/fail-test/recovery_policy"
printf 'custom\n' >"$TASKS_DIR/fail-test/runner"
assert_eq "alternate recovery runner avoids the previous runner" "codex" "$(recovery_select_runner "fail-test" "custom" "custom")"
printf 'done\n' >"$TASKS_DIR/fail-test/status"
printf 'done\n' >"$TASKS_DIR/fail-flake/status"
printf 'done\n' >"$TASKS_DIR/fail-split/status"

printf '\n[7b] Automatic reviewer trigger for risky merge override\n'
_review_run() {
	local _target=${1:-}
	local task_id=$2
	local out_file
	out_file="$(task_dir "$task_id")/review_output.txt"
	printf 'REVIEW_STATUS: approved\n' >"$out_file"
	printf 'REVIEW_REASON: auto reviewer approved this diff\n' >>"$out_file"
	printf 'No issues found.\n' >>"$out_file"
	task_set "$task_id" "review_status" "approved"
	task_set "$task_id" "review_reason" "auto reviewer approved this diff"
	task_set "$task_id" "reviewed_at" "$(now_iso)"
	task_set "$task_id" "review_runner" "custom"
	task_set "$task_id" "review_output_file" "$out_file"
}
mkdir -p "$TASKS_DIR/merge-auto-review" "$TMP_SWARM_DIR/worktree-merge-auto-review"
printf 'done\n' >"$TASKS_DIR/merge-auto-review/status"
printf 'high\n' >"$TASKS_DIR/merge-auto-review/risk"
printf 'targeted\n' >"$TASKS_DIR/merge-auto-review/verification_tier"
printf '2026-03-24T00:00:00Z\n' >"$TASKS_DIR/merge-auto-review/checked_at"
printf '%s\n' "$TMP_SWARM_DIR/worktree-merge-auto-review" >"$TASKS_DIR/merge-auto-review/worktree"
if ! verify_merge_accepts_task "merge-auto-review" >/dev/null 2>&1; then
	pass "risky targeted task blocks before reviewer approval"
else
	fail "risky targeted task blocks before reviewer approval"
fi
if _review_run "" "merge-auto-review" >/dev/null 2>&1 && verify_merge_accepts_task "merge-auto-review" >/dev/null 2>&1; then
	pass "review helper approval unblocks risky targeted task for merge"
else
	fail "review helper approval unblocks risky targeted task for merge"
fi
assert_eq "auto review stores approval state" "approved" "$(task_get "merge-auto-review" "review_status" "")"
assert_eq "auto review stores reviewer reason" "auto reviewer approved this diff" "$(task_get "merge-auto-review" "review_reason" "")"

printf '\n[7c] Built-in review runners use task worktree cwd\n'
FAKE_CLAUDE="$TMP_SWARM_DIR/fake-claude.sh"
REVIEW_BUILTIN_WORKTREE="$TMP_SWARM_DIR/review-builtin-worktree"
REVIEW_BUILTIN_OUTPUT="$TMP_SWARM_DIR/review-builtin-output.txt"
REVIEW_BUILTIN_PWD_CAPTURE="$TMP_SWARM_DIR/review-builtin-pwd.txt"
mkdir -p "$REVIEW_BUILTIN_WORKTREE"
printf 'project-root\n' >"$PROJECT_ROOT/review_context.txt"
printf 'task-worktree\n' >"$REVIEW_BUILTIN_WORKTREE/review_context.txt"
cat >"$FAKE_CLAUDE" <<EOF
#!/usr/bin/env bash
set -euo pipefail
pwd >"$REVIEW_BUILTIN_PWD_CAPTURE"
cat review_context.txt
EOF
chmod +x "$FAKE_CLAUDE"
cat >>"$PROJECT_ROOT/.orchd.toml" <<EOF

claude_bin = "$FAKE_CLAUDE"
EOF
_review_run_prompt_to_file "claude" "prompt" "$REVIEW_BUILTIN_OUTPUT" "$REVIEW_BUILTIN_WORKTREE" "review-builtin" >/dev/null 2>&1
assert_eq "built-in review runner executes from task worktree" "$REVIEW_BUILTIN_WORKTREE" "$(cat "$REVIEW_BUILTIN_PWD_CAPTURE")"
assert_eq "built-in review runner reads files from task worktree" "task-worktree" "$(tr -d '\n' <"$REVIEW_BUILTIN_OUTPUT")"

printf '\n[7d] Non-failed resume keeps existing runner\n'
runner_exec() {
	local runner=$1
	local task_id=$2
	local _prompt=$3
	local _worktree=$4
	task_set "$task_id" "session" "stub-session-$task_id"
	printf '%s\n' "$runner" >"$TMP_SWARM_DIR/resume-runner-capture.txt"
	return 0
}
mkdir -p "$TASKS_DIR/resume-done" "$TMP_SWARM_DIR/resume-done-worktree"
printf 'done\n' >"$TASKS_DIR/resume-done/status"
printf '%s\n' "$TMP_SWARM_DIR/resume-done-worktree" >"$TASKS_DIR/resume-done/worktree"
printf 'custom\n' >"$TASKS_DIR/resume-done/runner"
printf 'builder\n' >"$TASKS_DIR/resume-done/routing_role"
printf 'custom\n' >"$TASKS_DIR/resume-done/routing_selected_runner"
printf 'custom\n' >"$TASKS_DIR/resume-done/routing_default_runner"
printf 'builder route\n' >"$TASKS_DIR/resume-done/routing_reason"
printf 'false\n' >"$TASKS_DIR/resume-done/routing_fallback_used"
printf 'custom\n' >"$TASKS_DIR/resume-done/routing_candidates"
cat >"$PROJECT_ROOT/.orchd.toml" <<'EOF'
custom_runner_cmd = "printf ok"

[swarm.roles]
recovery = ["codex"]
reviewer = ["custom"]
EOF
_resume_single "resume-done" "normal continuation" >/dev/null
assert_eq "normal resume keeps stored runner" "custom" "$(task_get "resume-done" "runner" "")"
assert_eq "normal resume launches stored runner" "custom" "$(cat "$TMP_SWARM_DIR/resume-runner-capture.txt")"
assert_eq "normal resume preserves non-recovery routing role" "builder" "$(task_get "resume-done" "routing_role" "")"

printf '\n[8] Append-safe replanning\n'
mkdir -p "$TASKS_DIR/base-task"
printf 'pending\n' >"$TASKS_DIR/base-task/status"
cat >"$TMP_SWARM_DIR/replan.txt" <<'EOF'
TASK: a
TITLE: Split part A
ROLE: builder
DEPS: none
DESCRIPTION: Part A
ACCEPTANCE: Done
TASK: b
TITLE: Split part B
ROLE: builder
DEPS: a
DESCRIPTION: Part B
ACCEPTANCE: Done
TASK: c
TITLE: Split part C
ROLE: builder
DEPS: base-task,b
DESCRIPTION: Part C
ACCEPTANCE: Done
EOF
if _parse_plan_output "$TMP_SWARM_DIR/replan.txt" true "split-" >/dev/null 2>&1; then
	pass "append plan preserves existing tasks"
else
	fail "append plan preserves existing tasks"
fi
assert_eq "existing task survives append parse" "pending" "$(task_status "base-task")"
assert_eq "append parse creates prefixed task ids" "pending" "$(task_status "split-a")"
assert_eq "append parse rewrites internal deps with prefix" "split-a" "$(task_get "split-b" "deps" "")"
assert_eq "append parse preserves external deps while rewriting internal ones" "base-task,split-b" "$(task_get "split-c" "deps" "")"

printf '\n[9] Automatic split replanning\n'
SPLIT_PLANNER="$TMP_SWARM_DIR/planner-split.sh"
cat >"$SPLIT_PLANNER" <<'EOF'
#!/usr/bin/env bash
cat <<'PLAN'
TASK: a
TITLE: Small slice A
ROLE: builder
DEPS: none
DESCRIPTION: First split task
ACCEPTANCE: done
TASK: b
TITLE: Small slice B
ROLE: builder
DEPS: a
DESCRIPTION: Second split task
ACCEPTANCE: done
PLAN
EOF
chmod +x "$SPLIT_PLANNER"
cat >>"$PROJECT_ROOT/.orchd.toml" <<EOF

[swarm.roles]
planner = ["custom"]

[runners.custom]
custom_runner_cmd = "$SPLIT_PLANNER"
EOF
mkdir -p "$TASKS_DIR/auto-split"
mkdir -p "$TASKS_DIR/dep-upstream" "$TASKS_DIR/downstream-after-split"
printf 'pending\n' >"$TASKS_DIR/dep-upstream/status"
printf 'pending\n' >"$TASKS_DIR/downstream-after-split/status"
printf 'auto-split\n' >"$TASKS_DIR/downstream-after-split/deps"
printf 'failed\n' >"$TASKS_DIR/auto-split/status"
printf 'Large failed task\n' >"$TASKS_DIR/auto-split/title"
printf 'Need task splitting\n' >"$TASKS_DIR/auto-split/description"
printf 'Ship the feature\n' >"$TASKS_DIR/auto-split/acceptance"
printf 'dep-upstream\n' >"$TASKS_DIR/auto-split/deps"
printf 'scope_confusion\n' >"$TASKS_DIR/auto-split/failure_class"
printf 'Task is too large\n' >"$TASKS_DIR/auto-split/failure_summary"
printf 'replan_split\n' >"$TASKS_DIR/auto-split/recovery_policy"
printf '0\n' >"$TASKS_DIR/auto-split/attempts"
printf '0\n' >"$TASKS_DIR/auto-split/last_retry_epoch"
(
	cd "$PROJECT_ROOT"
	_autopilot_retry_failed "custom" >/dev/null
)
assert_eq "auto split marks original task as split" "split" "$(task_status "auto-split")"
assert_eq "auto split stores generated children" "auto-split-a,auto-split-b" "$(task_get "auto-split" "split_children" "")"
assert_eq "auto split creates prefixed child task" "pending" "$(task_status "auto-split-a")"
assert_eq "auto split preserves original upstream deps on entry child" "dep-upstream" "$(task_get "auto-split-a" "deps" "")"
assert_eq "auto split keeps internal child deps after upstream preservation" "auto-split-a" "$(task_get "auto-split-b" "deps" "")"
assert_eq "auto split rewires downstream tasks to split leaf children" "auto-split-b" "$(task_get "downstream-after-split" "deps" "")"
if ! task_is_ready "auto-split-a"; then
	pass "auto split child waits for original upstream deps"
else
	fail "auto split child waits for original upstream deps"
fi
printf 'merged\n' >"$TASKS_DIR/dep-upstream/status"
if task_is_ready "auto-split-a"; then
	pass "auto split child becomes ready after upstream deps merge"
else
	fail "auto split child becomes ready after upstream deps merge"
fi

printf '\n[10] Split dependency deadlock diagnostics\n'
SPLIT_DEADLOCK_RESULT=$(
	PROJECT_ROOT="$TMP_SWARM_DIR/split-deadlock-project"
	ORCHD_DIR="$PROJECT_ROOT/.orchd"
	TASKS_DIR="$ORCHD_DIR/tasks"
	LOGS_DIR="$ORCHD_DIR/logs"
	mkdir -p "$PROJECT_ROOT" "$TASKS_DIR" "$LOGS_DIR"
	mkdir -p "$TASKS_DIR/split-parent" "$TASKS_DIR/downstream-stuck"
	printf 'split\n' >"$TASKS_DIR/split-parent/status"
	printf 'split-child-a,split-child-b\n' >"$TASKS_DIR/split-parent/split_children"
	printf 'pending\n' >"$TASKS_DIR/downstream-stuck/status"
	printf 'split-parent\n' >"$TASKS_DIR/downstream-stuck/deps"
	_autopilot_detect_deadlock >/dev/null
	printf '%s|%s|%s\n' \
		"$(task_status "downstream-stuck")" \
		"$(task_get "downstream-stuck" "needs_input_code" "")" \
		"$(task_get "downstream-stuck" "needs_input_options" "")"
)
assert_eq "split dependency deadlock marks task needs_input" "needs_input|split_dependency|split-child-a,split-child-b" "$SPLIT_DEADLOCK_RESULT"

printf '\n[11] Integrated swarm-finisher slice\n'
INTEGRATED_RESULT=$(
	SCENARIO_DIR="$TMP_SWARM_DIR/integrated"
	mkdir -p "$SCENARIO_DIR"
	git -C "$SCENARIO_DIR" init -q
	git -C "$SCENARIO_DIR" config user.name "orchd-test"
	git -C "$SCENARIO_DIR" config user.email "test@orchd.dev"
	git -C "$SCENARIO_DIR" commit --allow-empty -q -m init
	BASE_BRANCH=$(git -C "$SCENARIO_DIR" symbolic-ref --quiet --short HEAD)
	mkdir -p "$SCENARIO_DIR/.orchd/tasks" "$SCENARIO_DIR/.orchd/logs" "$SCENARIO_DIR/bin"
	cat >"$SCENARIO_DIR/.orchd.toml" <<EOF
[project]
base_branch = "$BASE_BRANCH"

[worker]
runner = "custom"

custom_runner_cmd = "printf ok"

[quality]
test_cmd = "true"

[swarm.roles]
reviewer = ["custom"]
recovery = ["custom", "codex"]

[runners.codex]
codex_bin = "$SCENARIO_DIR/bin/codex"
EOF
	cat >"$SCENARIO_DIR/bin/codex" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
	chmod +x "$SCENARIO_DIR/bin/codex"
	export PATH="$SCENARIO_DIR/bin:$PATH"
	PROJECT_ROOT="$SCENARIO_DIR"
	ORCHD_DIR="$SCENARIO_DIR/.orchd"
	TASKS_DIR="$ORCHD_DIR/tasks"
	LOGS_DIR="$ORCHD_DIR/logs"

	git -C "$SCENARIO_DIR" checkout -q -b agent-risky
	printf 'risky\n' >"$SCENARIO_DIR/risky.txt"
	git -C "$SCENARIO_DIR" add risky.txt
	git -C "$SCENARIO_DIR" commit -q -m "risky"
	git -C "$SCENARIO_DIR" checkout -q "$BASE_BRANCH"

	mkdir -p "$TASKS_DIR/risky-merge" "$TASKS_DIR/retry-task"
	printf 'done\n' >"$TASKS_DIR/risky-merge/status"
	printf 'agent-risky\n' >"$TASKS_DIR/risky-merge/branch"
	printf 'high\n' >"$TASKS_DIR/risky-merge/risk"
	printf 'targeted\n' >"$TASKS_DIR/risky-merge/verification_tier"
	printf '2026-03-24T00:00:00Z\n' >"$TASKS_DIR/risky-merge/checked_at"

	printf 'failed\n' >"$TASKS_DIR/retry-task/status"
	printf 'custom\n' >"$TASKS_DIR/retry-task/runner"
	printf 'test_failure\n' >"$TASKS_DIR/retry-task/failure_class"
	printf 'retry_alternate_runner\n' >"$TASKS_DIR/retry-task/recovery_policy"

	_review_run "" risky-merge >/dev/null
	_merge_single risky-merge >/dev/null
	finish_record_state "project_complete" "all scoped work appears complete"
	STATE_JSON=$(cd "$SCENARIO_DIR" && cmd_state --json)
	printf '%s|%s|%s|%s\n' \
		"$(task_status risky-merge)" \
		"$(task_get risky-merge review_status '')" \
		"$(recovery_select_runner retry-task custom custom)" \
		"$(python -c 'import json, sys; print(json.load(sys.stdin)["finisher"]["state"])' <<<"$STATE_JSON")"
)
assert_eq "integrated slice covers auto review, alternate runner, merge, and finisher state" "merged|approved|codex|project_complete" "$INTEGRATED_RESULT"

printf '\n=== Results: %d passed, %d failed, %d total ===\n' "$PASS" "$FAIL" "$TOTAL"

if ((FAIL > 0)); then
	exit 1
fi
