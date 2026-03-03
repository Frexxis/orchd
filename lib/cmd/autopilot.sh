#!/usr/bin/env bash
# lib/cmd/autopilot.sh - orchd autopilot command
# Fully autonomous loop: spawn -> wait -> check -> merge -> repeat
# Runs until all tasks reach a terminal state (merged/failed) or deadlock.

cmd_autopilot() {
	local mode="run"
	local poll_interval=""
	local continuous=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		-h | --help)
			cat <<'EOF'
usage:
  orchd autopilot [poll_seconds]
  orchd autopilot --continuous [poll_seconds]
  orchd autopilot --daemon [poll_seconds]
  orchd autopilot --daemon --continuous [poll_seconds]
  orchd autopilot --status
  orchd autopilot --stop
  orchd autopilot --logs
EOF
			return 0
			;;
		--continuous)
			continuous=true
			shift
			;;
		--daemon | --start)
			mode="daemon"
			shift
			;;
		--status)
			mode="status"
			shift
			;;
		--stop)
			mode="stop"
			shift
			;;
		--logs)
			mode="logs"
			shift
			;;
		[0-9]*)
			poll_interval="$1"
			shift
			;;
		*)
			die "unknown autopilot argument: $1 (try: orchd autopilot --help)"
			;;
		esac
	done

	require_project

	case "$mode" in
	status)
		_autopilot_status
		return 0
		;;
	stop)
		_autopilot_stop
		return 0
		;;
	logs)
		_autopilot_logs
		return 0
		;;
	daemon)
		_autopilot_start_daemon "$poll_interval" "$continuous"
		return 0
		;;
	esac

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

	# Used via eval updates in _autopilot_ideate
	# shellcheck disable=SC2034
	local ideate_cycles=0
	# shellcheck disable=SC2034
	local ideate_failures=0
	local ideate_max_cycles
	ideate_max_cycles=$(config_get_int "ideate.max_cycles" "20")
	local ideate_cooldown
	ideate_cooldown=$(config_get_int "ideate.cooldown_seconds" "30")
	local ideate_max_failures
	ideate_max_failures=$(config_get_int "ideate.max_consecutive_failures" "3")

	# Verify tasks exist
	local task_count=0
	local tid
	while IFS= read -r tid; do
		[[ -z "$tid" ]] && continue
		task_count=$((task_count + 1))
	done <<<"$(task_list_ids)"

	# Allow queue-only autopilot startup: if there are no tasks yet, try
	# planning from the idea queue first.
	# In continuous mode, try ideation before queue drain.
	if ((task_count == 0)); then
		if $continuous; then
			local ideate_rc=0
			_autopilot_ideate "$runner" "$ideate_cooldown" "$ideate_max_cycles" "$ideate_max_failures" ideate_cycles ideate_failures || ideate_rc=$?
			if [[ "$ideate_rc" == "2" ]]; then
				log_event "INFO" "autopilot: ideate signaled PROJECT_COMPLETE (startup)"
				printf 'project complete (ideate)\n'
				return 0
			fi
		fi
		if _autopilot_drain_queue "$runner" "$poll_interval"; then
			while IFS= read -r tid; do
				[[ -z "$tid" ]] && continue
				task_count=$((task_count + 1))
			done <<<"$(task_list_ids)"
		fi
	fi

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
			# Check idea queue before exiting — continuous operation
			if _autopilot_drain_queue "$runner" "$poll_interval"; then
				# New tasks were created from the queue; restart the loop
				continue
			fi

			if $continuous; then
				local ideate_rc=0
				_autopilot_ideate "$runner" "$ideate_cooldown" "$ideate_max_cycles" "$ideate_max_failures" ideate_cycles ideate_failures || ideate_rc=$?
				case "$ideate_rc" in
				0)
					# New ideas were queued; plan them and continue.
					if _autopilot_drain_queue "$runner" "$poll_interval"; then
						continue
					fi
					;;
				1)
					printf '  ideate failed — waiting %ss before retry\n' "$poll_interval"
					sleep "$poll_interval"
					continue
					;;
				2)
					log_event "INFO" "autopilot: ideate signaled PROJECT_COMPLETE"
					_autopilot_summary "$merged" "$failed" "$conflict" "$needs_input"
					return 0
					;;
				esac
			fi
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
			# Check idea queue before exiting — continuous operation
			if _autopilot_drain_queue "$runner" "$poll_interval"; then
				continue
			fi

			if $continuous; then
				local ideate_rc=0
				_autopilot_ideate "$runner" "$ideate_cooldown" "$ideate_max_cycles" "$ideate_max_failures" ideate_cycles ideate_failures || ideate_rc=$?
				case "$ideate_rc" in
				0)
					if _autopilot_drain_queue "$runner" "$poll_interval"; then
						continue
					fi
					;;
				1)
					printf '  ideate failed — waiting %ss before retry\n' "$poll_interval"
					sleep "$poll_interval"
					continue
					;;
				2)
					log_event "INFO" "autopilot: ideate signaled PROJECT_COMPLETE"
					_autopilot_summary "$merged2" "$failed2" "$conflict2" "$needs2"
					return 0
					;;
				esac
			fi
			_autopilot_summary "$merged2" "$failed2" "$conflict2" "$needs2"
			return 0
		fi

		# --- Sleep ---
		printf '  waiting %ss...\n\n' "$poll_interval"
		sleep "$poll_interval"
	done
}

_autopilot_pid_file() {
	# shellcheck disable=SC2153
	printf '%s/autopilot.pid' "$ORCHD_DIR"
}

_autopilot_log_file() {
	# shellcheck disable=SC2153
	printf '%s/autopilot.log' "$ORCHD_DIR"
}

_autopilot_is_running() {
	local pid_file
	pid_file=$(_autopilot_pid_file)
	[[ -f "$pid_file" ]] || return 1
	local pid
	pid=$(cat "$pid_file" 2>/dev/null || true)
	[[ -n "$pid" ]] || return 1
	if kill -0 "$pid" >/dev/null 2>&1; then
		return 0
	fi
	return 1
}

_autopilot_status() {
	local pid_file
	pid_file=$(_autopilot_pid_file)
	if _autopilot_is_running; then
		local pid
		pid=$(cat "$pid_file" 2>/dev/null || true)
		printf 'autopilot daemon: running (pid %s)\n' "$pid"
		printf 'log: %s\n' "$(_autopilot_log_file)"
		return 0
	fi
	if [[ -f "$pid_file" ]]; then
		printf 'autopilot daemon: not running (stale pid file)\n'
	else
		printf 'autopilot daemon: not running\n'
	fi
	return 1
}

_autopilot_stop() {
	local pid_file
	pid_file=$(_autopilot_pid_file)
	if ! [[ -f "$pid_file" ]]; then
		printf 'autopilot daemon: not running\n'
		return 0
	fi
	local pid
	pid=$(cat "$pid_file" 2>/dev/null || true)
	if [[ -z "$pid" ]]; then
		rm -f "$pid_file"
		printf 'autopilot daemon: pid file removed\n'
		return 0
	fi
	if kill -0 "$pid" >/dev/null 2>&1; then
		kill "$pid" >/dev/null 2>&1 || true
		printf 'autopilot daemon: stopped (pid %s)\n' "$pid"
	else
		printf 'autopilot daemon: not running (stale pid %s)\n' "$pid"
	fi
	rm -f "$pid_file"
}

_autopilot_logs() {
	local log_file
	log_file=$(_autopilot_log_file)
	if [[ ! -f "$log_file" ]]; then
		printf 'autopilot log not found: %s\n' "$log_file"
		return 1
	fi
	tail -n 200 -f "$log_file"
}

_autopilot_start_daemon() {
	local poll_interval="$1"
	local continuous="${2:-false}"
	if _autopilot_is_running; then
		_autopilot_status
		return 0
	fi

	# Poll interval: arg > config > default 30s
	if [[ -z "$poll_interval" ]]; then
		poll_interval=$(config_get "autopilot_poll" "30")
	fi
	if ! [[ "$poll_interval" =~ ^[0-9]+$ ]]; then
		die "poll interval must be integer seconds: $poll_interval"
	fi

	local log_file pid_file
	log_file=$(_autopilot_log_file)
	pid_file=$(_autopilot_pid_file)

	[[ -n "${ORCHD_BIN:-}" ]] || die "ORCHD_BIN not set (internal error)"

	local args="autopilot"
	if [[ "$continuous" == "true" ]]; then
		args+=" --continuous"
	fi
	if [[ -n "$poll_interval" ]]; then
		args+=" $poll_interval"
	fi

	# shellcheck disable=SC2086
	nohup "$ORCHD_BIN" $args >"$log_file" 2>&1 &
	local pid=$!
	printf '%s\n' "$pid" >"$pid_file"
	printf 'autopilot daemon started (pid %s)\n' "$pid"
	printf 'log: %s\n' "$log_file"
}

_autopilot_ideate() {
	local runner=$1
	local cooldown=$2
	local max_cycles=$3
	local max_failures=$4
	local cycles_var=$5
	local failures_var=$6

	local cycles failures
	cycles=$(eval "printf '%s' \"\${$cycles_var:-0}\"" 2>/dev/null || printf '0')
	failures=$(eval "printf '%s' \"\${$failures_var:-0}\"" 2>/dev/null || printf '0')
	if ! [[ "$cycles" =~ ^[0-9]+$ ]]; then
		cycles=0
	fi
	if ! [[ "$failures" =~ ^[0-9]+$ ]]; then
		failures=0
	fi

	if [[ "$runner" == "none" ]]; then
		return 1
	fi

	if ((max_cycles > 0)) && ((cycles >= max_cycles)); then
		log_event "WARN" "autopilot: ideate max_cycles reached ($max_cycles)"
		return 1
	fi

	if ((cooldown > 0)); then
		printf '  ideate cooldown: waiting %ss...\n' "$cooldown"
		sleep "$cooldown"
	fi

	cycles=$((cycles + 1))
	eval "$cycles_var=\"$cycles\""
	printf '  ideate: generating next ideas (cycle %d)...\n' "$cycles"

	(
		set +e
		cmd_ideate
	)
	local rc=$?
	if ((rc != 0)); then
		if [[ "$rc" == "2" ]]; then
			failures=0
			eval "$failures_var=\"$failures\""
			return 2
		fi
		failures=$((failures + 1))
		eval "$failures_var=\"$failures\""
		log_event "WARN" "autopilot: ideate failed (rc=$rc failures=$failures)"
		if ((max_failures > 0)) && ((failures >= max_failures)); then
			die "ideate failed $failures times (max=$max_failures). Check $ORCHD_DIR/ideate_output.txt and $ORCHD_DIR/ideate_stderr.log"
		fi
		return 1
	fi

	failures=0
	eval "$failures_var=\"$failures\""
	return 0
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

# --- Queue drain: pick next idea and plan it ---
# Returns 0 if a new plan was created (caller should restart the loop).
# Returns 1 if no ideas remain or planning failed.
_autopilot_drain_queue() {
	local runner=$1
	local poll_interval=${2:-30}

	local task_count=0
	local tid
	while IFS= read -r tid; do
		[[ -z "$tid" ]] && continue
		task_count=$((task_count + 1))
	done <<<"$(task_list_ids)"

	local in_progress
	in_progress=$(queue_in_progress_count)

	local pending_ideas
	pending_ideas=$(queue_count)
	if ((pending_ideas == 0)) && ((in_progress == 0)); then
		return 1
	fi

	# Do not mutate queue state if we cannot plan.
	if [[ "$runner" == "none" ]]; then
		log_event "ERROR" "autopilot: cannot plan from queue — no runner available"
		return 1
	fi

	local idea=""

	# If tasks exist, we are at the end of a cycle; mark the current in-progress idea
	# complete before moving on.
	if ((task_count > 0)); then
		queue_complete_current
	fi

	# If there is an in-progress idea and no tasks exist, we likely failed while planning.
	# Retry planning the same idea without mutating queue state.
	if ((task_count == 0)) && ((in_progress > 0)); then
		idea=$(queue_current_in_progress 2>/dev/null || true)
		[[ -n "$idea" ]] || return 1
	else
		idea=$(queue_pop) || return 1
	fi

	local remaining
	remaining=$(queue_count)

	printf '\n'
	printf '┌─────────────────────────────────────┐\n'
	printf '│     idea queue: picking next idea    │\n'
	printf '├─────────────────────────────────────┤\n'
	printf '│  idea: %-29s │\n' "$(printf '%.29s' "$idea")"
	printf '│  remaining: %-24d │\n' "$remaining"
	printf '└─────────────────────────────────────┘\n'

	log_event "INFO" "autopilot: draining queue — planning idea: $idea"

	if (cmd_plan "$idea" 2>&1) | sed 's/^/  [plan] /'; then
		log_event "INFO" "autopilot: plan created from idea queue"
		printf '\n  new plan created — restarting autopilot loop\n\n'
		return 0
	else
		log_event "ERROR" "autopilot: plan failed for idea: $idea"
		printf '  [ERROR] plan generation failed for idea: %s\n' "$idea"
		printf '  will retry later (leaving queue item in-progress)\n\n'
		return 1
	fi
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
