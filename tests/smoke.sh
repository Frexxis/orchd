#!/usr/bin/env bash
# smoke.sh - Basic smoke tests for orchd
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
PASS=0
FAIL=0
TOTAL=0

# Isolate monitor state from the user's home directory.
ORCHD_TEST_STATE_DIR=$(mktemp -d)
export ORCHD_STATE_DIR="$ORCHD_TEST_STATE_DIR"
trap 'rm -rf "$ORCHD_TEST_STATE_DIR"' EXIT

# --- Helpers ---

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

assert_exit_0() {
	local desc=$1
	shift
	if "$@" >/dev/null 2>&1; then
		pass "$desc"
	else
		fail "$desc (exit $?)"
	fi
}

assert_exit_nonzero() {
	local desc=$1
	shift
	if "$@" >/dev/null 2>&1; then
		fail "$desc (expected nonzero, got 0)"
	else
		pass "$desc"
	fi
}

assert_output_contains() {
	local desc=$1
	shift
	local pattern=$1
	shift
	local output
	output=$("$@" 2>&1) || true
	if printf '%s' "$output" | grep -q "$pattern"; then
		pass "$desc"
	else
		fail "$desc (pattern '$pattern' not found in output)"
	fi
}

run_in_dir() {
	local dir=$1
	shift
	(cd "$dir" && "$@")
}

set_test_cmd() {
	local cfg=$1
	local cmd=$2
	local tmp
	tmp=$(mktemp)
	awk -v cmd="$cmd" '
		/^[[:space:]]*test_cmd[[:space:]]*=/ {
			print "test_cmd = \"" cmd "\""
			next
		}
		{ print }
	' "$cfg" >"$tmp"
	mv "$tmp" "$cfg"
}

assert_task_status() {
	local desc=$1
	local repo_dir=$2
	local task_id=$3
	local expected=$4
	local file="$repo_dir/.orchd/tasks/$task_id/status"

	if [[ ! -f "$file" ]]; then
		fail "$desc (missing $file)"
		return
	fi

	local actual
	actual=$(<"$file")
	if [[ "$actual" == "$expected" ]]; then
		pass "$desc"
	else
		fail "$desc (expected '$expected', got '$actual')"
	fi
}

get_base_branch() {
	local repo_dir=$1
	local cfg="$repo_dir/.orchd.toml"
	awk -F '=' '
		/^[[:space:]]*base_branch[[:space:]]*=/ {
			val = $2
			gsub(/^[[:space:]]*"?|"?[[:space:]]*$/, "", val)
			print val
			exit
		}
	' "$cfg"
}

cleanup() {
	# Stop any test sessions
	tmux kill-session -t "orchd-smoketest" 2>/dev/null || true
	# Remove temp repo
	if [[ -n "${TMPDIR:-}" && -d "$TMPDIR" ]]; then
		rm -rf "$TMPDIR"
	fi
	# Remove test state
	rm -rf "${HOME}/.orchd/orchd-smoketest"
	# Remove init test dir
	if [[ -n "${INIT_DIR:-}" && -d "$INIT_DIR" ]]; then
		rm -rf "$INIT_DIR"
	fi
}

trap cleanup EXIT

# --- Setup ---

printf '=== orchd smoke tests ===\n\n'

# Check dependencies first
for dep in git tmux; do
	if ! command -v "$dep" >/dev/null 2>&1; then
		printf 'SKIP: %s not installed\n' "$dep"
		exit 0
	fi
done

# Create a temporary git repo
TMPDIR=$(mktemp -d)
git -C "$TMPDIR" init -q
git -C "$TMPDIR" config user.name "orchd-test"
git -C "$TMPDIR" config user.email "test@orchd.dev"
git -C "$TMPDIR" commit --allow-empty -m "init" -q

# --- Tests ---

printf '[1] Help and usage\n'
assert_exit_0 "orchd --help exits 0" "$ORCHD" --help
assert_exit_0 "orchd help exits 0" "$ORCHD" help
assert_exit_0 "orchd (no args) exits 0" "$ORCHD"
assert_output_contains "help output contains orchd" "orchestrator" "$ORCHD" --help

printf '\n[2] Input validation\n'
assert_exit_nonzero "start with bad dir fails" "$ORCHD" start /nonexistent/path
assert_exit_nonzero "start with bad interval fails" "$ORCHD" start "$TMPDIR" abc
assert_exit_nonzero "attach without session fails" "$ORCHD" attach
assert_exit_nonzero "stop without session fails" "$ORCHD" stop
assert_exit_nonzero "status without session fails" "$ORCHD" status
assert_exit_nonzero "unknown command fails" "$ORCHD" foobar
assert_exit_0 "spawn --help exits 0" "$ORCHD" spawn --help

printf '\n[3] List (no sessions)\n'
assert_exit_0 "list exits 0" "$ORCHD" list

printf '\n[4] Start / list / status / stop lifecycle\n'
export ORCHD_SESSION="orchd-smoketest"

assert_exit_0 "start succeeds" "$ORCHD" start "$TMPDIR" 60
sleep 1

# Verify session is listed
assert_output_contains "list shows session" "orchd-smoketest" "$ORCHD" list

# Verify status works
assert_output_contains "status shows running" "running" "$ORCHD" status orchd-smoketest

# Stop it
assert_exit_0 "stop succeeds" "$ORCHD" stop orchd-smoketest
sleep 1

# Verify it's gone
assert_exit_nonzero "status after stop fails" "$ORCHD" status orchd-smoketest

printf '\n[5] Double-start prevention\n'
export ORCHD_SESSION="orchd-smoketest"
assert_exit_0 "start for double-test" "$ORCHD" start "$TMPDIR" 60
sleep 1
assert_exit_nonzero "double start is rejected" "$ORCHD" start "$TMPDIR" 60
"$ORCHD" stop orchd-smoketest >/dev/null 2>&1 || true

printf '\n[6] Init command\n'
INIT_DIR=$(mktemp -d)
git -C "$INIT_DIR" init -q
git -C "$INIT_DIR" config user.name "orchd-test"
git -C "$INIT_DIR" config user.email "test@orchd.dev"
git -C "$INIT_DIR" commit --allow-empty -m "init" -q

assert_exit_0 "init succeeds" "$ORCHD" init "$INIT_DIR"
assert_exit_nonzero "double init is rejected" "$ORCHD" init "$INIT_DIR"
BASE_BRANCH=$(get_base_branch "$INIT_DIR")
if [[ -z "$BASE_BRANCH" ]]; then
	BASE_BRANCH="main"
fi

# Verify files were created
if [[ -f "$INIT_DIR/.orchd.toml" ]]; then
	pass "config file created"
else
	fail "config file not created"
fi

if [[ -d "$INIT_DIR/.orchd/tasks" ]]; then
	pass "state directory created"
else
	fail "state directory not created"
fi

if [[ -f "$INIT_DIR/.gitignore" ]] && grep -q '.orchd/' "$INIT_DIR/.gitignore"; then
	pass ".gitignore updated"
else
	fail ".gitignore not updated"
fi

if [[ -f "$INIT_DIR/AGENTS.md" ]]; then
	pass "AGENTS.md created"
else
	fail "AGENTS.md not created"
fi

if [[ -f "$INIT_DIR/ORCHESTRATOR.md" ]]; then
	pass "ORCHESTRATOR.md created"
else
	fail "ORCHESTRATOR.md not created"
fi

if [[ -f "$INIT_DIR/WORKER.md" ]]; then
	pass "WORKER.md created"
else
	fail "WORKER.md not created"
fi

if [[ -f "$INIT_DIR/CLAUDE.md" ]]; then
	pass "CLAUDE.md created"
else
	fail "CLAUDE.md not created"
fi

if [[ -f "$INIT_DIR/OPENCODE.md" ]]; then
	pass "OPENCODE.md created"
else
	fail "OPENCODE.md not created"
fi

if [[ -f "$INIT_DIR/orchestrator-runbook.md" ]]; then
	pass "orchestrator-runbook.md created"
else
	fail "orchestrator-runbook.md not created"
fi

printf '\n[6b] Plan import parses quality overrides\n'
run_in_dir "$INIT_DIR" bash -c 'cat > .orchd/plan_in.txt <<"EOF"
TASK: t1
TITLE: Test overrides
ROLE: domain
DEPS: none
DESCRIPTION: do a thing
ACCEPTANCE: done
TEST_CMD: echo test
LINT_CMD: echo lint
BUILD_CMD: none
EOF'
assert_exit_0 "plan --file succeeds" run_in_dir "$INIT_DIR" "$ORCHD" plan --file .orchd/plan_in.txt
assert_output_contains "task test_cmd stored" "echo test" cat "$INIT_DIR/.orchd/tasks/t1/test_cmd"
assert_output_contains "task lint_cmd stored" "echo lint" cat "$INIT_DIR/.orchd/tasks/t1/lint_cmd"
# Cleanup so later autopilot tests see only the tasks they create.
rm -rf "$INIT_DIR/.orchd/tasks/t1" "$INIT_DIR/.orchd/plan_in.txt"

printf '\n[7] Orchestration commands (no-project validation)\n'
# These should fail gracefully when not in an orchd project
assert_exit_nonzero "plan without project fails" "$ORCHD" plan "test"
assert_exit_nonzero "spawn without project fails" "$ORCHD" spawn --all
assert_exit_nonzero "check without project fails" "$ORCHD" check --all
assert_exit_nonzero "merge without project fails" "$ORCHD" merge --all
assert_exit_nonzero "resume without project fails" "$ORCHD" resume foo

printf '\n[8] Board command (in initialized project)\n'
# Board should work in an initialized project (shows empty board)
assert_exit_0 "board in init dir" run_in_dir "$INIT_DIR" "$ORCHD" board

printf '\n[9] Utility commands (in initialized project)\n'
assert_exit_0 "doctor in init dir" run_in_dir "$INIT_DIR" "$ORCHD" doctor
assert_exit_0 "refresh-docs in init dir" run_in_dir "$INIT_DIR" "$ORCHD" refresh-docs

printf '\n[10] Help includes orchestration commands\n'
assert_output_contains "help shows init" "init" "$ORCHD" --help
assert_output_contains "help shows plan" "plan" "$ORCHD" --help
assert_output_contains "help shows review" "review" "$ORCHD" --help
assert_output_contains "help shows spawn" "spawn" "$ORCHD" --help
assert_output_contains "help shows board" "board" "$ORCHD" --help
assert_output_contains "help shows state" "state" "$ORCHD" --help
assert_output_contains "help shows await" "await" "$ORCHD" --help
assert_output_contains "help shows check" "check" "$ORCHD" --help
assert_output_contains "help shows merge" "merge" "$ORCHD" --help
assert_output_contains "help shows resume" "resume" "$ORCHD" --help
assert_output_contains "help shows autopilot" "autopilot" "$ORCHD" --help
assert_output_contains "help shows doctor" "doctor" "$ORCHD" --help
assert_output_contains "help shows refresh-docs" "refresh-docs" "$ORCHD" --help

printf '\n[11] Merge checks out base branch before merge\n'
run_in_dir "$INIT_DIR" git checkout -q -b "agent-merge-base-safety"
printf 'merge-base-safety\n' >"$INIT_DIR/merge_base_safety.txt"
run_in_dir "$INIT_DIR" git add "merge_base_safety.txt"
run_in_dir "$INIT_DIR" git commit -q -m "test: merge base safety"

mkdir -p "$INIT_DIR/.orchd/tasks/merge-base-safety"
printf 'done\n' >"$INIT_DIR/.orchd/tasks/merge-base-safety/status"
printf 'agent-merge-base-safety\n' >"$INIT_DIR/.orchd/tasks/merge-base-safety/branch"

assert_exit_0 "merge single succeeds from non-base HEAD" run_in_dir "$INIT_DIR" "$ORCHD" merge "merge-base-safety"

current_branch=$(run_in_dir "$INIT_DIR" git rev-parse --abbrev-ref HEAD)
if [[ "$current_branch" == "$BASE_BRANCH" ]]; then
	pass "merge leaves repository on base branch"
else
	fail "merge leaves repository on base branch (expected '$BASE_BRANCH', got '$current_branch')"
fi
assert_task_status "merged task marked as merged" "$INIT_DIR" "merge-base-safety" "merged"

printf '\n[12] Autopilot merges done tasks\n'
run_in_dir "$INIT_DIR" git checkout -q "$BASE_BRANCH"
run_in_dir "$INIT_DIR" git checkout -q -b "agent-autopilot-merge"
printf 'autopilot-merge\n' >"$INIT_DIR/autopilot_merge.txt"
run_in_dir "$INIT_DIR" git add "autopilot_merge.txt"
run_in_dir "$INIT_DIR" git commit -q -m "test: autopilot merge"
run_in_dir "$INIT_DIR" git checkout -q "$BASE_BRANCH"

mkdir -p "$INIT_DIR/.orchd/tasks/autopilot-merge"
printf 'done\n' >"$INIT_DIR/.orchd/tasks/autopilot-merge/status"
printf 'agent-autopilot-merge\n' >"$INIT_DIR/.orchd/tasks/autopilot-merge/branch"

assert_exit_0 "autopilot merges done task" run_in_dir "$INIT_DIR" "$ORCHD" autopilot 0
assert_task_status "autopilot task marked as merged" "$INIT_DIR" "autopilot-merge" "merged"

printf '\n[13] Merge --all stops after post-merge test failure\n'
set_test_cmd "$INIT_DIR/.orchd.toml" "false"

run_in_dir "$INIT_DIR" git checkout -q "$BASE_BRANCH"
run_in_dir "$INIT_DIR" git checkout -q -b "agent-a-fail-stop"
printf 'a-fail-stop\n' >"$INIT_DIR/a_fail_stop.txt"
run_in_dir "$INIT_DIR" git add "a_fail_stop.txt"
run_in_dir "$INIT_DIR" git commit -q -m "test: fail stop A"

run_in_dir "$INIT_DIR" git checkout -q "$BASE_BRANCH"
run_in_dir "$INIT_DIR" git checkout -q -b "agent-z-fail-stop"
printf 'z-fail-stop\n' >"$INIT_DIR/z_fail_stop.txt"
run_in_dir "$INIT_DIR" git add "z_fail_stop.txt"
run_in_dir "$INIT_DIR" git commit -q -m "test: fail stop Z"
run_in_dir "$INIT_DIR" git checkout -q "$BASE_BRANCH"

mkdir -p "$INIT_DIR/.orchd/tasks/a-fail-stop" "$INIT_DIR/.orchd/tasks/z-fail-stop"
printf 'done\n' >"$INIT_DIR/.orchd/tasks/a-fail-stop/status"
printf 'agent-a-fail-stop\n' >"$INIT_DIR/.orchd/tasks/a-fail-stop/branch"
printf 'done\n' >"$INIT_DIR/.orchd/tasks/z-fail-stop/status"
printf 'agent-z-fail-stop\n' >"$INIT_DIR/.orchd/tasks/z-fail-stop/branch"

assert_exit_nonzero "merge --all fails when post-merge tests fail" run_in_dir "$INIT_DIR" "$ORCHD" merge --all
assert_task_status "first failing task marked failed" "$INIT_DIR" "a-fail-stop" "failed"
assert_task_status "later task remains unmerged" "$INIT_DIR" "z-fail-stop" "done"

# Restore test_cmd to empty so remaining tests aren't affected by false.
set_test_cmd "$INIT_DIR/.orchd.toml" ""

printf '\n[14] Memory bank commands\n'
assert_exit_0 "memory (no memory yet) exits 0" run_in_dir "$INIT_DIR" "$ORCHD" memory
assert_exit_0 "memory --help exits 0" run_in_dir "$INIT_DIR" "$ORCHD" memory --help
assert_exit_0 "memory init exits 0" run_in_dir "$INIT_DIR" "$ORCHD" memory init

if [[ -d "$INIT_DIR/docs/memory" ]]; then
	pass "memory init creates docs/memory/"
else
	fail "memory init creates docs/memory/"
fi

if [[ -f "$INIT_DIR/docs/memory/projectbrief.md" ]]; then
	pass "memory init creates projectbrief.md"
else
	fail "memory init creates projectbrief.md"
fi

if [[ -f "$INIT_DIR/docs/memory/activeContext.md" ]]; then
	pass "memory init creates activeContext.md"
else
	fail "memory init creates activeContext.md"
fi

if [[ -f "$INIT_DIR/docs/memory/progress.md" ]]; then
	pass "memory init creates progress.md"
else
	fail "memory init creates progress.md"
fi

if [[ -f "$INIT_DIR/docs/memory/systemPatterns.md" ]]; then
	pass "memory init creates systemPatterns.md"
else
	fail "memory init creates systemPatterns.md"
fi

if [[ -f "$INIT_DIR/docs/memory/techContext.md" ]]; then
	pass "memory init creates techContext.md"
else
	fail "memory init creates techContext.md"
fi

if [[ -d "$INIT_DIR/docs/memory/lessons" ]]; then
	pass "memory init creates lessons/"
else
	fail "memory init creates lessons/"
fi

assert_exit_0 "memory show exits 0" run_in_dir "$INIT_DIR" "$ORCHD" memory show
assert_exit_0 "memory update exits 0" run_in_dir "$INIT_DIR" "$ORCHD" memory update
assert_output_contains "memory status shows projectbrief" "projectbrief.md" run_in_dir "$INIT_DIR" "$ORCHD" memory
assert_exit_nonzero "memory reset without --force fails" run_in_dir "$INIT_DIR" "$ORCHD" memory reset
assert_exit_0 "memory reset --force exits 0" run_in_dir "$INIT_DIR" "$ORCHD" memory reset --force

if [[ ! -d "$INIT_DIR/docs/memory" ]]; then
	pass "memory reset removes docs/memory/"
else
	fail "memory reset removes docs/memory/"
fi

# Re-init memory for merge test below
run_in_dir "$INIT_DIR" "$ORCHD" memory init >/dev/null 2>&1

printf '\n[15] Memory bank merge integration\n'
# Create a task with a TASK_REPORT.md, mark done, and merge — verify lesson is written.
run_in_dir "$INIT_DIR" git checkout -q "$BASE_BRANCH"
run_in_dir "$INIT_DIR" git checkout -q -b "agent-memory-lesson-test"
printf 'memory-lesson-test\n' >"$INIT_DIR/mem_lesson_test.txt"
run_in_dir "$INIT_DIR" git add "mem_lesson_test.txt"
run_in_dir "$INIT_DIR" git commit -q -m "test: memory lesson"
# Write a minimal TASK_REPORT.md in the branch (it lives as a local file — irrelevant for merge)
run_in_dir "$INIT_DIR" git checkout -q "$BASE_BRANCH"

mkdir -p "$INIT_DIR/.orchd/tasks/memory-lesson-test"
printf 'done\n' >"$INIT_DIR/.orchd/tasks/memory-lesson-test/status"
printf 'agent-memory-lesson-test\n' >"$INIT_DIR/.orchd/tasks/memory-lesson-test/branch"
printf 'Memory lesson test task\n' >"$INIT_DIR/.orchd/tasks/memory-lesson-test/title"
printf 'Test memory lesson writing\n' >"$INIT_DIR/.orchd/tasks/memory-lesson-test/description"

assert_exit_0 "merge writes memory lesson" run_in_dir "$INIT_DIR" "$ORCHD" merge "memory-lesson-test"

if [[ -f "$INIT_DIR/docs/memory/lessons/memory-lesson-test.md" ]]; then
	pass "lesson file created after merge"
else
	fail "lesson file created after merge"
fi

if [[ -f "$INIT_DIR/docs/memory/progress.md" ]]; then
	if grep -q "memory-lesson-test" "$INIT_DIR/docs/memory/progress.md" 2>/dev/null; then
		pass "progress.md updated after merge"
	else
		fail "progress.md updated after merge (task not found in progress)"
	fi
else
	fail "progress.md updated after merge (file missing)"
fi

printf '\n[16] Idea queue commands\n'
assert_exit_0 "idea --help exits 0" run_in_dir "$INIT_DIR" "$ORCHD" idea --help
assert_exit_nonzero "idea without args fails" run_in_dir "$INIT_DIR" "$ORCHD" idea
assert_exit_0 "idea queues an idea" run_in_dir "$INIT_DIR" "$ORCHD" idea "build user dashboard"
assert_exit_0 "idea queues second idea" run_in_dir "$INIT_DIR" "$ORCHD" idea "add notifications"

if [[ -f "$INIT_DIR/.orchd/queue.md" ]]; then
	pass "queue.md created"
else
	fail "queue.md created"
fi

assert_output_contains "idea list shows first idea" "build user dashboard" run_in_dir "$INIT_DIR" "$ORCHD" idea list
assert_output_contains "idea list shows second idea" "add notifications" run_in_dir "$INIT_DIR" "$ORCHD" idea list
assert_output_contains "idea count shows 2" "2" run_in_dir "$INIT_DIR" "$ORCHD" idea count

# Verify queue drain does not consume ideas when runner is unavailable.
ORCHD_LIB_DIR="$(dirname "$ORCHD")/../lib"
QUEUE_COUNT_AFTER_NONE=$(
	cd "$INIT_DIR" || exit 1
	# shellcheck source=../lib/core.sh
	source "$ORCHD_LIB_DIR/core.sh"
	# shellcheck source=../lib/cmd/autopilot.sh
	source "$ORCHD_LIB_DIR/cmd/autopilot.sh"
	# These variables are used by sourced helpers.
	# shellcheck disable=SC2034
	PROJECT_ROOT="$INIT_DIR"
	ORCHD_DIR="$INIT_DIR/.orchd"
	# shellcheck disable=SC2034
	TASKS_DIR="$ORCHD_DIR/tasks"
	# shellcheck disable=SC2034
	LOGS_DIR="$ORCHD_DIR/logs"
	_autopilot_drain_queue "none" 0 >/dev/null 2>&1 || true
	queue_count
)
if [[ "$QUEUE_COUNT_AFTER_NONE" == "2" ]]; then
	pass "queue drain keeps ideas when runner unavailable"
else
	fail "queue drain keeps ideas when runner unavailable (got: $QUEUE_COUNT_AFTER_NONE)"
fi

# Test queue_pop via internal helper (source core.sh to get helpers)
QUEUE_POP_OUTPUT=$(
	cd "$INIT_DIR" || exit 1
	# shellcheck source=../lib/core.sh
	source "$ORCHD_LIB_DIR/core.sh"
	# These variables are used by functions in core.sh
	# shellcheck disable=SC2034
	PROJECT_ROOT="$INIT_DIR"
	ORCHD_DIR="$INIT_DIR/.orchd"
	# shellcheck disable=SC2034
	TASKS_DIR="$ORCHD_DIR/tasks"
	# shellcheck disable=SC2034
	LOGS_DIR="$ORCHD_DIR/logs"
	queue_pop
)
if [[ "$QUEUE_POP_OUTPUT" == "build user dashboard" ]]; then
	pass "queue_pop returns first idea"
else
	fail "queue_pop returns first idea (got: $QUEUE_POP_OUTPUT)"
fi

assert_output_contains "idea count after pop is 1" "1" run_in_dir "$INIT_DIR" "$ORCHD" idea count

assert_exit_nonzero "idea clear without --force fails" run_in_dir "$INIT_DIR" "$ORCHD" idea clear
assert_exit_0 "idea clear --force exits 0" run_in_dir "$INIT_DIR" "$ORCHD" idea clear --force
assert_output_contains "idea count after clear is 0" "0" run_in_dir "$INIT_DIR" "$ORCHD" idea count

printf '\n[17] Fleet commands\n'
assert_exit_0 "fleet --help exits 0" "$ORCHD" fleet --help
assert_exit_nonzero "fleet list without config fails" "$ORCHD" fleet list

# Create a temporary fleet config
FLEET_DIR=$(mktemp -d)
FLEET_CFG="$FLEET_DIR/fleet.toml"
FLEET_SPACE_PATH="$FLEET_DIR/project with space"
mkdir -p "$FLEET_SPACE_PATH"
cat >"$FLEET_CFG" <<TOML
[projects.testproj]
path = "$INIT_DIR"

[projects.missing]
path = "/nonexistent/path"

[projects.spaced]
path = "$FLEET_SPACE_PATH"
TOML
export ORCHD_STATE_DIR="$FLEET_DIR"

assert_exit_0 "fleet list with config exits 0" "$ORCHD" fleet list
assert_output_contains "fleet list shows testproj" "testproj" "$ORCHD" fleet list
assert_output_contains "fleet list shows missing" "missing" "$ORCHD" fleet list
assert_output_contains "fleet list preserves spaces" "project with space" "$ORCHD" fleet list
assert_exit_0 "fleet status exits 0" "$ORCHD" fleet status
assert_output_contains "fleet status shows testproj" "testproj" "$ORCHD" fleet status
assert_exit_0 "fleet brief exits 0" "$ORCHD" fleet brief
assert_output_contains "fleet brief shows testproj" "testproj" "$ORCHD" fleet brief
assert_exit_0 "fleet stop exits 0" "$ORCHD" fleet stop

# Restore state dir
export ORCHD_STATE_DIR="$ORCHD_TEST_STATE_DIR"
rm -rf "$FLEET_DIR"

printf '\n[18] Help includes new commands\n'
assert_output_contains "help shows memory" "memory" "$ORCHD" --help
assert_output_contains "help shows idea" "idea" "$ORCHD" --help
assert_output_contains "help shows fleet" "fleet" "$ORCHD" --help

# --- Summary ---

printf '\n=== Results: %d passed, %d failed, %d total ===\n' "$PASS" "$FAIL" "$TOTAL"

if ((FAIL > 0)); then
	exit 1
fi
