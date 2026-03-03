#!/usr/bin/env bash
# lib/cmd/check.sh - orchd check command
# Quality gate: lint, test, build, task report verification

cmd_check() {
	local target="${1:-}"

	require_project

	if [[ "$target" == "--all" ]]; then
		_check_all
	elif [[ -n "$target" ]]; then
		_check_single "$target"
	else
		die "usage: orchd check <task-id> | orchd check --all"
	fi
}

_check_single() {
	local task_id=$1

	task_exists "$task_id" || die "task not found: $task_id"

	local status
	status=$(task_status "$task_id")

	if [[ "$status" != "running" ]] && [[ "$status" != "done" ]] && [[ "$status" != "failed" ]] && [[ "$status" != "needs_input" ]]; then
		die "task is not ready for check (status: $status)"
	fi

	local worktree
	worktree=$(task_get "$task_id" "worktree" "")
	[[ -n "$worktree" ]] || die "no worktree found for task: $task_id"
	[[ -d "$worktree" ]] || die "worktree missing: $worktree"

	local check_file
	check_file="$(task_dir "$task_id")/last_check.txt"
	: >"$check_file"

	_check_printf() {
		local fmt=$1
		shift
		# shellcheck disable=SC2059
		printf "$fmt" "$@"
		# shellcheck disable=SC2059
		printf "$fmt" "$@" >>"$check_file"
	}

	_quality_exec() {
		local kind=$1
		local cmd=$2
		ORCHD_QUALITY_TMP=$(mktemp "${ORCHD_DIR}/.orchd-check-${task_id}-${kind}.XXXXXX")
		ORCHD_QUALITY_RC=0
		(cd "$worktree" && eval "$cmd") >"$ORCHD_QUALITY_TMP" 2>&1 || ORCHD_QUALITY_RC=$?
		return "$ORCHD_QUALITY_RC"
	}

	_validate_test_cmd_paths() {
		local cmd=$1
		if ! command -v python3 >/dev/null 2>&1; then
			return 0
		fi
		local out rc
		out=$(
			python3 - "$worktree" "$cmd" <<'PY'
import difflib
import os
import shlex
import sys

root = sys.argv[1]
cmd = sys.argv[2]

try:
    args = shlex.split(cmd)
except Exception:
    sys.exit(0)

def is_pytest_invocation(a):
    if not a:
        return (False, 0)
    exe = os.path.basename(a[0])
    if exe == "pytest" or a[0].endswith("/pytest"):
        return (True, 1)
    if exe in ("python", "python3") or a[0].endswith("/python") or a[0].endswith("/python3"):
        if len(a) >= 3 and a[1] == "-m" and a[2] == "pytest":
            return (True, 3)
    return (False, 0)

is_pytest, start = is_pytest_invocation(args)
if not is_pytest:
    sys.exit(0)

missing = []
candidates = []
for a in args[start:]:
    if a.startswith("-"):
        continue
    # Path-like args only.
    if "::" in a:
        a = a.split("::", 1)[0]
    if any(ch in a for ch in ("*", "?", "[", "]", "{", "}")):
        continue
    if a.endswith(".py") or "/" in a or a.startswith("tests") or a.startswith("./"):
        candidates.append(a)

for p in candidates:
    abs_p = os.path.normpath(os.path.join(root, p))
    if not (os.path.isfile(abs_p) or os.path.isdir(abs_p)):
        missing.append(p)

if not missing:
    sys.exit(0)

print("pytest: test_cmd references missing path(s):")
for p in missing:
    print(f"  - {p}")

# Suggest close matches among test files.
all_tests = []
for dirpath, dirnames, filenames in os.walk(root):
    rel_dir = os.path.relpath(dirpath, root)
    # Skip heavy/irrelevant dirs.
    dirnames[:] = [d for d in dirnames if d not in (".git", ".orchd", ".worktrees", "node_modules", ".venv")]
    for fn in filenames:
        if fn.startswith("test") and fn.endswith(".py"):
            rp = os.path.normpath(os.path.join(rel_dir, fn))
            if rp == ".":
                rp = fn
            all_tests.append(rp)

if all_tests:
    print("pytest: did you mean:")
    for p in missing:
        base = os.path.basename(p)
        matches = difflib.get_close_matches(base, [os.path.basename(x) for x in all_tests], n=3, cutoff=0.6)
        if matches:
            for m in matches:
                # Show the first path that ends with the matched basename.
                for full in all_tests:
                    if os.path.basename(full) == m:
                        print(f"  - {full}")
                        break
PY
		)
		rc=$?
		if ((rc != 0)); then
			# If the validator itself errored, don't block tests.
			return 0
		fi
		if [[ -n "$out" ]]; then
			_check_printf '  [FAIL] invalid pytest path(s) in test_cmd\n'
			_check_printf '%s\n' "$out"
			return 1
		fi
		return 0
	}

	_check_printf '=== quality gate: %s ===\n\n' "$task_id"

	local passed=0
	local failed=0
	local skipped=0
	local total=0
	local needs_input=false
	if [[ -f "$worktree/.orchd_needs_input.md" ]]; then
		needs_input=true
		total=$((total + 1))
		_check_printf '  [FAIL] needs user input (.orchd_needs_input.md present)\n'
		failed=$((failed + 1))
	fi
	# Backward compatibility: treat BLOCKER.md as needs_input as well.
	if [[ -f "$worktree/BLOCKER.md" ]]; then
		needs_input=true
		total=$((total + 1))
		_check_printf '  [FAIL] blocked (BLOCKER.md present; use .orchd_needs_input.md going forward)\n'
		failed=$((failed + 1))
	fi

	# 1. Check if agent session has exited (task is complete)
	total=$((total + 1))
	local agent_alive=false
	if runner_is_alive "$task_id"; then
		agent_alive=true
	fi

	# If the worker explicitly requested user input, treat as terminal immediately.
	if $needs_input; then
		task_set "$task_id" "status" "needs_input"
		task_set "$task_id" "needs_input_at" "$(now_iso)"
		if $agent_alive; then
			runner_stop "$task_id"
			agent_alive=false
			_check_printf '  [INFO] stopped agent session due to needs_input\n'
		fi
		_check_printf '\n  task marked as NEEDS_INPUT (.orchd_needs_input.md)\n'
		log_event "WARN" "needs input: $task_id"

		# Record evidence and exit early
		task_set "$task_id" "check_passed" "$passed"
		task_set "$task_id" "check_total" "$total"
		task_set "$task_id" "check_skipped" "$skipped"
		task_set "$task_id" "check_failed" "$failed"
		task_set "$task_id" "checked_at" "$(now_iso)"
		task_set "$task_id" "last_check_file" "$check_file"
		return 0
	fi

	if $agent_alive; then
		_check_printf '  [SKIP] agent still running\n'
		skipped=$((skipped + 1))
	else
		local exit_code
		exit_code=$(runner_exit_code "$task_id" || true)
		if [[ -z "$exit_code" ]]; then
			_check_printf '  [FAIL] agent exit status unknown (missing ORCHD_EXIT marker)\n'
			failed=$((failed + 1))
		elif [[ "$exit_code" == "0" ]]; then
			_check_printf '  [PASS] agent session completed (exit=0)\n'
			passed=$((passed + 1))
		else
			_check_printf '  [FAIL] agent session failed (exit=%s)\n' "$exit_code"
			failed=$((failed + 1))
		fi
		task_set "$task_id" "agent_exit_code" "${exit_code:-unknown}"
	fi

	# 2. Check for TASK_REPORT.md and validate minimal contents
	total=$((total + 1))
	if [[ -f "$worktree/TASK_REPORT.md" ]]; then
		# Archive task report into orchd state so it survives worktree cleanup.
		local attempts
		attempts=$(task_get "$task_id" "attempts" "0")
		if ! [[ "$attempts" =~ ^[0-9]+$ ]]; then
			attempts=0
		fi
		local archived_report
		archived_report="$(task_dir "$task_id")/TASK_REPORT.attempt${attempts}.md"
		cp "$worktree/TASK_REPORT.md" "$archived_report" 2>/dev/null || true
		task_set "$task_id" "task_report_file" "$archived_report"

		local report_ok=true
		if ! grep -q '^EVIDENCE:' "$worktree/TASK_REPORT.md" 2>/dev/null; then
			report_ok=false
		fi
		if ! grep -q '^[[:space:]]*- CMD:' "$worktree/TASK_REPORT.md" 2>/dev/null; then
			report_ok=false
		fi
		if ! grep -q '^[[:space:]]*RESULT:' "$worktree/TASK_REPORT.md" 2>/dev/null; then
			report_ok=false
		fi
		if ! grep -q '^[[:space:]]*OUTPUT:' "$worktree/TASK_REPORT.md" 2>/dev/null; then
			report_ok=false
		fi
		if ! grep -qi 'rollback' "$worktree/TASK_REPORT.md" 2>/dev/null; then
			report_ok=false
		fi
		if $report_ok; then
			_check_printf '  [PASS] TASK_REPORT.md exists (evidence + rollback present)\n'
			passed=$((passed + 1))
		else
			_check_printf '  [FAIL] TASK_REPORT.md incomplete (missing evidence and/or rollback note)\n'
			_check_printf '         expected: EVIDENCE + - CMD + RESULT + OUTPUT, and a rollback note\n'
			failed=$((failed + 1))
		fi
	else
		_check_printf '  [FAIL] TASK_REPORT.md not found\n'
		failed=$((failed + 1))
	fi

	# 4. Check for commits on the branch
	total=$((total + 1))
	local branch
	branch=$(task_get "$task_id" "branch" "agent-${task_id}")
	local base_branch
	base_branch=$(config_get "base_branch" "main")

	local commit_count
	commit_count=$(git -C "$worktree" rev-list --count "${base_branch}..HEAD" 2>/dev/null || printf '0')

	if ((commit_count > 0)); then
		_check_printf '  [PASS] %d commit(s) on branch %s\n' "$commit_count" "$branch"
		passed=$((passed + 1))
	else
		_check_printf '  [FAIL] no commits on branch %s\n' "$branch"
		failed=$((failed + 1))
	fi

	# 5. Resolve quality commands (task override > config > auto-detect)
	local lint_cmd test_cmd build_cmd
	local auto_detect_used=false
	local task_lint_cmd task_test_cmd task_build_cmd

	task_lint_cmd=$(task_get "$task_id" "lint_cmd" "")
	task_test_cmd=$(task_get "$task_id" "test_cmd" "")
	task_build_cmd=$(task_get "$task_id" "build_cmd" "")

	# Task overrides win if set.
	lint_cmd="$task_lint_cmd"
	test_cmd="$task_test_cmd"
	build_cmd="$task_build_cmd"

	# Fill missing from global config.
	if [[ -z "$lint_cmd" ]]; then lint_cmd=$(config_get "lint_cmd" ""); fi
	if [[ -z "$test_cmd" ]]; then test_cmd=$(config_get "test_cmd" ""); fi
	if [[ -z "$build_cmd" ]]; then build_cmd=$(config_get "build_cmd" ""); fi

	if [[ -z "$lint_cmd" || -z "$test_cmd" || -z "$build_cmd" ]]; then
		auto_detect_used=true
		quality_detect_cmds "$worktree"

		if [[ -z "$lint_cmd" ]]; then
			lint_cmd="$ORCHD_DETECTED_LINT_CMD"
		fi
		if [[ -z "$test_cmd" ]]; then
			test_cmd="$ORCHD_DETECTED_TEST_CMD"
		fi
		if [[ -z "$build_cmd" ]]; then
			build_cmd="$ORCHD_DETECTED_BUILD_CMD"
		fi
	fi

	if [[ -n "$task_lint_cmd" || -n "$task_test_cmd" || -n "$task_build_cmd" ]]; then
		_check_printf '  [INFO] task-specific quality commands enabled\n'
	fi

	if $auto_detect_used; then
		if [[ -n "$ORCHD_DETECTED_STACK" ]]; then
			_check_printf '  [INFO] auto-detected stack: %s\n' "$ORCHD_DETECTED_STACK"
		else
			_check_printf '  [WARN] auto-detect could not determine stack; set lint_cmd/test_cmd/build_cmd in .orchd.toml\n'
		fi
		if [[ -z "$lint_cmd" ]]; then
			_check_printf '  [WARN] no lint command detected\n'
		fi
		if [[ -z "$test_cmd" ]]; then
			_check_printf '  [WARN] no test command detected\n'
		fi
		if [[ -z "$build_cmd" ]]; then
			_check_printf '  [WARN] no build command detected\n'
		fi
		if [[ -n "$ORCHD_DETECTED_NOTES" ]]; then
			while IFS= read -r line; do
				[[ -n "$line" ]] && _check_printf '  [NOTE] %s\n' "$line"
			done <<<"$ORCHD_DETECTED_NOTES"
		fi
	fi

	# 6. Run lint command if configured
	if [[ -n "$lint_cmd" ]]; then
		total=$((total + 1))
		_check_printf '  [RUN]  lint: %s\n' "$lint_cmd"
		if _quality_exec "lint" "$lint_cmd"; then
			_check_printf '  [PASS] lint passed\n'
			passed=$((passed + 1))
		else
			_check_printf '  [FAIL] lint failed\n'
			_check_printf '         --- output (last 200 lines) ---\n'
			_check_printf '%s\n' "$(tail -n 200 "$ORCHD_QUALITY_TMP" 2>/dev/null || true)"
			failed=$((failed + 1))
		fi
		rm -f "$ORCHD_QUALITY_TMP" 2>/dev/null || true
	fi

	# 7. Run test command if configured
	if [[ -n "$test_cmd" ]]; then
		total=$((total + 1))
		_check_printf '  [RUN]  test: %s\n' "$test_cmd"
		if ! _validate_test_cmd_paths "$test_cmd"; then
			failed=$((failed + 1))
		elif _quality_exec "test" "$test_cmd"; then
			_check_printf '  [PASS] tests passed\n'
			passed=$((passed + 1))
		else
			_check_printf '  [FAIL] tests failed\n'
			_check_printf '         --- output (last 200 lines) ---\n'
			_check_printf '%s\n' "$(tail -n 200 "$ORCHD_QUALITY_TMP" 2>/dev/null || true)"
			failed=$((failed + 1))
		fi
		rm -f "$ORCHD_QUALITY_TMP" 2>/dev/null || true
	fi

	# 8. Run build command if configured
	if [[ -n "$build_cmd" ]]; then
		total=$((total + 1))
		_check_printf '  [RUN]  build: %s\n' "$build_cmd"
		if _quality_exec "build" "$build_cmd"; then
			_check_printf '  [PASS] build passed\n'
			passed=$((passed + 1))
		else
			_check_printf '  [FAIL] build failed\n'
			_check_printf '         --- output (last 200 lines) ---\n'
			_check_printf '%s\n' "$(tail -n 200 "$ORCHD_QUALITY_TMP" 2>/dev/null || true)"
			failed=$((failed + 1))
		fi
		rm -f "$ORCHD_QUALITY_TMP" 2>/dev/null || true
	fi

	# Summary
	_check_printf '\n  --- %d/%d passed' "$passed" "$total"
	if ((skipped > 0)); then
		_check_printf ' (%d skipped)' "$skipped"
	fi
	if ((failed > 0)); then
		_check_printf ' (%d failed)' "$failed"
	fi
	_check_printf ' ---\n'

	# Record evidence
	task_set "$task_id" "check_passed" "$passed"
	task_set "$task_id" "check_total" "$total"
	task_set "$task_id" "check_skipped" "$skipped"
	task_set "$task_id" "check_failed" "$failed"
	task_set "$task_id" "checked_at" "$(now_iso)"
	task_set "$task_id" "last_check_file" "$check_file"

	if ((failed == 0)) && ! $agent_alive; then
		task_set "$task_id" "status" "done"
		_check_printf '\n  task marked as DONE (ready for merge)\n'
		log_event "INFO" "quality gate passed: $task_id ($passed/$total)"
	else
		if $agent_alive; then
			_check_printf '\n  agent still running — check again later\n'
		else
			if $needs_input; then
				task_set "$task_id" "status" "needs_input"
				task_set "$task_id" "needs_input_at" "$(now_iso)"
				_check_printf '\n  task marked as NEEDS_INPUT (.orchd_needs_input.md)\n'
				log_event "WARN" "needs input: $task_id"
			else
				task_set "$task_id" "status" "failed"
				task_set "$task_id" "last_failure_reason" "quality_gate"
				_check_printf '\n  task marked as FAILED (quality gate failed)\n'
				log_event "WARN" "quality gate failed: $task_id ($passed/$total, $failed failed)"
			fi
		fi
	fi
}

_check_all() {
	local task_id
	local checked=0
	while IFS= read -r task_id; do
		[[ -z "$task_id" ]] && continue
		local status
		status=$(task_status "$task_id")
		if [[ "$status" == "running" ]] || [[ "$status" == "done" ]]; then
			_check_single "$task_id"
			printf '\n'
			checked=$((checked + 1))
		fi
	done <<<"$(task_list_ids)"

	if ((checked == 0)); then
		printf 'no tasks ready for checking\n'
	fi
}
