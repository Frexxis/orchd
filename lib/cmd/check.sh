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

	if [[ "$status" != "running" ]] && [[ "$status" != "done" ]]; then
		die "task is not ready for check (status: $status)"
	fi

	local worktree
	worktree=$(task_get "$task_id" "worktree" "")
	[[ -n "$worktree" ]] || die "no worktree found for task: $task_id"
	[[ -d "$worktree" ]] || die "worktree missing: $worktree"

	printf '=== quality gate: %s ===\n\n' "$task_id"

	local passed=0
	local failed=0
	local skipped=0
	local total=0

	# 1. Check if agent session has exited (task is complete)
	total=$((total + 1))
	local agent_alive=false
	if runner_is_alive "$task_id"; then
		agent_alive=true
	fi

	if $agent_alive; then
		printf '  [SKIP] agent still running\n'
		skipped=$((skipped + 1))
	else
		local exit_code
		exit_code=$(runner_exit_code "$task_id" || true)
		if [[ -z "$exit_code" ]]; then
			printf '  [FAIL] agent exit status unknown (missing ORCHD_EXIT marker)\n'
			failed=$((failed + 1))
		elif [[ "$exit_code" == "0" ]]; then
			printf '  [PASS] agent session completed (exit=0)\n'
			passed=$((passed + 1))
		else
			printf '  [FAIL] agent session failed (exit=%s)\n' "$exit_code"
			failed=$((failed + 1))
		fi
	fi

	# 2. Check for TASK_REPORT.md
	total=$((total + 1))
	if [[ -f "$worktree/TASK_REPORT.md" ]]; then
		printf '  [PASS] TASK_REPORT.md exists\n'
		passed=$((passed + 1))
	else
		printf '  [FAIL] TASK_REPORT.md not found\n'
		failed=$((failed + 1))
	fi

	# 3. Check for BLOCKER.md (presence = warning)
	if [[ -f "$worktree/BLOCKER.md" ]]; then
		printf '  [WARN] BLOCKER.md found — review required\n'
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
		printf '  [PASS] %d commit(s) on branch %s\n' "$commit_count" "$branch"
		passed=$((passed + 1))
	else
		printf '  [FAIL] no commits on branch %s\n' "$branch"
		failed=$((failed + 1))
	fi

	# 5. Resolve quality commands (config or auto-detect)
	local lint_cmd test_cmd build_cmd
	local auto_detect_used=false

	lint_cmd=$(config_get "lint_cmd" "")
	test_cmd=$(config_get "test_cmd" "")
	build_cmd=$(config_get "build_cmd" "")

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

	if $auto_detect_used; then
		if [[ -n "$ORCHD_DETECTED_STACK" ]]; then
			printf '  [INFO] auto-detected stack: %s\n' "$ORCHD_DETECTED_STACK"
		else
			printf '  [WARN] auto-detect could not determine stack; set lint_cmd/test_cmd/build_cmd in .orchd.toml\n'
		fi
		if [[ -z "$lint_cmd" ]]; then
			printf '  [WARN] no lint command detected\n'
		fi
		if [[ -z "$test_cmd" ]]; then
			printf '  [WARN] no test command detected\n'
		fi
		if [[ -z "$build_cmd" ]]; then
			printf '  [WARN] no build command detected\n'
		fi
		if [[ -n "$ORCHD_DETECTED_NOTES" ]]; then
			while IFS= read -r line; do
				[[ -n "$line" ]] && printf '  [NOTE] %s\n' "$line"
			done <<<"$ORCHD_DETECTED_NOTES"
		fi
	fi

	# 6. Run lint command if configured
	if [[ -n "$lint_cmd" ]]; then
		total=$((total + 1))
		printf '  [RUN]  lint: %s\n' "$lint_cmd"
		if (cd "$worktree" && eval "$lint_cmd" >/dev/null 2>&1); then
			printf '  [PASS] lint passed\n'
			passed=$((passed + 1))
		else
			printf '  [FAIL] lint failed\n'
			failed=$((failed + 1))
		fi
	fi

	# 7. Run test command if configured
	if [[ -n "$test_cmd" ]]; then
		total=$((total + 1))
		printf '  [RUN]  test: %s\n' "$test_cmd"
		if (cd "$worktree" && eval "$test_cmd" >/dev/null 2>&1); then
			printf '  [PASS] tests passed\n'
			passed=$((passed + 1))
		else
			printf '  [FAIL] tests failed\n'
			failed=$((failed + 1))
		fi
	fi

	# 8. Run build command if configured
	if [[ -n "$build_cmd" ]]; then
		total=$((total + 1))
		printf '  [RUN]  build: %s\n' "$build_cmd"
		if (cd "$worktree" && eval "$build_cmd" >/dev/null 2>&1); then
			printf '  [PASS] build passed\n'
			passed=$((passed + 1))
		else
			printf '  [FAIL] build failed\n'
			failed=$((failed + 1))
		fi
	fi

	# Summary
	printf '\n  --- %d/%d passed' "$passed" "$total"
	if ((skipped > 0)); then
		printf ' (%d skipped)' "$skipped"
	fi
	if ((failed > 0)); then
		printf ' (%d failed)' "$failed"
	fi
	printf ' ---\n'

	# Record evidence
	task_set "$task_id" "check_passed" "$passed"
	task_set "$task_id" "check_total" "$total"
	task_set "$task_id" "check_skipped" "$skipped"
	task_set "$task_id" "check_failed" "$failed"
	task_set "$task_id" "checked_at" "$(now_iso)"

	if ((failed == 0)) && ! $agent_alive; then
		task_set "$task_id" "status" "done"
		printf '\n  task marked as DONE (ready for merge)\n'
		log_event "INFO" "quality gate passed: $task_id ($passed/$total)"
	else
		if $agent_alive; then
			printf '\n  agent still running — check again later\n'
		else
			log_event "WARN" "quality gate failed: $task_id ($passed/$total, $failed failed)"
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
