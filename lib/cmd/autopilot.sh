#!/usr/bin/env bash
# lib/cmd/autopilot.sh - orchd autopilot command
# Fully autonomous loop: spawn -> wait -> check -> merge -> repeat
# Runs until all tasks reach a terminal state (merged/failed) or deadlock.

cmd_autopilot() {
	local mode="run"
	local poll_interval=""
	local continuous=false
	local engine_override=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		-h | --help)
			cat <<'EOF'
usage:
	 orchd autopilot [poll_seconds]
	 orchd autopilot --daemon [poll_seconds]
	 orchd autopilot --status
	 orchd autopilot --stop
	 orchd autopilot --logs

engine selection:
	 orchd autopilot                     # default: ai-orchestrated supervisor loop
	 orchd autopilot --ai-orchestrated   # explicit ai orchestrator mode
	 orchd autopilot --deterministic     # legacy deterministic spawn/check/merge loop

compatibility:
	 orchd autopilot --continuous [...]  # accepted; implicit in ai-orchestrated mode
	 orchd autopilot --daemon --continuous [poll_seconds]
EOF
			return 0
			;;
		--continuous)
			continuous=true
			shift
			;;
		--deterministic | --classic)
			engine_override="deterministic"
			shift
			;;
		--ai-orchestrated | --ai)
			engine_override="ai"
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

	local autopilot_engine="$engine_override"
	if [[ -z "$autopilot_engine" ]]; then
		autopilot_engine=$(config_get "orchestrator.autopilot_mode" "ai")
	fi
	autopilot_engine=$(printf '%s' "$autopilot_engine" | tr '[:upper:]' '[:lower:]')
	case "$autopilot_engine" in
	ai | ai-orchestrated | "")
		autopilot_engine="ai"
		;;
	deterministic | classic | legacy)
		autopilot_engine="deterministic"
		;;
	*)
		log_event "WARN" "autopilot: unknown orchestrator.autopilot_mode '$autopilot_engine', defaulting to ai"
		autopilot_engine="ai"
		;;
	esac

	if [[ "$autopilot_engine" == "ai" ]]; then
		_autopilot_delegate_ai "$mode" "$poll_interval" "$continuous"
		return $?
	fi
	_AUTOPILOT_SELECTED_ENGINE="$autopilot_engine"

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
	runner=$(swarm_select_runner_for_role "builder" "$(detect_runner)")
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
	printf '%s started\n' "$(_autopilot_mode_name)"
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

		_autopilot_collect_scheduler_state "$runner"

		local ts
		ts=$(now_iso)
		printf '[%s] tick #%d — pending:%d running:%d done:%d merged:%d split:%d failed:%d need:%d\n' \
			"$ts" "$iteration" "$AUTOPILOT_PENDING" "$AUTOPILOT_RUNNING" "$AUTOPILOT_DONE" "$AUTOPILOT_MERGED" "${AUTOPILOT_SPLIT:-0}" "$AUTOPILOT_FAILED" "$AUTOPILOT_NEEDS_INPUT"

		# --- Terminal: all tasks in final state ---
		# Note: `failed` is not terminal here because autopilot can retry failed tasks.
		if _autopilot_completion_eligible; then
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
					_autopilot_summary "$AUTOPILOT_MERGED" "$AUTOPILOT_FAILED" "$AUTOPILOT_CONFLICT" "$AUTOPILOT_NEEDS_INPUT"
					return 0
					;;
				3)
					# Fatal: no AI runner configured/available
					printf '  [FATAL] continuous mode requires an AI runner (codex/claude/opencode/aider)\n' >&2
					log_event "ERROR" "autopilot: continuous mode requires AI runner"
					return 1
					;;
				esac
			fi
			_autopilot_summary "$AUTOPILOT_MERGED" "$AUTOPILOT_FAILED" "$AUTOPILOT_CONFLICT" "$AUTOPILOT_NEEDS_INPUT"
			return 0
		fi

		local next_action
		_autopilot_next_action >/dev/null
		next_action="$SCHEDULER_ACTION"
		scheduler_record_decision "autopilot" "$next_action" "$SCHEDULER_REASON"
		log_event "INFO" "autopilot scheduler: action=$next_action reason=$SCHEDULER_REASON"
		printf '  next action: %s — %s\n' "$next_action" "$SCHEDULER_REASON"

		case "$next_action" in
		merge)
			_autopilot_merge_done
			continue
			;;
		check)
			_autopilot_check_finished
			continue
			;;
		spawn)
			_autopilot_spawn_ready "$runner"
			continue
			;;
		recover)
			_autopilot_retry_failed "$runner"
			continue
			;;
		blocked)
			_autopilot_summary "$AUTOPILOT_MERGED" "$AUTOPILOT_FAILED" "$AUTOPILOT_CONFLICT" "$AUTOPILOT_NEEDS_INPUT"
			return 0
			;;
		wait)
			if _autopilot_detect_deadlock; then
				return 1
			fi
			;;
		esac

		# --- Sleep ---
		printf '  waiting %ss...\n\n' "$poll_interval"
		sleep "$poll_interval"
	done
}

cmd_finish() {
	ORCHD_AUTOPILOT_PROFILE="finish"
	export ORCHD_AUTOPILOT_PROFILE
	cmd_autopilot --deterministic --continuous "$@"
}

_autopilot_collect_scheduler_state() {
	local runner=${1:-}
	AUTOPILOT_TOTAL=0
	AUTOPILOT_PENDING=0
	AUTOPILOT_RUNNING=0
	AUTOPILOT_DONE=0
	AUTOPILOT_MERGED=0
	AUTOPILOT_SPLIT=0
	AUTOPILOT_FAILED=0
	AUTOPILOT_CONFLICT=0
	AUTOPILOT_NEEDS_INPUT=0
	AUTOPILOT_READY_MERGE=0
	AUTOPILOT_READY_CHECK=0
	AUTOPILOT_READY_SPAWN=0
	AUTOPILOT_READY_RECOVER=0

	local task_id status
	while IFS= read -r task_id; do
		[[ -z "$task_id" ]] && continue
		AUTOPILOT_TOTAL=$((AUTOPILOT_TOTAL + 1))
		task_runtime_refresh "$task_id"
		status="$TASK_RUNTIME_STATUS"
		case "$status" in
		pending)
			AUTOPILOT_PENDING=$((AUTOPILOT_PENDING + 1))
			if task_is_ready "$task_id"; then
				AUTOPILOT_READY_SPAWN=$((AUTOPILOT_READY_SPAWN + 1))
			fi
			;;
		running)
			if [[ "$TASK_RUNTIME_AGENT_ALIVE" == "true" ]]; then
				AUTOPILOT_RUNNING=$((AUTOPILOT_RUNNING + 1))
			else
				AUTOPILOT_READY_CHECK=$((AUTOPILOT_READY_CHECK + 1))
			fi
			;;
		done)
			AUTOPILOT_DONE=$((AUTOPILOT_DONE + 1))
			if _deps_all_merged "$task_id"; then
				AUTOPILOT_READY_MERGE=$((AUTOPILOT_READY_MERGE + 1))
			fi
			;;
		merged)
			AUTOPILOT_MERGED=$((AUTOPILOT_MERGED + 1))
			;;
		split)
			AUTOPILOT_SPLIT=$((AUTOPILOT_SPLIT + 1))
			;;
		failed)
			AUTOPILOT_FAILED=$((AUTOPILOT_FAILED + 1))
			AUTOPILOT_READY_RECOVER=$((AUTOPILOT_READY_RECOVER + 1))
			;;
		conflict)
			AUTOPILOT_CONFLICT=$((AUTOPILOT_CONFLICT + 1))
			AUTOPILOT_READY_RECOVER=$((AUTOPILOT_READY_RECOVER + 1))
			;;
		needs_input)
			AUTOPILOT_NEEDS_INPUT=$((AUTOPILOT_NEEDS_INPUT + 1))
			;;
		esac
	done <<<"$(task_list_ids)"
}

_autopilot_completion_eligible() {
	if ((AUTOPILOT_TOTAL <= 0)); then
		return 1
	fi
	((${AUTOPILOT_MERGED:-0} + ${AUTOPILOT_SPLIT:-0} + ${AUTOPILOT_NEEDS_INPUT:-0} >= AUTOPILOT_TOTAL))
}

_autopilot_blocked_only() {
	if ((AUTOPILOT_NEEDS_INPUT <= 0)); then
		return 1
	fi
	if ((AUTOPILOT_PENDING > 0 || AUTOPILOT_RUNNING > 0 || AUTOPILOT_DONE > 0)); then
		return 1
	fi
	if ((AUTOPILOT_READY_MERGE > 0 || AUTOPILOT_READY_CHECK > 0 || AUTOPILOT_READY_SPAWN > 0 || AUTOPILOT_READY_RECOVER > 0)); then
		return 1
	fi
	if ((AUTOPILOT_FAILED > 0 || AUTOPILOT_CONFLICT > 0)); then
		return 1
	fi
	return 0
}

_autopilot_next_action() {
	local blocked_only=false
	local completion_eligible=false
	if _autopilot_blocked_only; then
		blocked_only=true
	fi
	if _autopilot_completion_eligible; then
		completion_eligible=true
	fi
	scheduler_next_action \
		"$AUTOPILOT_READY_MERGE" \
		"$AUTOPILOT_READY_CHECK" \
		"$AUTOPILOT_READY_SPAWN" \
		"$AUTOPILOT_READY_RECOVER" \
		0 \
		"$blocked_only" \
		"$completion_eligible"
}

_autopilot_delegate_ai() {
	local mode=$1
	local poll_interval=$2
	local continuous=$3

	if [[ "$continuous" == "true" ]]; then
		printf 'note: --continuous is implicit in ai-orchestrated autopilot mode\n'
	fi

	case "$mode" in
	status)
		cmd_orchestrate --status
		;;
	stop)
		cmd_orchestrate --stop
		;;
	logs)
		cmd_orchestrate --logs
		;;
	daemon)
		if [[ -n "$poll_interval" ]]; then
			cmd_orchestrate --daemon "$poll_interval"
		else
			cmd_orchestrate --daemon
		fi
		;;
	run)
		if [[ -n "$poll_interval" ]]; then
			cmd_orchestrate "$poll_interval"
		else
			cmd_orchestrate
		fi
		;;
	*)
		die "unsupported autopilot mode: $mode"
		;;
	esac
}

_autopilot_pid_file() {
	printf '%s/%s.pid\n' "$ORCHD_DIR" "$(_autopilot_mode_name)"
}

_autopilot_log_file() {
	printf '%s/%s.log\n' "$ORCHD_DIR" "$(_autopilot_mode_name)"
}

_autopilot_mode_name() {
	printf '%s\n' "${ORCHD_AUTOPILOT_PROFILE:-autopilot}"
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
	local mode_name
	mode_name=$(_autopilot_mode_name)
	pid_file=$(_autopilot_pid_file)
	if _autopilot_is_running; then
		local pid
		pid=$(cat "$pid_file" 2>/dev/null || true)
		printf '%s daemon: running (pid %s)\n' "$mode_name" "$pid"
		printf 'log: %s\n' "$(_autopilot_log_file)"
		return 0
	fi
	if [[ -f "$pid_file" ]]; then
		printf '%s daemon: not running (stale pid file)\n' "$mode_name"
	else
		printf '%s daemon: not running\n' "$mode_name"
	fi
	return 1
}

_autopilot_stop() {
	local pid_file
	local mode_name
	mode_name=$(_autopilot_mode_name)
	pid_file=$(_autopilot_pid_file)
	if ! [[ -f "$pid_file" ]]; then
		printf '%s daemon: not running\n' "$mode_name"
		return 0
	fi
	local pid
	pid=$(cat "$pid_file" 2>/dev/null || true)
	if [[ -z "$pid" ]]; then
		rm -f "$pid_file"
		printf '%s daemon: pid file removed\n' "$mode_name"
		return 0
	fi
	if kill -0 "$pid" >/dev/null 2>&1; then
		kill "$pid" >/dev/null 2>&1 || true
		printf '%s daemon: stopped (pid %s)\n' "$mode_name" "$pid"
	else
		printf '%s daemon: not running (stale pid %s)\n' "$mode_name" "$pid"
	fi
	rm -f "$pid_file"
}

_autopilot_logs() {
	local log_file
	local mode_name
	mode_name=$(_autopilot_mode_name)
	log_file=$(_autopilot_log_file)
	if [[ ! -f "$log_file" ]]; then
		printf '%s log not found: %s\n' "$mode_name" "$log_file"
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
	if [[ "$(_autopilot_mode_name)" == "finish" ]]; then
		args="finish"
	fi
	if [[ "${_AUTOPILOT_SELECTED_ENGINE:-}" == "deterministic" ]]; then
		args+=" --deterministic"
	fi
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
	printf '%s daemon started (pid %s)\n' "$(_autopilot_mode_name)" "$pid"
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
		# Return 3 for fatal "no runner" to distinguish from transient failures
		return 3
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
		task_runtime_refresh "$task_id"
		status="$TASK_RUNTIME_STATUS"
		[[ "$status" == "running" ]] || continue

		if [[ "$TASK_RUNTIME_AGENT_ALIVE" != "true" ]]; then
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
		[[ "$status" == "failed" || "$status" == "conflict" ]] || continue

		local failure_class recovery_policy resume_reason
		failure_class=$(task_get "$task_id" "failure_class" "")
		if [[ -z "$failure_class" ]]; then
			failure_class=$(recovery_classify_failure "$task_id" "$(task_get "$task_id" "failure_check_file" "")")
			recovery_task_update_state "$task_id" "$failure_class" "$(task_get "$task_id" "failure_check_file" "")"
		fi
		recovery_policy=$(task_get "$task_id" "recovery_policy" "")
		if [[ -z "$recovery_policy" ]]; then
			recovery_policy_for_class "$task_id" "$failure_class" >/dev/null
			task_set "$task_id" "recovery_policy" "$RECOVERY_POLICY"
			task_set "$task_id" "recovery_next_action" "$RECOVERY_NEXT_ACTION"
			task_set "$task_id" "recovery_policy_reason" "$RECOVERY_POLICY_REASON"
			recovery_policy="$RECOVERY_POLICY"
		fi

		if ! recovery_policy_allows_auto_retry "$recovery_policy"; then
			task_mark_needs_input "$task_id" "system" "Recovery policy requires human input" "$failure_class" "Investigate the failure and decide how to continue" "true"
			recovery_task_update_state "$task_id" "needs_input" "$(task_get "$task_id" "failure_check_file" "")"
			log_event "WARN" "autopilot: $task_id needs_input (policy=$recovery_policy class=$failure_class)"
			continue
		fi

		# If no AI runner is available, we cannot retry; mark as needs_input.
		if [[ "$runner" == "none" ]]; then
			task_mark_needs_input "$task_id" "system" "No AI runner available for retry" "no_runner" "Install/configure a supported runner and retry" "true"
			recovery_task_update_state "$task_id" "needs_input" "$(task_get "$task_id" "failure_check_file" "")"
			log_event "WARN" "autopilot: $task_id needs_input (no runner available to retry)"
			continue
		fi

		if [[ "$recovery_policy" == "replan_split" ]]; then
			task_set "$task_id" "last_retry_epoch" "$now_epoch"
			printf '  replanning: %s (policy=%s)\n' "$task_id" "$recovery_policy"
			if _autopilot_replan_split_task "$task_id"; then
				continue
			fi
			log_event "WARN" "autopilot: split replan failed for $task_id; leaving task failed"
			continue
		fi

		local worktree
		worktree=$(task_get "$task_id" "worktree" "")
		if [[ -z "$worktree" ]] || [[ ! -d "$worktree" ]]; then
			# Can't retry without a worktree
			task_mark_needs_input "$task_id" "system" "Task worktree is missing" "missing_worktree" "Recreate worktree and resume task" "true"
			recovery_task_update_state "$task_id" "needs_input" "$(task_get "$task_id" "failure_check_file" "")"
			log_event "WARN" "autopilot: $task_id needs_input (missing worktree)"
			continue
		fi

		needs_input_detect "$worktree"
		if [[ "$ORCHD_NEEDS_INPUT_PRESENT" == "true" ]]; then
			task_mark_needs_input "$task_id" "$ORCHD_NEEDS_INPUT_SOURCE" "$ORCHD_NEEDS_INPUT_SUMMARY" "$ORCHD_NEEDS_INPUT_CODE" "$ORCHD_NEEDS_INPUT_QUESTION" "$ORCHD_NEEDS_INPUT_BLOCKING" "$ORCHD_NEEDS_INPUT_OPTIONS" "$ORCHD_NEEDS_INPUT_FILE"
			task_set "$task_id" "needs_input_error" "$ORCHD_NEEDS_INPUT_ERROR"
			recovery_task_update_state "$task_id" "needs_input" "$(task_get "$task_id" "failure_check_file" "")"
			log_event "WARN" "autopilot: $task_id needs_input (.orchd_needs_input artifact)"
			continue
		fi

		local attempts
		attempts=$(task_get "$task_id" "attempts" "0")
		if ! [[ "$attempts" =~ ^[0-9]+$ ]]; then
			attempts=0
		fi

		if ((attempts >= retry_limit)); then
			task_mark_needs_input "$task_id" "system" "Retry limit exhausted" "retries_exhausted" "Investigate failure and resume manually" "true"
			recovery_task_update_state "$task_id" "needs_input" "$(task_get "$task_id" "failure_check_file" "")"
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
		resume_reason=$(recovery_resume_reason_for_task "$task_id")
		printf '  retrying: %s (attempt %d/%d, class=%s, policy=%s)\n' "$task_id" $((attempts + 1)) "$retry_limit" "$failure_class" "$recovery_policy"
		(_resume_single "$task_id" "$resume_reason" 2>&1) | sed 's/^/    /' || true
	done <<<"$(task_list_ids)"
}

_autopilot_replan_split_task() {
	local task_id=$1
	local title description acceptance failure_class failure_summary prefix prompt_desc split_children original_deps leaf_children
	title=$(task_get "$task_id" "title" "$task_id")
	description=$(task_get "$task_id" "description" "")
	acceptance=$(task_get "$task_id" "acceptance" "")
	failure_class=$(task_get "$task_id" "failure_class" "scope_confusion")
	failure_summary=$(task_get "$task_id" "failure_summary" "")
	original_deps=$(task_get "$task_id" "deps" "")
	prefix="${task_id}-"
	prompt_desc=$(
		cat <<EOF
Split one failed orchd task into 2-4 smaller dependency-safe tasks.

Original task id: $task_id
Title: $title
Description: $description
Acceptance: $acceptance
Original upstream deps: ${original_deps:-none}
Failure class: $failure_class
Failure summary: $failure_summary

Requirements:
- Output only the standard TASK/TITLE/ROLE/DEPS/DESCRIPTION/ACCEPTANCE plan format.
- Keep the same end-user goal, but reduce scope per task.
- Prefer linear or lightly parallel subtasks with clear boundaries.
- Avoid broad umbrella tasks.
- Any split task that can start immediately must preserve the original upstream deps.
- Never depend on the original task id; use only the new split task ids or existing external deps.
- Reference existing repo reality; do not invent unrelated work.
EOF
	)

	if (cmd_plan --append --prefix "$prefix" "$prompt_desc" >/dev/null 2>&1); then
		split_children=$(task_list_ids | grep "^${prefix}" | paste -sd ',' - || true)
		_autopilot_split_preserve_upstream_deps "$task_id" "$original_deps" "$split_children"
		leaf_children=$(_autopilot_split_rewire_dependents "$task_id" "$split_children")
		task_set "$task_id" "status" "split"
		task_set "$task_id" "split_at" "$(now_iso)"
		task_set "$task_id" "split_children" "$split_children"
		task_set "$task_id" "split_reason" "$failure_summary"
		task_set "$task_id" "last_failure_reason" "split_into_subtasks"
		log_event "INFO" "autopilot: task split into follow-up tasks $task_id -> ${split_children:-unknown} (downstream now waits on ${leaf_children:-none})"
		return 0
	fi
	return 1
}

_autopilot_csv_contains() {
	local csv=$1
	local needle=$2
	local item cleaned
	while IFS=',' read -r -a csv_arr; do
		for item in "${csv_arr[@]}"; do
			cleaned=$(printf '%s' "$item" | tr -d '[:space:]')
			[[ -n "$cleaned" ]] || continue
			[[ "$cleaned" == "$needle" ]] && return 0
		done
	done <<<"$csv"
	return 1
}

_autopilot_csv_add_unique() {
	local merged="" raw item cleaned
	for raw in "$@"; do
		while IFS=',' read -r -a csv_arr; do
			for item in "${csv_arr[@]}"; do
				cleaned=$(printf '%s' "$item" | tr -d '[:space:]')
				[[ -n "$cleaned" ]] || continue
				if _autopilot_csv_contains "$merged" "$cleaned"; then
					continue
				fi
				if [[ -n "$merged" ]]; then
					merged+=","
				fi
				merged+="$cleaned"
			done
		done <<<"$raw"
	done
	printf '%s\n' "$merged"
}

_autopilot_csv_replace_target() {
	local csv=$1
	local target=$2
	local replacement_csv=$3
	local rewritten="" item cleaned
	while IFS=',' read -r -a csv_arr; do
		for item in "${csv_arr[@]}"; do
			cleaned=$(printf '%s' "$item" | tr -d '[:space:]')
			[[ -n "$cleaned" ]] || continue
			if [[ "$cleaned" == "$target" ]]; then
				rewritten=$(_autopilot_csv_add_unique "$rewritten" "$replacement_csv")
			else
				rewritten=$(_autopilot_csv_add_unique "$rewritten" "$cleaned")
			fi
		done
	done <<<"$csv"
	printf '%s\n' "$rewritten"
}

_autopilot_split_has_internal_dep() {
	local deps=$1
	local split_children=$2
	local dep cleaned
	while IFS=',' read -r -a dep_arr; do
		for dep in "${dep_arr[@]}"; do
			cleaned=$(printf '%s' "$dep" | tr -d '[:space:]')
			[[ -n "$cleaned" ]] || continue
			if _autopilot_csv_contains "$split_children" "$cleaned"; then
				return 0
			fi
		done
	done <<<"$deps"
	return 1
}

_autopilot_split_leaf_children() {
	local split_children=$1
	local leaf_children="" child other deps
	while IFS=',' read -r -a child_arr; do
		for child in "${child_arr[@]}"; do
			child=$(printf '%s' "$child" | tr -d '[:space:]')
			[[ -n "$child" ]] || continue
			local is_leaf=true
			while IFS=',' read -r -a other_arr; do
				for other in "${other_arr[@]}"; do
					other=$(printf '%s' "$other" | tr -d '[:space:]')
					[[ -n "$other" && "$other" != "$child" ]] || continue
					deps=$(task_get "$other" "deps" "")
					if _autopilot_csv_contains "$deps" "$child"; then
						is_leaf=false
						break
					fi
				done
				$is_leaf || break
			done <<<"$split_children"
			if $is_leaf; then
				leaf_children=$(_autopilot_csv_add_unique "$leaf_children" "$child")
			fi
		done
	done <<<"$split_children"
	printf '%s\n' "$leaf_children"
}

_autopilot_split_preserve_upstream_deps() {
	local task_id=$1
	local original_deps=$2
	local split_children=$3
	local child deps rewritten

	[[ -n "$split_children" ]] || return 0

	while IFS=',' read -r -a child_arr; do
		for child in "${child_arr[@]}"; do
			child=$(printf '%s' "$child" | tr -d '[:space:]')
			[[ -n "$child" ]] || continue
			deps=$(task_get "$child" "deps" "")
			rewritten=$(_autopilot_csv_replace_target "$deps" "$task_id" "$original_deps")
			if [[ -n "$original_deps" ]] && ! _autopilot_split_has_internal_dep "$rewritten" "$split_children"; then
				rewritten=$(_autopilot_csv_add_unique "$rewritten" "$original_deps")
			fi
			task_set "$child" "deps" "$rewritten"
		done
	done <<<"$split_children"
}

_autopilot_split_rewire_dependents() {
	local task_id=$1
	local split_children=$2
	local leaf_children dependent deps rewritten

	leaf_children=$(_autopilot_split_leaf_children "$split_children")
	[[ -n "$leaf_children" ]] || leaf_children="$split_children"

	while IFS= read -r dependent; do
		[[ -n "$dependent" && "$dependent" != "$task_id" ]] || continue
		if _autopilot_csv_contains "$split_children" "$dependent"; then
			continue
		fi
		deps=$(task_get "$dependent" "deps" "")
		[[ -n "$deps" ]] || continue
		if ! _autopilot_csv_contains "$deps" "$task_id"; then
			continue
		fi
		rewritten=$(_autopilot_csv_replace_target "$deps" "$task_id" "$leaf_children")
		task_set "$dependent" "deps" "$rewritten"
	done <<<"$(task_list_ids)"

	printf '%s\n' "$leaf_children"
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
		task_runtime_refresh "$task_id"
		status="$TASK_RUNTIME_STATUS"
		case "$status" in
		pending) pending=$((pending + 1)) ;;
		running)
			if [[ "$TASK_RUNTIME_AGENT_ALIVE" == "true" ]]; then
				running=$((running + 1))
			fi
			;;
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
		task_runtime_refresh "$task_id"
		status="$TASK_RUNTIME_STATUS"
		case "$status" in
		running)
			if [[ "$TASK_RUNTIME_AGENT_ALIVE" == "true" ]]; then
				running=$((running + 1))
			fi
			;;
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
				local deps code summary question options blocker_dep blocker_status split_children
				code="dependency_deadlock"
				summary="Dependency deadlock detected"
				question="Resolve dependency chain and resume"
				options=""
				if task_dependency_blocker "$task_id"; then
					blocker_dep="$TASK_DEPENDENCY_BLOCKER_ID"
					blocker_status="$TASK_DEPENDENCY_BLOCKER_STATUS"
					if [[ "$blocker_status" == "split" ]]; then
						split_children=$(task_get "$blocker_dep" "split_children" "")
						code="split_dependency"
						summary="Dependency references split task: ${blocker_dep}"
						question="Replace dependency ${blocker_dep} with its split child tasks and resume"
						options="$split_children"
					fi
				fi
				task_mark_needs_input "$task_id" "system" "$summary" "$code" "$question" "true" "$options"
				local deps
				deps=$(task_get "$task_id" "deps" "")
				printf '  deadlock: %s -> needs_input (deps: %s)\n' "$task_id" "$deps"
				log_event "WARN" "deadlock: $task_id marked needs_input (code=$code deps: $deps)"
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

	local active_task_count=0
	local tid status
	while IFS= read -r tid; do
		[[ -z "$tid" ]] && continue
		task_runtime_refresh "$tid"
		status="$TASK_RUNTIME_STATUS"
		case "$status" in
		pending) active_task_count=$((active_task_count + 1)) ;;
		running)
			if [[ "$TASK_RUNTIME_AGENT_ALIVE" == "true" ]]; then
				active_task_count=$((active_task_count + 1))
			fi
			;;
		esac
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

	# If active tasks exist, we are at the end of a cycle; mark the current in-progress idea
	# complete before moving on.
	if ((active_task_count > 0)); then
		queue_complete_current
	fi

	# If there is an in-progress idea and no active tasks exist, we likely failed while planning.
	# Retry planning the same idea without mutating queue state.
	if ((active_task_count == 0)) && ((in_progress > 0)); then
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
	local mode_name
	mode_name=$(_autopilot_mode_name)
	local split_count=${AUTOPILOT_SPLIT:-0}

	printf '\n'
	printf '┌─────────────────────────────────────┐\n'
	printf '│        %-28s│\n' "${mode_name} complete"
	printf '├─────────────────────────────────────┤\n'
	printf '│  merged:   %-4d                      │\n' "$merged"
	if ((split_count > 0)); then
		printf '│  split:    %-4d                      │\n' "$split_count"
	fi
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
