#!/usr/bin/env bash
# lib/cmd/merge.sh - orchd merge command
# DAG-ordered merge of completed tasks into base branch

cmd_merge() {
	local target="${1:-}"

	require_project

	# Prevent concurrent merges from corrupting git state.
	# Lock is held for the lifetime of this process.
	if command -v flock >/dev/null 2>&1; then
		exec 9>"$ORCHD_DIR/merge.lock"
		flock -n 9 || die "another merge is already in progress"
	fi

	if [[ "$target" == "--all" ]]; then
		_merge_all_ready
	elif [[ -n "$target" ]]; then
		_merge_single "$target"
	else
		die "usage: orchd merge <task-id> | orchd merge --all"
	fi
}

_merge_try_auto_review() {
	local task_id=$1
	MERGE_AUTO_REVIEW_REASON=""

	if ! is_truthy "$(config_get "swarm.policy.auto_review" "true")"; then
		MERGE_AUTO_REVIEW_REASON="auto review disabled by swarm.policy.auto_review"
		return 1
	fi

	local review_status actual_tier actual_rank reviewer_runner
	review_status=$(printf '%s' "$(task_get "$task_id" "review_status" "")" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
	case "$review_status" in
	approved)
		MERGE_AUTO_REVIEW_REASON="approved review already present"
		return 0
		;;
	changes_requested)
		MERGE_AUTO_REVIEW_REASON="existing review already requested changes"
		return 1
		;;
	esac

	actual_tier=$(printf '%s' "$(task_get "$task_id" "verification_tier" "")" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
	actual_rank=$(verify_tier_rank "$actual_tier")
	if ((actual_rank < 2)); then
		MERGE_AUTO_REVIEW_REASON="verification tier ${actual_tier:-none} is too low for review override"
		return 1
	fi

	reviewer_runner=$(swarm_select_runner_for_role "reviewer" "$(detect_runner)")
	if [[ -z "$reviewer_runner" || "$reviewer_runner" == "none" ]]; then
		MERGE_AUTO_REVIEW_REASON="no reviewer runner available"
		return 1
	fi

	task_set "$task_id" "review_requested_at" "$(now_iso)"
	task_set "$task_id" "review_auto_triggered" "true"
	printf 'task requires review before merge: %s — running reviewer (%s)...\n' "$task_id" "$reviewer_runner"
	if _review_run "" "$task_id" >/dev/null 2>&1; then
		review_status=$(printf '%s' "$(task_get "$task_id" "review_status" "")" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
		if [[ "$review_status" == "approved" ]]; then
			MERGE_AUTO_REVIEW_REASON="auto review approved the task"
			log_event "INFO" "merge: auto review approved $task_id"
			return 0
		fi
		MERGE_AUTO_REVIEW_REASON="auto review did not approve the task"
		log_event "WARN" "merge: auto review did not approve $task_id"
		return 1
	fi

	MERGE_AUTO_REVIEW_REASON="review command failed"
	log_event "WARN" "merge: auto review failed for $task_id"
	return 1
}

_merge_single() {
	local task_id=$1

	task_exists "$task_id" || die "task not found: $task_id"

	local status
	status=$(task_status "$task_id")
	local prev_status="$status"

	if [[ "$status" == "merged" ]]; then
		printf 'already merged: %s\n' "$task_id"
		return 0
	fi

	if [[ "$status" != "done" ]] && [[ "$status" != "conflict" ]]; then
		die "task not ready for merge (status: $status). Run: orchd check $task_id"
	fi

	if [[ "$status" == "done" ]]; then
		if ! verify_merge_accepts_task "$task_id"; then
			if [[ "${VERIFY_MERGE_REVIEW_REQUIRED:-false}" == "true" ]]; then
				_merge_try_auto_review "$task_id" || true
				verify_merge_accepts_task "$task_id" || true
			fi
		fi
		if ! verify_merge_accepts_task "$task_id"; then
			local merge_gate_reason="$VERIFY_MERGE_REASON"
			if [[ -n "${MERGE_AUTO_REVIEW_REASON:-}" ]]; then
				merge_gate_reason+="; ${MERGE_AUTO_REVIEW_REASON}"
			fi
			task_set "$task_id" "merge_gate_status" "blocked"
			task_set "$task_id" "merge_gate_reason" "$merge_gate_reason"
			task_set "$task_id" "merge_required_verification_tier" "$VERIFY_MERGE_REQUIRED_TIER"
			die "task not ready for merge: $merge_gate_reason"
		fi
		task_set "$task_id" "merge_gate_status" "ready"
		task_set "$task_id" "merge_gate_reason" "$VERIFY_MERGE_REASON"
		task_set "$task_id" "merge_required_verification_tier" "$VERIFY_MERGE_REQUIRED_TIER"
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

	if ! git -C "$PROJECT_ROOT" checkout "$base_branch" >/dev/null 2>&1; then
		die "failed to checkout base branch: $base_branch"
	fi

	# Only stage memory into the merge commit if docs/memory has no tracked changes.
	# Untracked memory scaffold files (common right after `orchd memory init`) are OK.
	local memory_clean=true
	if [[ -n "$(git -C "$PROJECT_ROOT" status --porcelain --untracked-files=no -- docs/memory 2>/dev/null || true)" ]]; then
		memory_clean=false
	fi

	# If task is in conflict state, it may have been merged manually already.
	if [[ "$status" == "conflict" ]]; then
		if git -C "$PROJECT_ROOT" rev-parse --verify "$branch" >/dev/null 2>&1; then
			if git -C "$PROJECT_ROOT" merge-base --is-ancestor "$branch" "$base_branch" >/dev/null 2>&1; then
				task_set "$task_id" "status" "merged"
				task_set "$task_id" "merged_at" "$(now_iso)"
				printf 'already merged (manual conflict resolution detected): %s\n' "$task_id"
				log_event "INFO" "task merged (manual resolution): $task_id ($branch -> $base_branch)"
				local worktree
				worktree=$(task_get "$task_id" "worktree" "")
				if [[ -n "$worktree" ]] && [[ -d "$worktree" ]]; then
					worktree_remove "$PROJECT_ROOT" "$worktree"
				fi
				return 0
			fi
		fi
		# Otherwise, try merging again below.
	fi

	# Perform the merge (no-commit so we can include memory updates in the merge commit)
	if ! git -C "$PROJECT_ROOT" merge --no-ff --no-commit "$branch" >/dev/null 2>&1; then
		# Auto-resolve conflicts caused only by TASK_REPORT.md (local evidence artifact).
		local conflict_list
		conflict_list=$(git -C "$PROJECT_ROOT" diff --name-only --diff-filter=U 2>/dev/null || true)
		local conflict_count
		conflict_count=$(printf '%s\n' "$conflict_list" | sed '/^$/d' | wc -l | tr -d '[:space:]')
		if [[ "$conflict_count" == "1" ]] && [[ "$conflict_list" == "TASK_REPORT.md" ]]; then
			printf 'auto-resolving TASK_REPORT.md conflict (keeping base version)\n'
			git -C "$PROJECT_ROOT" checkout --ours -- TASK_REPORT.md >/dev/null 2>&1 || true
			git -C "$PROJECT_ROOT" add TASK_REPORT.md >/dev/null 2>&1 || true
		else
			printf '\nmerge conflict detected!\n'
			printf 'resolve conflicts in %s, then run:\n' "$PROJECT_ROOT"
			printf '  git add . && git commit\n'
			printf '  orchd merge %s  (retry)\n' "$task_id"
			log_event "ERROR" "merge conflict: $task_id ($branch -> $base_branch)"
			task_set "$task_id" "status" "conflict"
			return 1
		fi
	fi

	# If the merge produced no changes (already up to date), don't attempt to create a new commit.
	if ! git -C "$PROJECT_ROOT" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
		task_set "$task_id" "status" "merged"
		task_set "$task_id" "merged_at" "$(now_iso)"
		printf 'already merged (no-op merge): %s\n' "$task_id"
		log_event "INFO" "task merged (no-op): $task_id ($branch -> $base_branch)"
		local worktree
		worktree=$(task_get "$task_id" "worktree" "")
		if [[ -n "$worktree" ]] && [[ -d "$worktree" ]]; then
			worktree_remove "$PROJECT_ROOT" "$worktree"
		fi
		return 0
	fi

	# Run post-merge regression before committing the merge.
	local test_cmd
	test_cmd=$(config_get "test_cmd" "")
	if [[ -n "$test_cmd" ]]; then
		printf 'running post-merge tests...\n'
		if (cd "$PROJECT_ROOT" && eval "$test_cmd" >/dev/null 2>&1); then
			printf '  [PASS] post-merge tests passed\n'
			log_event "INFO" "post-merge regression passed: $task_id"
		else
			printf '  [FAIL] post-merge tests failed!\n'
			printf '  merge aborted (no commit created)\n'
			log_event "ERROR" "post-merge regression failed: $task_id"
			git -C "$PROJECT_ROOT" merge --abort >/dev/null 2>&1 || true
			task_set "$task_id" "status" "failed"
			return 1
		fi
	fi

	# Update memory bank. Stage into the merge commit only if it's safe.
	memory_write_lesson "$task_id" || true
	memory_update_progress_override "$task_id" "merged" || true
	if $memory_clean; then
		git -C "$PROJECT_ROOT" add -A -- docs/memory >/dev/null 2>&1 || true
	else
		log_event "WARN" "memory: updated but not staged for $task_id (docs/memory has local changes)"
	fi

	# Finalize merge commit.
	if ! git -C "$PROJECT_ROOT" commit -m "merge: $task_id ($branch)" >/dev/null 2>&1; then
		printf '\nmerge applied but commit failed!\n'
		printf 'resolve in %s, then run:\n' "$PROJECT_ROOT"
		printf '  git status\n'
		printf '  git commit\n'
		log_event "ERROR" "merge commit failed: $task_id ($branch -> $base_branch)"
		task_set "$task_id" "status" "conflict"
		return 1
	fi

	task_set "$task_id" "status" "merged"
	task_set "$task_id" "merged_at" "$(now_iso)"

	# Memory updates were already staged into the merge commit above.

	printf 'merged: %s\n' "$task_id"
	log_event "INFO" "task merged: $task_id ($branch -> $base_branch)"

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
				if ! _merge_single "$task_id"; then
					printf 'stopping merge --all due to failure in task: %s\n' "$task_id"
					return 1
				fi
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
