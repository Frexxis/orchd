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

printf '\n[3] List (no sessions)\n'
assert_output_contains "list shows no sessions msg" "no active" "$ORCHD" list

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

printf '\n[7] Orchestration commands (no-project validation)\n'
# These should fail gracefully when not in an orchd project
assert_exit_nonzero "plan without project fails" "$ORCHD" plan "test"
assert_exit_nonzero "spawn without project fails" "$ORCHD" spawn --all
assert_exit_nonzero "check without project fails" "$ORCHD" check --all
assert_exit_nonzero "merge without project fails" "$ORCHD" merge --all

printf '\n[8] Board command (in initialized project)\n'
# Board should work in an initialized project (shows empty board)
assert_exit_0 "board in init dir" run_in_dir "$INIT_DIR" "$ORCHD" board

printf '\n[9] Help includes orchestration commands\n'
assert_output_contains "help shows init" "init" "$ORCHD" --help
assert_output_contains "help shows plan" "plan" "$ORCHD" --help
assert_output_contains "help shows spawn" "spawn" "$ORCHD" --help
assert_output_contains "help shows board" "board" "$ORCHD" --help
assert_output_contains "help shows check" "check" "$ORCHD" --help
assert_output_contains "help shows merge" "merge" "$ORCHD" --help

printf '\n[10] Merge checks out base branch before merge\n'
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

printf '\n[11] Merge --all stops after post-merge test failure\n'
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

# --- Summary ---

printf '\n=== Results: %d passed, %d failed, %d total ===\n' "$PASS" "$FAIL" "$TOTAL"

if ((FAIL > 0)); then
	exit 1
fi
