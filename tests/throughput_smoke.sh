#!/usr/bin/env bash
set -euo pipefail

resolve_path() {
	local target=$1
	if command -v realpath >/dev/null 2>&1; then
		realpath "$target"
	else
		local dir
		dir=$(dirname "$target")
		printf '%s/%s\n' "$(cd "$dir" && pwd -P)" "$(basename "$target")"
	fi
}

ORCHD="$(resolve_path "$(dirname "$0")/../bin/orchd")"
CORE_SH="$(resolve_path "$(dirname "$0")/../lib/core.sh")"

TMPDIR=$(mktemp -d)
cleanup() {
	rm -rf "$TMPDIR"
}
trap cleanup EXIT

git -C "$TMPDIR" init -q
git -C "$TMPDIR" config user.name "orchd-test"
git -C "$TMPDIR" config user.email "test@orchd.dev"
git -C "$TMPDIR" commit --allow-empty -m "init" -q

"$ORCHD" init "$TMPDIR" >/dev/null

mkdir -p "$TMPDIR/.orchd/tasks/t-metrics"
printf 'merged\n' >"$TMPDIR/.orchd/tasks/t-metrics/status"
printf 'metrics baseline\n' >"$TMPDIR/.orchd/tasks/t-metrics/title"
printf 'domain\n' >"$TMPDIR/.orchd/tasks/t-metrics/role"
printf 'none\n' >"$TMPDIR/.orchd/tasks/t-metrics/deps"

(
	cd "$TMPDIR"
	"$ORCHD" autopilot 1 >/dev/null
)

metrics_file="$TMPDIR/.orchd/metrics/events.jsonl"
if [[ ! -s "$metrics_file" ]]; then
	printf 'FAIL: expected non-empty metrics file at %s\n' "$metrics_file" >&2
	exit 1
fi

printf 'PASS: throughput smoke metrics emission\n'

# Cache primitive behavior (tick-scoped)
CACHE_REPO=$(mktemp -d)
git -C "$CACHE_REPO" init -q
git -C "$CACHE_REPO" config user.name "orchd-test"
git -C "$CACHE_REPO" config user.email "test@orchd.dev"
git -C "$CACHE_REPO" commit --allow-empty -m "init" -q

cat >"$CACHE_REPO/.orchd.toml" <<'EOF'
[project]
name = "cache-test"
description = "cache"
base_branch = "main"

[orchestrator]
max_parallel = 3
EOF

mkdir -p "$CACHE_REPO/.orchd/tasks/t1"
printf 'pending\n' >"$CACHE_REPO/.orchd/tasks/t1/status"

(
	cd "$CACHE_REPO"
	die() { return 1; }
	# shellcheck disable=SC1090
	source "$CORE_SH"
	PROJECT_ROOT="$CACHE_REPO"
	ORCHD_DIR="$CACHE_REPO/.orchd"
	TASKS_DIR="$ORCHD_DIR/tasks"
	LOGS_DIR="$ORCHD_DIR/logs"

	cache_tick_begin
	config_get_cached "max_parallel" "0" >/dev/null
	v1=$REPLY
	cat >"$CACHE_REPO/.orchd.toml" <<'EOF2'
[project]
name = "cache-test"
description = "cache"
base_branch = "main"

[orchestrator]
max_parallel = 9
EOF2
	config_get_cached "max_parallel" "0" >/dev/null
	v2=$REPLY
	cache_tick_end
	config_get_cached "max_parallel" "0" >/dev/null
	v3=$REPLY

	[[ "$v1" == "3" ]]
	[[ "$v2" == "3" ]]
	[[ "$v3" == "9" ]]
)

rm -rf "$CACHE_REPO"
printf 'PASS: throughput smoke cache primitives\n'

# State JSON runner liveness checks should be single-pass
STATE_REPO=$(mktemp -d)
git -C "$STATE_REPO" init -q
git -C "$STATE_REPO" config user.name "orchd-test"
git -C "$STATE_REPO" config user.email "test@orchd.dev"
git -C "$STATE_REPO" commit --allow-empty -m "init" -q

"$ORCHD" init "$STATE_REPO" >/dev/null
mkdir -p "$STATE_REPO/.orchd/tasks/t-running"
printf 'running\n' >"$STATE_REPO/.orchd/tasks/t-running/status"
printf 'running task\n' >"$STATE_REPO/.orchd/tasks/t-running/title"
printf 'domain\n' >"$STATE_REPO/.orchd/tasks/t-running/role"
printf 'none\n' >"$STATE_REPO/.orchd/tasks/t-running/deps"
printf 'codex\n' >"$STATE_REPO/.orchd/tasks/t-running/runner"
printf 'tmux-session-1\n' >"$STATE_REPO/.orchd/tasks/t-running/session"

FAKE_BIN="$STATE_REPO/fakebin"
mkdir -p "$FAKE_BIN"
cat >"$FAKE_BIN/tmux" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "has-session" ]]; then
  count_file=${TMUX_CALL_COUNT_FILE:?}
  count=0
  if [[ -f "$count_file" ]]; then
    count=$(cat "$count_file")
  fi
  count=$((count + 1))
  printf '%s\n' "$count" >"$count_file"
  exit 1
fi
exit 0
EOF
chmod +x "$FAKE_BIN/tmux"

COUNT_FILE="$STATE_REPO/tmux-count.txt"
printf '0\n' >"$COUNT_FILE"
(
	cd "$STATE_REPO"
	PATH="$FAKE_BIN:$PATH" TMUX_CALL_COUNT_FILE="$COUNT_FILE" "$ORCHD" state --json >/dev/null
)

tmux_calls=$(cat "$COUNT_FILE")
if [[ "$tmux_calls" != "1" ]]; then
	printf 'FAIL: expected one tmux has-session call in state --json, got %s\n' "$tmux_calls" >&2
	exit 1
fi

rm -rf "$STATE_REPO"
printf 'PASS: throughput smoke single-pass state liveness checks\n'

# Ready queue prioritization should prefer high-throughput tasks
SCORE_REPO=$(mktemp -d)
git -C "$SCORE_REPO" init -q
git -C "$SCORE_REPO" config user.name "orchd-test"
git -C "$SCORE_REPO" config user.email "test@orchd.dev"
git -C "$SCORE_REPO" commit --allow-empty -m "init" -q

"$ORCHD" init "$SCORE_REPO" >/dev/null

tmp_cfg=$(mktemp)
awk '
  /^[[:space:]]*max_parallel[[:space:]]*=/ { print "max_parallel = 1"; next }
  /^[[:space:]]*runner[[:space:]]*=/ { print "runner = \"custom\""; next }
  { print }
' "$SCORE_REPO/.orchd.toml" >"$tmp_cfg"
mv "$tmp_cfg" "$SCORE_REPO/.orchd.toml"
printf '\ncustom_runner_cmd = "true"\n' >>"$SCORE_REPO/.orchd.toml"

mkdir -p "$SCORE_REPO/.orchd/tasks/a-big"
printf 'pending\n' >"$SCORE_REPO/.orchd/tasks/a-big/status"
printf 'big task\n' >"$SCORE_REPO/.orchd/tasks/a-big/title"
printf 'domain\n' >"$SCORE_REPO/.orchd/tasks/a-big/role"
: >"$SCORE_REPO/.orchd/tasks/a-big/deps"
printf 'l\n' >"$SCORE_REPO/.orchd/tasks/a-big/size"
printf 'high\n' >"$SCORE_REPO/.orchd/tasks/a-big/risk"

mkdir -p "$SCORE_REPO/.orchd/tasks/z-small"
printf 'pending\n' >"$SCORE_REPO/.orchd/tasks/z-small/status"
printf 'small task\n' >"$SCORE_REPO/.orchd/tasks/z-small/title"
printf 'domain\n' >"$SCORE_REPO/.orchd/tasks/z-small/role"
: >"$SCORE_REPO/.orchd/tasks/z-small/deps"
printf 's\n' >"$SCORE_REPO/.orchd/tasks/z-small/size"
printf 'low\n' >"$SCORE_REPO/.orchd/tasks/z-small/risk"

(
	cd "$SCORE_REPO"
	"$ORCHD" spawn --all >/dev/null
)

status_big=$(cat "$SCORE_REPO/.orchd/tasks/a-big/status")
status_small=$(cat "$SCORE_REPO/.orchd/tasks/z-small/status")

if [[ "$status_small" != "running" ]] || [[ "$status_big" != "pending" ]]; then
	printf 'FAIL: expected z-small to be spawned before a-big (got a-big=%s z-small=%s)\n' "$status_big" "$status_small" >&2
	exit 1
fi

rm -rf "$SCORE_REPO"
printf 'PASS: throughput smoke ready-queue prioritization\n'

# Throughput mode off should disable priority scoring
SCORE_OFF_REPO=$(mktemp -d)
git -C "$SCORE_OFF_REPO" init -q
git -C "$SCORE_OFF_REPO" config user.name "orchd-test"
git -C "$SCORE_OFF_REPO" config user.email "test@orchd.dev"
git -C "$SCORE_OFF_REPO" commit --allow-empty -m "init" -q

"$ORCHD" init "$SCORE_OFF_REPO" >/dev/null

tmp_cfg=$(mktemp)
awk '
  /^[[:space:]]*max_parallel[[:space:]]*=/ { print "max_parallel = 1"; next }
  /^[[:space:]]*throughput_mode[[:space:]]*=/ { print "throughput_mode = \"off\""; next }
  /^[[:space:]]*runner[[:space:]]*=/ { print "runner = \"custom\""; next }
  { print }
' "$SCORE_OFF_REPO/.orchd.toml" >"$tmp_cfg"
mv "$tmp_cfg" "$SCORE_OFF_REPO/.orchd.toml"
printf '\ncustom_runner_cmd = "true"\n' >>"$SCORE_OFF_REPO/.orchd.toml"

mkdir -p "$SCORE_OFF_REPO/.orchd/tasks/a-big"
printf 'pending\n' >"$SCORE_OFF_REPO/.orchd/tasks/a-big/status"
printf 'big task\n' >"$SCORE_OFF_REPO/.orchd/tasks/a-big/title"
printf 'domain\n' >"$SCORE_OFF_REPO/.orchd/tasks/a-big/role"
: >"$SCORE_OFF_REPO/.orchd/tasks/a-big/deps"
printf 'l\n' >"$SCORE_OFF_REPO/.orchd/tasks/a-big/size"
printf 'high\n' >"$SCORE_OFF_REPO/.orchd/tasks/a-big/risk"

mkdir -p "$SCORE_OFF_REPO/.orchd/tasks/z-small"
printf 'pending\n' >"$SCORE_OFF_REPO/.orchd/tasks/z-small/status"
printf 'small task\n' >"$SCORE_OFF_REPO/.orchd/tasks/z-small/title"
printf 'domain\n' >"$SCORE_OFF_REPO/.orchd/tasks/z-small/role"
: >"$SCORE_OFF_REPO/.orchd/tasks/z-small/deps"
printf 's\n' >"$SCORE_OFF_REPO/.orchd/tasks/z-small/size"
printf 'low\n' >"$SCORE_OFF_REPO/.orchd/tasks/z-small/risk"

(
	cd "$SCORE_OFF_REPO"
	"$ORCHD" spawn --all >/dev/null
)

status_big=$(cat "$SCORE_OFF_REPO/.orchd/tasks/a-big/status")
status_small=$(cat "$SCORE_OFF_REPO/.orchd/tasks/z-small/status")

if [[ "$status_big" != "running" ]] || [[ "$status_small" != "pending" ]]; then
	printf 'FAIL: expected throughput_mode=off to spawn a-big first (got a-big=%s z-small=%s)\n' "$status_big" "$status_small" >&2
	exit 1
fi

rm -rf "$SCORE_OFF_REPO"
printf 'PASS: throughput smoke throughput_mode off\n'

# Adaptive parallelism helper should downshift under failures/conflicts
ADAPT_REPO=$(mktemp -d)
git -C "$ADAPT_REPO" init -q
git -C "$ADAPT_REPO" config user.name "orchd-test"
git -C "$ADAPT_REPO" config user.email "test@orchd.dev"
git -C "$ADAPT_REPO" commit --allow-empty -m "init" -q

"$ORCHD" init "$ADAPT_REPO" >/dev/null

AUTOPILOT_SH="$(resolve_path "$(dirname "$0")/../lib/cmd/autopilot.sh")"
CHECK_SH="$(resolve_path "$(dirname "$0")/../lib/cmd/check.sh")"
(
	cd "$ADAPT_REPO"
	die() { return 1; }
	# shellcheck disable=SC1090
	source "$CORE_SH"
	# shellcheck disable=SC1090
	source "$AUTOPILOT_SH"

	v1=$(_autopilot_effective_parallel 4 0 0 1)
	v2=$(_autopilot_effective_parallel 4 2 0 1)
	v3=$(_autopilot_effective_parallel 4 0 3 2)

	[[ "$v1" == "4" ]]
	[[ "$v2" == "3" ]]
	[[ "$v3" == "3" ]]
)

rm -rf "$ADAPT_REPO"
printf 'PASS: throughput smoke adaptive parallelism helper\n'

# Quality profile helpers
PROFILE_REPO=$(mktemp -d)
git -C "$PROFILE_REPO" init -q
git -C "$PROFILE_REPO" config user.name "orchd-test"
git -C "$PROFILE_REPO" config user.email "test@orchd.dev"
git -C "$PROFILE_REPO" commit --allow-empty -m "init" -q

"$ORCHD" init "$PROFILE_REPO" >/dev/null
(
	cd "$PROFILE_REPO"
	die() { return 1; }
	# shellcheck disable=SC1090
	source "$CORE_SH"
	# shellcheck disable=SC1090
	source "$CHECK_SH"

	v1=$(_quality_profile_resolve "")
	v2=$(_quality_profile_resolve "quick")
	v3=$(_quality_profile_resolve "UNKNOWN")
	[[ "$v1" == "standard" ]]
	[[ "$v2" == "quick" ]]
	[[ "$v3" == "standard" ]]

	_quality_profile_apply "quick" "lint-cmd" "test-cmd" "build-cmd"
	[[ "$ORCHD_PROFILE_LINT_CMD" == "lint-cmd" ]]
	[[ "$ORCHD_PROFILE_TEST_CMD" == "test-cmd" ]]
	[[ -z "$ORCHD_PROFILE_BUILD_CMD" ]]

	_quality_profile_apply "strict" "lint-cmd" "" ""
	[[ "$ORCHD_PROFILE_REQUIRE_FULL" == "1" ]]
	missing=$(_quality_profile_missing_count "$ORCHD_PROFILE_LINT_CMD" "$ORCHD_PROFILE_TEST_CMD" "$ORCHD_PROFILE_BUILD_CMD")
	[[ "$missing" == "2" ]]
)

rm -rf "$PROFILE_REPO"
printf 'PASS: throughput smoke quality profile helpers\n'

# Retry policy matrix and classification actions
POLICY_REPO=$(mktemp -d)
git -C "$POLICY_REPO" init -q
git -C "$POLICY_REPO" config user.name "orchd-test"
git -C "$POLICY_REPO" config user.email "test@orchd.dev"
git -C "$POLICY_REPO" commit --allow-empty -m "init" -q

"$ORCHD" init "$POLICY_REPO" >/dev/null
cat >>"$POLICY_REPO/.orchd.toml" <<'EOF'
autopilot_retry_limit_infra = 2
autopilot_retry_backoff_infra = 0
autopilot_retry_limit_quality = 1
autopilot_retry_backoff_quality = 0
EOF

for tid in infra needs conflict quality quality2; do
	mkdir -p "$POLICY_REPO/.orchd/tasks/t-$tid"
	printf 'failed\n' >"$POLICY_REPO/.orchd/tasks/t-$tid/status"
	wt="$POLICY_REPO/wt-$tid"
	mkdir -p "$wt"
	printf '%s\n' "$wt" >"$POLICY_REPO/.orchd/tasks/t-$tid/worktree"
done

printf 'infra_flake\n' >"$POLICY_REPO/.orchd/tasks/t-infra/failure_class"
printf 'needs_input\n' >"$POLICY_REPO/.orchd/tasks/t-needs/failure_class"
printf 'merge_conflict\n' >"$POLICY_REPO/.orchd/tasks/t-conflict/failure_class"
printf 'lint_failure\n' >"$POLICY_REPO/.orchd/tasks/t-quality/failure_class"
printf '1\n' >"$POLICY_REPO/.orchd/tasks/t-quality/attempts"
printf 'lint_failure\n' >"$POLICY_REPO/.orchd/tasks/t-quality2/failure_class"

RESUME_LOG="$POLICY_REPO/resume.log"
(
	cd "$POLICY_REPO"
	die() { return 1; }
	# shellcheck disable=SC1090
	source "$CORE_SH"
	# shellcheck disable=SC1090
	source "$AUTOPILOT_SH"

	PROJECT_ROOT="$POLICY_REPO"
	ORCHD_DIR="$POLICY_REPO/.orchd"
	TASKS_DIR="$ORCHD_DIR/tasks"
	LOGS_DIR="$ORCHD_DIR/logs"

	_resume_single() {
		printf '%s\n' "$1" >>"$RESUME_LOG"
		return 0
	}

	cache_tick_begin
	_autopilot_retry_failed "codex"
)

grep -q '^t-infra$' "$RESUME_LOG"
grep -q '^t-quality2$' "$RESUME_LOG"
! grep -q '^t-quality$' "$RESUME_LOG"

[[ "$(cat "$POLICY_REPO/.orchd/tasks/t-needs/status")" == "needs_input" ]]
[[ "$(cat "$POLICY_REPO/.orchd/tasks/t-conflict/status")" == "conflict" ]]
[[ "$(cat "$POLICY_REPO/.orchd/tasks/t-quality/status")" == "needs_input" ]]

rm -rf "$POLICY_REPO"
printf 'PASS: throughput smoke retry policy matrix\n'

# KPI computation should use metrics events
KPI_REPO=$(mktemp -d)
git -C "$KPI_REPO" init -q
git -C "$KPI_REPO" config user.name "orchd-test"
git -C "$KPI_REPO" config user.email "test@orchd.dev"
git -C "$KPI_REPO" commit --allow-empty -m "init" -q

"$ORCHD" init "$KPI_REPO" >/dev/null
mkdir -p "$KPI_REPO/.orchd/metrics"

now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
spawn_t1=$(date -u -d '-120 seconds' +%Y-%m-%dT%H:%M:%SZ)
spawn_t2=$(date -u -d '-60 seconds' +%Y-%m-%dT%H:%M:%SZ)

cat >"$KPI_REPO/.orchd/metrics/events.jsonl" <<EOF
{"ts":"$spawn_t1","event":"spawn.started","task_id":"t1","status":"running","duration_ms":0,"details":{}}
{"ts":"$now","event":"check.completed","task_id":"t1","status":"done","duration_ms":0,"details":{}}
{"ts":"$now","event":"merge.completed","task_id":"t1","status":"merged","duration_ms":0,"details":{}}
{"ts":"$spawn_t2","event":"spawn.started","task_id":"t2","status":"running","duration_ms":0,"details":{}}
{"ts":"$now","event":"check.completed","task_id":"t2","status":"failed","duration_ms":0,"details":{}}
{"ts":"$now","event":"check.completed","task_id":"t2","status":"done","duration_ms":0,"details":{}}
EOF

KPI_JSON=$(cd "$KPI_REPO" && "$ORCHD" state --json)

if ! printf '%s' "$KPI_JSON" | grep -q '"merged_tasks_per_day":1'; then
	printf 'FAIL: expected merged_tasks_per_day=1 in KPI\n' >&2
	exit 1
fi
if ! printf '%s' "$KPI_JSON" | grep -q '"cycle_time_p50_seconds":120'; then
	printf 'FAIL: expected cycle_time_p50_seconds=120 in KPI\n' >&2
	exit 1
fi
if ! printf '%s' "$KPI_JSON" | grep -q '"cycle_time_p90_seconds":120'; then
	printf 'FAIL: expected cycle_time_p90_seconds=120 in KPI\n' >&2
	exit 1
fi
if ! printf '%s' "$KPI_JSON" | grep -q '"first_pass_check_success_rate":50'; then
	printf 'FAIL: expected first_pass_check_success_rate=50 in KPI\n' >&2
	exit 1
fi

rm -rf "$KPI_REPO"
printf 'PASS: throughput smoke KPI computation\n'
