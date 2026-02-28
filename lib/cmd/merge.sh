#!/usr/bin/env bash
# lib/cmd/merge.sh - orchd merge command
# DAG-ordered merge of completed tasks into base branch

cmd_merge() {
	local target="${1:-}"

	require_project

	if [[ "$target" == "--all" ]]; then
		_merge_all_ready
	elif [[ -n "$target" ]]; then
		_merge_single "$target"
	else
		die "usage: orchd merge <task-id> | orchd merge --all"
	fi
}

_merge_single() {
	local task_id=$1

	task_exists "$task_id" || die "task not found: $task_id"

	local status
	status=$(task_status "$task_id")

	if [[ "$status" == "merged" ]]; then
		printf 'already merged: %s\n' "$task_id"
		return 0
	fi

	if [[ "$status" != "done" ]]; then
		die "task not ready for merge (status: $status). Run: orchd check $task_id"
	fi

	# Verify all dependencies are merged
	local deps
	deps=$(task_get "$task_id" "deps" "")
	if [[ -n "$deps" ]]; then
		local dep dep_status
		while IFS=',' read -ra dep_arr; do
			for dep in "${dep_arr[@]}"; do
				dep=$(printf '%s' "$dep" | tr -d '[:space:]')
				[[ -z "$dep" ]] && continue
				dep_status=$(task_status "$dep")
				if [[ "$dep_status" != "merged" ]]; then
					die "dependency not merged: $dep (status: $dep_status). Merge dependencies first."
				fi
			done
		done <<<"$deps"
	fi

	local branch
	branch=$(task_get "$task_id" "branch" "agent-${task_id}")
	local base_branch
	base_branch=$(config_get "base_branch" "main")

	printf 'merging %s (%s -> %s)...\n' "$task_id" "$branch" "$base_branch"

	# Perform the merge
	if ! git -C "$PROJECT_ROOT" merge --no-ff "$branch" -m "merge: $task_id ($branch)"; then
		printf '\nmerge conflict detected!\n'
		printf 'resolve conflicts in %s, then run:\n' "$PROJECT_ROOT"
		printf '  git add . && git commit\n'
		printf '  orchd merge %s  (retry)\n' "$task_id"
		log_event "ERROR" "merge conflict: $task_id ($branch -> $base_branch)"
		task_set "$task_id" "status" "conflict"
		return 1
	fi

	task_set "$task_id" "status" "merged"
	task_set "$task_id" "merged_at" "$(now_iso)"

	printf 'merged: %s\n' "$task_id"
	log_event "INFO" "task merged: $task_id ($branch -> $base_branch)"

	# Run post-merge regression if test command is configured
	local test_cmd
	test_cmd=$(config_get "test_cmd" "")
	if [[ -n "$test_cmd" ]]; then
		printf 'running post-merge tests...\n'
		if (cd "$PROJECT_ROOT" && eval "$test_cmd" >/dev/null 2>&1); then
			printf '  [PASS] post-merge tests passed\n'
			log_event "INFO" "post-merge regression passed: $task_id"
		else
			printf '  [FAIL] post-merge tests failed!\n'
			printf '  consider: git revert HEAD\n'
			log_event "ERROR" "post-merge regression failed: $task_id"
		fi
	fi

	# Clean up worktree
	local worktree
	worktree=$(task_get "$task_id" "worktree" "")
	if [[ -n "$worktree" ]] && [[ -d "$worktree" ]]; then
		worktree_remove "$PROJECT_ROOT" "$worktree"
	fi

	# Check if new tasks are now unblocked
	local unblocked=0
	local tid
	while IFS= read -r tid; do
		[[ -z "$tid" ]] && continue
		if task_is_ready "$tid"; then
			local tid_status
			tid_status=$(task_status "$tid")
			if [[ "$tid_status" == "pending" ]]; then
				unblocked=$((unblocked + 1))
			fi
		fi
	done <<<"$(task_list_ids)"

	if ((unblocked > 0)); then
		printf '\n%d task(s) unblocked — run: orchd spawn --all\n' "$unblocked"
	fi
}

_merge_all_ready() {
	# Topological sort: merge tasks whose deps are all merged
	local merged_count=0
	local max_iterations=50
	local iteration=0

	while ((iteration < max_iterations)); do
		iteration=$((iteration + 1))
		local merged_this_round=0

		local task_id
		while IFS= read -r task_id; do
			[[ -z "$task_id" ]] && continue

			local status
			status=$(task_status "$task_id")
			[[ "$status" == "done" ]] || continue

			# Check all deps are merged
			local all_deps_merged=true
			local deps
			deps=$(task_get "$task_id" "deps" "")
			if [[ -n "$deps" ]]; then
				local dep dep_status
				while IFS=',' read -ra dep_arr; do
					for dep in "${dep_arr[@]}"; do
						dep=$(printf '%s' "$dep" | tr -d '[:space:]')
						[[ -z "$dep" ]] && continue
						dep_status=$(task_status "$dep")
						if [[ "$dep_status" != "merged" ]]; then
							all_deps_merged=false
							break 2
						fi
					done
				done <<<"$deps"
			fi

			if $all_deps_merged; then
				_merge_single "$task_id"
				merged_count=$((merged_count + 1))
				merged_this_round=$((merged_this_round + 1))
				printf '\n'
			fi
		done <<<"$(task_list_ids)"

		# No more tasks to merge this round
		if ((merged_this_round == 0)); then
			break
		fi
	done

	if ((merged_count == 0)); then
		printf 'no tasks ready to merge (run: orchd check --all)\n'
	else
		printf 'total merged: %d\n' "$merged_count"
	fi
}
