#!/usr/bin/env bash
# lib/cmd/autopilot.sh - orchd autopilot command
# Fully autonomous loop: spawn -> wait -> check -> merge -> repeat
# Runs until all tasks reach a terminal state (merged/failed) or deadlock.

cmd_autopilot() {
	local poll_interval="${1:-}"

	require_project

	local runner
	runner=$(detect_runner)
	# Runner is required only if we need to spawn pending tasks.
	# Allow merge-only/check-only autopilot runs without an AI runner installed.
	if [[ "$runner" != "none" ]]; then
		runner_validate "$runner"
	fi

	# Poll interval: arg > config > default 30s
	if [[ -z "$poll_interval" ]]; then
		poll_interval=$(config_get "autopilot_poll" "30")
	fi
	if ! [[ "$poll_interval" =~ ^[0-9]+$ ]]; then
		die "poll interval must be integer seconds: $poll_interval"
	fi

	# Verify tasks exist
	local task_count=0
	local tid
	while IFS= read -r tid; do
		[[ -z "$tid" ]] && continue
		task_count=$((task_count + 1))
	done <<<"$(task_list_ids)"

	if ((task_count == 0)); then
		die "no tasks found. Run: orchd plan \"<description>\" first"
	fi

	log_event "INFO" "autopilot started (poll=${poll_interval}s runner=$runner tasks=$task_count)"
	printf 'autopilot started\n'
	printf '  runner:   %s\n' "$runner"
	printf '  tasks:    %d\n' "$task_count"
	printf '  poll:     %ss\n' "$poll_interval"
	printf '  max_parallel: %s\n\n' "$(config_get "max_parallel" "3")"

	local iteration=0
	local max_iterations
	max_iterations=$(config_get "autopilot_max_iterations" "0")
	if ! [[ "$max_iterations" =~ ^[0-9]+$ ]]; then
		die "autopilot_max_iterations must be integer: $max_iterations"
	fi

	while true; do
		iteration=$((iteration + 1))
		if ((max_iterations > 0)) && ((iteration > max_iterations)); then
			printf 'autopilot reached iteration limit (%d), exiting\n' "$max_iterations"
			log_event "WARN" "autopilot iteration limit reached"
			return 1
		fi

		# --- Count current states ---
		local total=0 pending=0 running=0 done_count=0 merged=0 failed=0 conflict=0 needs_input=0
		local task_id status
		while IFS= read -r task_id; do
			[[ -z "$task_id" ]] && continue
			total=$((total + 1))
			status=$(task_status "$task_id")
			case "$status" in
			pending) pending=$((pending + 1)) ;;
			running) running=$((running + 1)) ;;
			done) done_count=$((done_count + 1)) ;;
			merged) merged=$((merged + 1)) ;;
			failed) failed=$((failed + 1)) ;;
			conflict) conflict=$((conflict + 1)) ;;
			needs_input) needs_input=$((needs_input + 1)) ;;
			esac
		done <<<"$(task_list_ids)"

		local ts
		ts=$(now_iso)
		printf '[%s] tick #%d — pending:%d running:%d done:%d merged:%d failed:%d need:%d\n' \
			"$ts" "$iteration" "$pending" "$running" "$done_count" "$merged" "$failed" "$needs_input"

		# --- Terminal: all tasks in final state ---
		# Note: `failed` is not terminal here because autopilot can retry failed tasks.
		if ((total > 0)) && ((merged + conflict + needs_input >= total)); then
			_autopilot_summary "$merged" "$failed" "$conflict" "$needs_input"
			return 0
		fi

		# --- Phase 1: Check running tasks whose agents have exited ---
		_autopilot_check_finished

		# --- Phase 2: Retry failed tasks (safe, bounded) ---
		_autopilot_retry_failed "$runner"

		# --- Phase 3: Merge done tasks (DAG order) ---
		_autopilot_merge_done

		# --- Phase 4: Spawn newly ready tasks ---
		_autopilot_spawn_ready "$runner"

		# --- Phase 5: Deadlock detection ---
		if _autopilot_detect_deadlock; then
			return 1
		fi

		# Re-check terminal state after actions to avoid an extra sleep.
		local total2=0 merged2=0 failed2=0 conflict2=0 needs2=0
		while IFS= read -r task_id; do
			[[ -z "$task_id" ]] && continue
			total2=$((total2 + 1))
			status=$(task_status "$task_id")
			case "$status" in
			merged) merged2=$((merged2 + 1)) ;;
			failed) failed2=$((failed2 + 1)) ;;
			conflict) conflict2=$((conflict2 + 1)) ;;
			needs_input) needs2=$((needs2 + 1)) ;;
			esac
		done <<<"$(task_list_ids)"
		if ((total2 > 0)) && ((merged2 + conflict2 + needs2 >= total2)); then
			_autopilot_summary "$merged2" "$failed2" "$conflict2" "$needs2"
			return 0
		fi

		# --- Sleep ---
		printf '  waiting %ss...\n\n' "$poll_interval"
		sleep "$poll_interval"
	done
}

# --- Phase 1: check finished agents ---
_autopilot_check_finished() {
	local task_id status
	while IFS= read -r task_id; do
		[[ -z "$task_id" ]] && continue
		status=$(task_status "$task_id")
		[[ "$status" == "running" ]] || continue

		if ! runner_is_alive "$task_id"; then
			printf '  agent exited: %s — checking...\n' "$task_id"
			# Run check in subshell to isolate die()
			(_check_single "$task_id" 2>&1) | sed 's/^/    /' || true
			status=$(task_status "$task_id")
			log_event "INFO" "autopilot: checked $task_id -> $status"
		fi
	done <<<"$(task_list_ids)"
}

# --- Phase 2: retry failed tasks (safe, bounded) ---

_autopilot_retry_failed() {
	local runner=${1:-}
	local retry_limit
	retry_limit=$(config_get "autopilot_retry_limit" "2")
	local base_backoff
	base_backoff=$(config_get "autopilot_retry_backoff" "60")

	if ! [[ "$retry_limit" =~ ^[0-9]+$ ]]; then
		retry_limit=2
	fi
	if ! [[ "$base_backoff" =~ ^[0-9]+$ ]]; then
		base_backoff=60
	fi

	local now_epoch
	now_epoch=$(date +%s)

	local task_id status
	while IFS= read -r task_id; do
		[[ -z "$task_id" ]] && continue
		status=$(task_status "$task_id")
		[[ "$status" == "failed" ]] || continue

		# If no AI runner is available, we cannot retry; mark as needs_input.
		if [[ "$runner" == "none" ]]; then
			task_set "$task_id" "status" "needs_input"
			task_set "$task_id" "needs_input_at" "$(now_iso)"
			task_set "$task_id" "last_failure_reason" "no_runner"
			log_event "WARN" "autopilot: $task_id needs_input (no runner available to retry)"
			continue
		fi

		local worktree
		worktree=$(task_get "$task_id" "worktree" "")
		if [[ -z "$worktree" ]] || [[ ! -d "$worktree" ]]; then
			# Can't retry without a worktree
			task_set "$task_id" "status" "needs_input"
			task_set "$task_id" "needs_input_at" "$(now_iso)"
			log_event "WARN" "autopilot: $task_id needs_input (missing worktree)"
			continue
		fi

		if [[ -f "$worktree/.orchd_needs_input.md" ]]; then
			task_set "$task_id" "status" "needs_input"
			task_set "$task_id" "needs_input_at" "$(now_iso)"
			log_event "WARN" "autopilot: $task_id needs_input (.orchd_needs_input.md)"
			continue
		fi

		local attempts
		attempts=$(task_get "$task_id" "attempts" "0")
		if ! [[ "$attempts" =~ ^[0-9]+$ ]]; then
			attempts=0
		fi

		if ((attempts >= retry_limit)); then
			task_set "$task_id" "status" "needs_input"
			task_set "$task_id" "needs_input_at" "$(now_iso)"
			task_set "$task_id" "last_failure_reason" "retries_exhausted"
			log_event "WARN" "autopilot: $task_id needs_input (retries exhausted: $attempts/$retry_limit)"
			continue
		fi

		local last_retry
		last_retry=$(task_get "$task_id" "last_retry_epoch" "0")
		if ! [[ "$last_retry" =~ ^[0-9]+$ ]]; then
			last_retry=0
		fi

		local backoff
		backoff=$((base_backoff * (1 << attempts)))
		if ((now_epoch - last_retry < backoff)); then
			continue
		fi

		task_set "$task_id" "last_retry_epoch" "$now_epoch"
		printf '  retrying: %s (attempt %d/%d)\n' "$task_id" $((attempts + 1)) "$retry_limit"
		(_resume_single "$task_id" "autopilot retry: quality gate failed" 2>&1) | sed 's/^/    /' || true
	done <<<"$(task_list_ids)"
}

# --- Phase 2: merge done tasks ---
_autopilot_merge_done() {
	local done_count=0
	local task_id status
	while IFS= read -r task_id; do
		[[ -z "$task_id" ]] && continue
		status=$(task_status "$task_id")
		[[ "$status" == "done" ]] && done_count=$((done_count + 1))
	done <<<"$(task_list_ids)"

	if ((done_count > 0)); then
		printf '  merging %d task(s)...\n' "$done_count"
		# Run in subshell to isolate die()
		(_merge_all_ready 2>&1) | sed 's/^/    /' || true
	fi
}

# --- Phase 3: spawn ready tasks ---
_autopilot_spawn_ready() {
	local runner=$1
	local pending=0 running=0
	local task_id status
	while IFS= read -r task_id; do
		[[ -z "$task_id" ]] && continue
		status=$(task_status "$task_id")
		case "$status" in
		pending) pending=$((pending + 1)) ;;
		running) running=$((running + 1)) ;;
		esac
	done <<<"$(task_list_ids)"

	local max_parallel
	max_parallel=$(config_get "max_parallel" "3")

	if ((pending > 0)) && ((running < max_parallel)); then
		if [[ "$runner" == "none" ]]; then
			die "no AI runner found/configured (needed to spawn pending tasks)"
		fi
		printf '  spawning ready tasks...\n'
		(_spawn_all_ready "$runner" 2>&1) | sed 's/^/    /' || true
	fi
}

# --- Phase 4: deadlock detection ---
# Returns 0 (true) if deadlocked, 1 (false) otherwise.
_autopilot_detect_deadlock() {
	local running=0 pending=0 has_spawnable=false
	local task_id status
	while IFS= read -r task_id; do
		[[ -z "$task_id" ]] && continue
		status=$(task_status "$task_id")
		case "$status" in
		running) running=$((running + 1)) ;;
		pending)
			pending=$((pending + 1))
			if task_is_ready "$task_id"; then
				has_spawnable=true
			fi
			;;
		esac
	done <<<"$(task_list_ids)"

	# Not deadlocked if agents are running or tasks are spawnable
	if ((running > 0)) || $has_spawnable; then
		return 1
	fi

	# No running agents and pending tasks exist but none are spawnable
	if ((pending > 0)); then
		printf '\n  deadlock: %d pending tasks with unsatisfiable dependencies\n' "$pending"
		log_event "ERROR" "autopilot deadlock: $pending tasks stuck"

		while IFS= read -r task_id; do
			[[ -z "$task_id" ]] && continue
			status=$(task_status "$task_id")
			if [[ "$status" == "pending" ]]; then
				task_set "$task_id" "status" "needs_input"
				task_set "$task_id" "needs_input_at" "$(now_iso)"
				local deps
				deps=$(task_get "$task_id" "deps" "")
				printf '  deadlock: %s -> needs_input (deps: %s)\n' "$task_id" "$deps"
				log_event "WARN" "deadlock: $task_id marked needs_input (deps: $deps)"
			fi
		done <<<"$(task_list_ids)"

		local merged=0 failed=0 conflict=0 needs_input=0
		while IFS= read -r task_id; do
			[[ -z "$task_id" ]] && continue
			status=$(task_status "$task_id")
			case "$status" in
			merged) merged=$((merged + 1)) ;;
			failed) failed=$((failed + 1)) ;;
			conflict) conflict=$((conflict + 1)) ;;
			needs_input) needs_input=$((needs_input + 1)) ;;
			esac
		done <<<"$(task_list_ids)"

		_autopilot_summary "$merged" "$failed" "$conflict" "$needs_input"
		return 0
	fi

	# Nothing pending, nothing running — should have been caught by terminal check
	return 1
}

# --- Final summary ---
_autopilot_summary() {
	local merged=$1 failed=$2 conflict=$3 needs_input=$4

	printf '\n'
	printf '┌─────────────────────────────────────┐\n'
	printf '│        autopilot complete            │\n'
	printf '├─────────────────────────────────────┤\n'
	printf '│  merged:   %-4d                      │\n' "$merged"
	printf '│  failed:   %-4d                      │\n' "$failed"
	if ((needs_input > 0)); then
		printf '│  need:     %-4d                      │\n' "$needs_input"
	fi
	if ((conflict > 0)); then
		printf '│  conflict: %-4d                      │\n' "$conflict"
	fi
	printf '└─────────────────────────────────────┘\n'

	if ((failed + conflict + needs_input > 0)); then
		log_event "WARN" "autopilot done: $merged merged, $failed failed, $conflict conflict, $needs_input needs_input"
	else
		log_event "INFO" "autopilot done: all $merged tasks merged successfully"
	fi
}
