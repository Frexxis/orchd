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
	if printf '%s' "$output" | grep -q -- "$pattern"; then
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

set_build_cmd() {
	local cfg=$1
	local cmd=$2
	local tmp
	tmp=$(mktemp)
	awk -v cmd="$cmd" '
		/^[[:space:]]*build_cmd[[:space:]]*=/ {
			print "build_cmd = \"" cmd "\""
			next
		}
		{ print }
	' "$cfg" >"$tmp"
	mv "$tmp" "$cfg"
}

set_orchestrator_profile() {
	local cfg=$1
	local profile=$2
	local tmp
	tmp=$(mktemp)
	awk -v profile="$profile" '
		BEGIN { in_orchestrator = 0; written = 0 }
		/^\[/ {
			if (in_orchestrator && !written) {
				print "profile = \"" profile "\""
				written = 1
			}
			in_orchestrator = ($0 ~ /^\[orchestrator\]$/)
			print
			next
		}
		{
			if (in_orchestrator && $0 ~ /^[[:space:]]*profile[[:space:]]*=/) {
				if (!written) {
					print "profile = \"" profile "\""
					written = 1
				}
				next
			}
			print
		}
		END {
			if (in_orchestrator && !written) {
				print "profile = \"" profile "\""
			}
		}
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

if grep -q '^[[:space:]]*profile = "fast"$' "$INIT_DIR/.orchd.toml" 2>/dev/null; then
	pass "init defaults profile to fast"
else
	fail "init defaults profile to fast"
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

printf '\n[6c] JSONL text extraction is tolerant\n'
ORCHD_LIB_DIR="$(dirname "$ORCHD")/../lib"
EXTRACT_OUT=$(
	cd "$INIT_DIR" || exit 1
	# shellcheck source=../lib/core.sh
	source "$ORCHD_LIB_DIR/core.sh"
	# shellcheck source=../lib/cmd/plan.sh
	source "$ORCHD_LIB_DIR/cmd/plan.sh"
	cat <<'EOF' | _extract_text_from_jsonl
{"type":"item.completed","item":{"type":"assistant_message","text":"TASK: t1\nTITLE: X"}}
EOF
)
if printf '%s' "$EXTRACT_OUT" | grep -q 'TASK: t1'; then
	pass "extractor reads item.completed text"
else
	fail "extractor reads item.completed text"
fi

EXTRACT_OUT2=$(
	cd "$INIT_DIR" || exit 1
	# shellcheck source=../lib/core.sh
	source "$ORCHD_LIB_DIR/core.sh"
	# shellcheck source=../lib/cmd/plan.sh
	source "$ORCHD_LIB_DIR/cmd/plan.sh"
	cat <<'EOF' | _extract_text_from_jsonl
{"type":"response.output_text.delta","delta":"TASK: t2\\n"}
{"type":"response.output_text.delta","delta":"TITLE: Y\\n"}
EOF
)
if printf '%s' "$EXTRACT_OUT2" | grep -q 'TASK: t2'; then
	pass "extractor falls back to delta stream"
else
	fail "extractor falls back to delta stream"
fi

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

printf '\n[9a] Doctor reports fast effective settings\n'
set_orchestrator_profile "$INIT_DIR/.orchd.toml" "fast"
DOCTOR_FAST_OUT=$(run_in_dir "$INIT_DIR" "$ORCHD" doctor)
if printf '%s' "$DOCTOR_FAST_OUT" | grep -q 'profile: .*fast'; then
	pass "doctor shows fast profile"
else
	fail "doctor shows fast profile"
fi
if printf '%s' "$DOCTOR_FAST_OUT" | grep -q 'max_parallel:  *8'; then
	pass "doctor shows fast max_parallel"
else
	fail "doctor shows fast max_parallel"
fi
if printf '%s' "$DOCTOR_FAST_OUT" | grep -q 'autopilot_poll:  *2'; then
	pass "doctor shows fast autopilot poll"
else
	fail "doctor shows fast autopilot poll"
fi
if printf '%s' "$DOCTOR_FAST_OUT" | grep -q 'verification_profile:  *fast'; then
	pass "doctor shows fast verification profile"
else
	fail "doctor shows fast verification profile"
fi
if printf '%s' "$DOCTOR_FAST_OUT" | grep -q 'post_merge_test:  *never'; then
	pass "doctor shows fast post-merge policy"
else
	fail "doctor shows fast post-merge policy"
fi
set_orchestrator_profile "$INIT_DIR/.orchd.toml" "balanced"

printf '\n[9b] Python auto-detect prefers venv bins\n'
mkdir -p "$INIT_DIR/.venv/bin"
printf '#!/usr/bin/env bash\nexit 0\n' >"$INIT_DIR/.venv/bin/python"
chmod +x "$INIT_DIR/.venv/bin/python"
printf '#!/usr/bin/env bash\nexit 0\n' >"$INIT_DIR/.venv/bin/ruff"
chmod +x "$INIT_DIR/.venv/bin/ruff"
printf '[build-system]\nrequires = []\n' >"$INIT_DIR/pyproject.toml"
DETECT_OUT=$(
	cd "$INIT_DIR" || exit 1
	# shellcheck source=../lib/core.sh
	source "$ORCHD_LIB_DIR/core.sh"
	quality_detect_cmds "$INIT_DIR"
	printf '%s\n' "$ORCHD_DETECTED_LINT_CMD"
)
if printf '%s' "$DETECT_OUT" | grep -q '^\.venv/bin/ruff'; then
	pass "python lint auto-detect uses .venv/bin/ruff"
else
	fail "python lint auto-detect uses .venv/bin/ruff"
fi

printf '\n[9c] Spawn uses fast effective parallelism\n'
set_orchestrator_profile "$INIT_DIR/.orchd.toml" "fast"
SPAWN_FAST_COUNT=$(
	cd "$INIT_DIR" || exit 1
	ORCHD_LIB_DIR="$(dirname "$ORCHD")/../lib"
	SPAWN_CAPTURE="$INIT_DIR/.orchd/spawn_capture.txt"
	# shellcheck source=../lib/core.sh
	source "$ORCHD_LIB_DIR/core.sh"
	# shellcheck source=../lib/runner.sh
	source "$ORCHD_LIB_DIR/runner.sh"
	# shellcheck source=../lib/cmd/spawn.sh
	source "$ORCHD_LIB_DIR/cmd/spawn.sh"
	# shellcheck disable=SC2034
	PROJECT_ROOT="$INIT_DIR"
	ORCHD_DIR="$INIT_DIR/.orchd"
	# shellcheck disable=SC2034
	TASKS_DIR="$ORCHD_DIR/tasks"
	# shellcheck disable=SC2034
	LOGS_DIR="$ORCHD_DIR/logs"
	for task_id in fast-spawn-a fast-spawn-b fast-spawn-c fast-spawn-d fast-spawn-e; do
		mkdir -p "$TASKS_DIR/$task_id"
		printf 'pending\n' >"$TASKS_DIR/$task_id/status"
		rm -f "$TASKS_DIR/$task_id/deps"
	done
	_spawn_single() {
		printf '%s\n' "$1" >>"$SPAWN_CAPTURE"
		return 0
	}
	_spawn_all_ready "opencode" >/dev/null
	wc -l <"$SPAWN_CAPTURE"
)
if [[ "$SPAWN_FAST_COUNT" == "5" ]]; then
	pass "spawn uses fast max_parallel"
else
	fail "spawn uses fast max_parallel (got: $SPAWN_FAST_COUNT)"
fi
rm -rf \
	"$INIT_DIR/.orchd/tasks/fast-spawn-a" \
	"$INIT_DIR/.orchd/tasks/fast-spawn-b" \
	"$INIT_DIR/.orchd/tasks/fast-spawn-c" \
	"$INIT_DIR/.orchd/tasks/fast-spawn-d" \
	"$INIT_DIR/.orchd/tasks/fast-spawn-e" \
	"$INIT_DIR/.orchd/spawn_capture.txt"
set_orchestrator_profile "$INIT_DIR/.orchd.toml" "balanced"

printf '\n[10] Help includes orchestration commands\n'
assert_output_contains "help shows init" "init" "$ORCHD" --help
assert_output_contains "help shows plan" "plan" "$ORCHD" --help
assert_output_contains "help shows review" "review" "$ORCHD" --help
assert_output_contains "help shows spawn" "spawn" "$ORCHD" --help
assert_output_contains "help shows board" "board" "$ORCHD" --help
assert_output_contains "help shows tui" "tui" "$ORCHD" --help
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

printf '\n[12a] Autopilot wait uses await helper in fast profile\n'
set_orchestrator_profile "$INIT_DIR/.orchd.toml" "fast"
AUTOPILOT_WAIT_OUT=$(
	cd "$INIT_DIR" || exit 1
	ORCHD_LIB_DIR="$(dirname "$ORCHD")/../lib"
	AWAIT_CAPTURE="$INIT_DIR/.orchd/await_capture.txt"
	# shellcheck source=../lib/core.sh
	source "$ORCHD_LIB_DIR/core.sh"
	# shellcheck source=../lib/cmd/autopilot.sh
	source "$ORCHD_LIB_DIR/cmd/autopilot.sh"
	# shellcheck disable=SC2034
	PROJECT_ROOT="$INIT_DIR"
	ORCHD_DIR="$INIT_DIR/.orchd"
	# shellcheck disable=SC2034
	TASKS_DIR="$ORCHD_DIR/tasks"
	# shellcheck disable=SC2034
	LOGS_DIR="$ORCHD_DIR/logs"
	cmd_await() {
		printf 'await %s %s %s %s %s\n' "$1" "$2" "$3" "$4" "$5" >"$AWAIT_CAPTURE"
		return 1
	}
	_autopilot_wait 2 1
	cat "$AWAIT_CAPTURE"
)
if printf '%s' "$AUTOPILOT_WAIT_OUT" | grep -q '^await --all --poll 1 --timeout 2$'; then
	pass "autopilot wait uses await"
else
	fail "autopilot wait uses await"
fi
set_orchestrator_profile "$INIT_DIR/.orchd.toml" "balanced"

printf '\n[12b] Fast verification skips redundant build\n'
set_orchestrator_profile "$INIT_DIR/.orchd.toml" "fast"
set_test_cmd "$INIT_DIR/.orchd.toml" "true"
set_build_cmd "$INIT_DIR/.orchd.toml" "false"
FAST_CHECK_WORKTREE="$INIT_DIR/.worktrees/agent-fast-check"
mkdir -p "$INIT_DIR/.worktrees"
run_in_dir "$INIT_DIR" git worktree add -q -b "agent-fast-check" "$FAST_CHECK_WORKTREE" "$BASE_BRANCH"
printf 'fast-check\n' >"$FAST_CHECK_WORKTREE/fast_check.txt"
run_in_dir "$FAST_CHECK_WORKTREE" git add "fast_check.txt"
run_in_dir "$FAST_CHECK_WORKTREE" git commit -q -m "test: fast check"
cat >"$FAST_CHECK_WORKTREE/TASK_REPORT.md" <<'EOF'
Summary of changes
- Fast verification fixture.

Files modified/created
- fast_check.txt

EVIDENCE:
- CMD: true
  RESULT: PASS
  OUTPUT: fixture prepared

Rollback note
- Roll back if fast verification fixture breaks regression coverage.
- Revert the fixture commit and remove the task state.

Risks/notes
- Test fixture only.
EOF
mkdir -p "$INIT_DIR/.orchd/tasks/fast-check"
printf 'running\n' >"$INIT_DIR/.orchd/tasks/fast-check/status"
printf '%s\n' "$FAST_CHECK_WORKTREE" >"$INIT_DIR/.orchd/tasks/fast-check/worktree"
printf 'agent-fast-check\n' >"$INIT_DIR/.orchd/tasks/fast-check/branch"
printf '0\n' >"$INIT_DIR/.orchd/logs/fast-check.exit"
assert_exit_0 "fast verification skips failing build" run_in_dir "$INIT_DIR" "$ORCHD" check fast-check
assert_task_status "fast verification task marked done" "$INIT_DIR" "fast-check" "done"
run_in_dir "$INIT_DIR" git worktree remove --force "$FAST_CHECK_WORKTREE" >/dev/null 2>&1 || true
set_test_cmd "$INIT_DIR/.orchd.toml" ""
set_build_cmd "$INIT_DIR/.orchd.toml" ""
set_orchestrator_profile "$INIT_DIR/.orchd.toml" "balanced"

printf '\n[12c] Fast merge skips post-merge tests\n'
set_orchestrator_profile "$INIT_DIR/.orchd.toml" "fast"
set_test_cmd "$INIT_DIR/.orchd.toml" "false"
run_in_dir "$INIT_DIR" git checkout -q "$BASE_BRANCH"
run_in_dir "$INIT_DIR" git checkout -q -b "agent-fast-merge-skip"
printf 'fast-merge-skip\n' >"$INIT_DIR/fast_merge_skip.txt"
run_in_dir "$INIT_DIR" git add "fast_merge_skip.txt"
run_in_dir "$INIT_DIR" git commit -q -m "test: fast merge skip"
run_in_dir "$INIT_DIR" git checkout -q "$BASE_BRANCH"
mkdir -p "$INIT_DIR/.orchd/tasks/fast-merge-skip"
printf 'done\n' >"$INIT_DIR/.orchd/tasks/fast-merge-skip/status"
printf 'agent-fast-merge-skip\n' >"$INIT_DIR/.orchd/tasks/fast-merge-skip/branch"
assert_exit_0 "fast merge skips post-merge test rerun" run_in_dir "$INIT_DIR" "$ORCHD" merge "fast-merge-skip"
assert_task_status "fast merge task marked merged" "$INIT_DIR" "fast-merge-skip" "merged"
set_test_cmd "$INIT_DIR/.orchd.toml" ""
set_orchestrator_profile "$INIT_DIR/.orchd.toml" "balanced"

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

if git -C "$INIT_DIR" log -n 20 --oneline | grep -q 'docs(memory): update after merging'; then
	fail "merge does not create separate docs(memory) commit"
else
	pass "merge does not create separate docs(memory) commit"
fi

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

# Verify plan failure does not mark in-progress idea complete (isolated state dir).
QUEUE_STATUS_AFTER_PLAN_FAIL=$(
	cd "$INIT_DIR" || exit 1
	# shellcheck source=../lib/core.sh
	source "$ORCHD_LIB_DIR/core.sh"
	# shellcheck source=../lib/cmd/autopilot.sh
	source "$ORCHD_LIB_DIR/cmd/autopilot.sh"
	# These variables are used by sourced helpers.
	# shellcheck disable=SC2034
	PROJECT_ROOT="$INIT_DIR"
	ORCHD_DIR="$INIT_DIR/.orchd_failtest"
	# shellcheck disable=SC2034
	TASKS_DIR="$ORCHD_DIR/tasks"
	# shellcheck disable=SC2034
	LOGS_DIR="$ORCHD_DIR/logs"
	mkdir -p "$TASKS_DIR" "$LOGS_DIR"

	queue_push "first idea" >/dev/null 2>&1
	queue_push "second idea" >/dev/null 2>&1

	# shellcheck disable=SC2329
	cmd_plan() { return 1; }
	_autopilot_drain_queue "opencode" 0 >/dev/null 2>&1 || true
	cat "$ORCHD_DIR/queue.md"
)
rm -rf "$INIT_DIR/.orchd_failtest" >/dev/null 2>&1 || true

if printf '%s' "$QUEUE_STATUS_AFTER_PLAN_FAIL" | grep -q -- "- \[>\]" && ! printf '%s' "$QUEUE_STATUS_AFTER_PLAN_FAIL" | grep -q -- "- \[x\]"; then
	pass "plan failure leaves idea in-progress"
else
	fail "plan failure leaves idea in-progress"
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

printf '\n[19] Ideate (autonomous backlog)\n'
assert_exit_0 "ideate --help exits 0" "$ORCHD" ideate --help
assert_output_contains "autopilot help shows continuous" "--continuous" "$ORCHD" autopilot --help

# Parse-only tests (no real runner invocation)
run_in_dir "$INIT_DIR" "$ORCHD" idea clear --force >/dev/null 2>&1 || true

ORCHD_LIB_DIR="$(dirname "$ORCHD")/../lib"
IDEATE_OUT="$INIT_DIR/.orchd/ideate_test_out.txt"
cat >"$IDEATE_OUT" <<'EOF'
IDEA: Add health check endpoint
REASON: Needed for ops readiness and monitoring

IDEA: Implement auth middleware
REASON: Required by project goals for secure endpoints

IDEA: Add integration tests for login
REASON: Prevent regressions and validate auth flow

IDEA: Add OpenAPI spec generation
REASON: Improves API usability and contract clarity

IDEA: Add rate limiting to auth endpoints
REASON: Security hardening for brute force prevention

IDEA: Improve logging format
REASON: Helps debugging and observability

IDEA: Add CI workflow
REASON: Enforces quality gates automatically
EOF

IDEATE_QUEUED_COUNT=$(
	cd "$INIT_DIR" || exit 1
	# shellcheck source=../lib/core.sh
	source "$ORCHD_LIB_DIR/core.sh"
	# shellcheck source=../lib/cmd/ideate.sh
	source "$ORCHD_LIB_DIR/cmd/ideate.sh"
	# These variables are used by sourced helpers.
	# shellcheck disable=SC2034
	PROJECT_ROOT="$INIT_DIR"
	ORCHD_DIR="$INIT_DIR/.orchd"
	# shellcheck disable=SC2034
	TASKS_DIR="$ORCHD_DIR/tasks"
	# shellcheck disable=SC2034
	LOGS_DIR="$ORCHD_DIR/logs"
	mkdir -p "$TASKS_DIR" "$LOGS_DIR"
	_ideate_parse_output "$IDEATE_OUT" false >/dev/null 2>&1 || exit 1
	queue_count
)
if [[ "$IDEATE_QUEUED_COUNT" == "5" ]]; then
	pass "ideate parse queues max_ideas (default 5)"
else
	fail "ideate parse queues max_ideas (expected 5, got: $IDEATE_QUEUED_COUNT)"
fi

IDEATE_COMPLETE_OUT="$INIT_DIR/.orchd/ideate_complete_out.txt"
cat >"$IDEATE_COMPLETE_OUT" <<'EOF'
PROJECT_COMPLETE
REASON: All goals in the project brief are satisfied.
EOF

IDEATE_COMPLETE_RC=$(
	cd "$INIT_DIR" || exit 1
	# shellcheck source=../lib/core.sh
	source "$ORCHD_LIB_DIR/core.sh"
	# shellcheck source=../lib/cmd/ideate.sh
	source "$ORCHD_LIB_DIR/cmd/ideate.sh"
	# shellcheck disable=SC2034
	PROJECT_ROOT="$INIT_DIR"
	ORCHD_DIR="$INIT_DIR/.orchd"
	# shellcheck disable=SC2034
	TASKS_DIR="$ORCHD_DIR/tasks"
	# shellcheck disable=SC2034
	LOGS_DIR="$ORCHD_DIR/logs"
	set +e
	_ideate_parse_output "$IDEATE_COMPLETE_OUT" true >/dev/null 2>&1
	echo "$?"
)
if [[ "$IDEATE_COMPLETE_RC" == "2" ]]; then
	pass "ideate parse returns PROJECT_COMPLETE"
else
	fail "ideate parse returns PROJECT_COMPLETE (expected 2, got: $IDEATE_COMPLETE_RC)"
fi

# --- Summary ---

printf '\n=== Results: %d passed, %d failed, %d total ===\n' "$PASS" "$FAIL" "$TOTAL"

if ((FAIL > 0)); then
	exit 1
fi
