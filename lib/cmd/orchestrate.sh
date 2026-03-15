#!/usr/bin/env bash
# lib/cmd/orchestrate.sh - supervised AI orchestrator loop

cmd_orchestrate() {
	local mode="run"
	local once=false
	local poll_interval=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		-h | --help)
			cat <<'EOF'
usage:
  orchd orchestrate [poll_seconds]
  orchd orchestrate --once
  orchd orchestrate --daemon [poll_seconds]
  orchd orchestrate --status
  orchd orchestrate --stop
  orchd orchestrate --logs

notes:
  - runs an AI orchestrator under supervisor control
  - automatically reinvokes the orchestrator with a system reminder until terminal state
  - waiting on workers is handled by the supervisor, not by the orchestrator agent itself
  - with opencode and session_mode=sticky, reminders are injected into the same live session
EOF
			return 0
			;;
		--once)
			once=true
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
			die "unknown orchestrate argument: $1 (try: orchd orchestrate --help)"
			;;
		esac
	done

	require_project
	_orchestrate_prepare_dir

	case "$mode" in
	status)
		_orchestrate_status
		return 0
		;;
	stop)
		_orchestrate_stop
		return 0
		;;
	logs)
		_orchestrate_logs
		return 0
		;;
	daemon)
		$once && die "orchd orchestrate --daemon does not support --once"
		_orchestrate_start_daemon "$poll_interval"
		return 0
		;;
	esac

	local runner
	runner=$(_orchestrate_detect_runner)
	runner_validate "$runner"

	if [[ -z "$poll_interval" ]]; then
		poll_interval=$(config_get "orchestrator.supervisor_poll" "")
		if [[ -z "$poll_interval" ]]; then
			poll_interval=$(config_get "autopilot_poll" "30")
		fi
	fi
	if ! [[ "$poll_interval" =~ ^[0-9]+$ ]]; then
		die "orchestrator poll interval must be integer seconds: $poll_interval"
	fi

	local continue_delay max_iterations max_stagnation
	continue_delay=$(config_get_int "orchestrator.continue_delay" "1")
	max_iterations=$(config_get_int "orchestrator.max_iterations" "0")
	max_stagnation=$(config_get_int "orchestrator.max_stagnation" "8")

	local session_mode idle_timeout reminder_cooldown max_reminders fallback_on_inject_failure
	session_mode=$(config_get "orchestrator.session_mode" "auto")
	idle_timeout=$(config_get_int "orchestrator.idle_timeout" "45")
	reminder_cooldown=$(config_get_int "orchestrator.reminder_cooldown" "20")
	max_reminders=$(config_get_int "orchestrator.max_reminders" "8")
	fallback_on_inject_failure=$(config_get "orchestrator.fallback_on_inject_failure" "true")

	rm -f "$(_orchestrate_stop_file)" 2>/dev/null || true
	if _orchestrate_use_sticky_session "$runner" "$session_mode" "$once"; then
		_orchestrate_loop_sticky "$runner" "$poll_interval" "$continue_delay" "$max_iterations" "$max_stagnation" "$idle_timeout" "$reminder_cooldown" "$max_reminders" "$fallback_on_inject_failure"
		local sticky_rc=$?
		if ((sticky_rc == 93)); then
			log_event "WARN" "sticky orchestrator loop requested fallback to classic supervisor loop"
			_orchestrate_loop "$runner" "$poll_interval" "$continue_delay" "$max_iterations" "$max_stagnation" "$once"
			return $?
		fi
		return $sticky_rc
	fi
	_orchestrate_loop "$runner" "$poll_interval" "$continue_delay" "$max_iterations" "$max_stagnation" "$once"
}

_orchestrate_detect_runner() {
	local configured
	configured=$(config_get "orchestrator.runner" "")
	if [[ -n "$configured" ]] && [[ "$configured" != "auto" ]]; then
		printf '%s\n' "$configured"
		return 0
	fi
	configured=$(config_get "worker.runner" "")
	if [[ -n "$configured" ]] && [[ "$configured" != "auto" ]]; then
		printf '%s\n' "$configured"
		return 0
	fi
	detect_runner
}

_orchestrate_state_dir() {
	printf '%s/orchestrator\n' "$ORCHD_DIR"
}

_orchestrate_iteration_dir() {
	printf '%s/iterations\n' "$(_orchestrate_state_dir)"
}

_orchestrate_log_file() {
	printf '%s/supervisor.log\n' "$(_orchestrate_state_dir)"
}

_orchestrate_pid_file() {
	printf '%s/supervisor.pid\n' "$(_orchestrate_state_dir)"
}

_orchestrate_stop_file() {
	printf '%s/stop\n' "$(_orchestrate_state_dir)"
}

_orchestrate_history_file() {
	printf '%s/history.log\n' "$(_orchestrate_state_dir)"
}

_orchestrate_session_name_file() {
	printf '%s/session_name\n' "$(_orchestrate_state_dir)"
}

_orchestrate_session_mode_file() {
	printf '%s/session_mode\n' "$(_orchestrate_state_dir)"
}

_orchestrate_use_sticky_session() {
	local runner=$1
	local session_mode=$2
	local once=$3

	[[ "$once" == "false" ]] || return 1

	local mode
	mode=$(printf '%s' "$session_mode" | tr '[:upper:]' '[:lower:]')
	case "$mode" in
	sticky)
		[[ "$runner" == "opencode" ]]
		;;
	auto | "")
		[[ "$runner" == "opencode" ]]
		;;
	classic | reinvoke | one-shot)
		return 1
		;;
	*)
		return 1
		;;
	esac
}

_orchestrate_prepare_dir() {
	mkdir -p "$(_orchestrate_state_dir)" "$(_orchestrate_iteration_dir)"
}

_orchestrate_is_running() {
	local pid_file pid
	pid_file=$(_orchestrate_pid_file)
	[[ -f "$pid_file" ]] || return 1
	pid=$(cat "$pid_file" 2>/dev/null || true)
	[[ -n "$pid" ]] || return 1
	kill -0 "$pid" >/dev/null 2>&1
}

_orchestrate_status() {
	if _orchestrate_is_running; then
		local pid
		pid=$(cat "$(_orchestrate_pid_file)" 2>/dev/null || true)
		printf 'orchestrator supervisor: running (pid %s)\n' "$pid"
		printf 'log: %s\n' "$(_orchestrate_log_file)"
		local sticky_session=""
		sticky_session=$(cat "$(_orchestrate_session_name_file)" 2>/dev/null || true)
		if [[ -n "$sticky_session" ]] && tmux has-session -t "$sticky_session" 2>/dev/null; then
			printf 'sticky session: %s\n' "$sticky_session"
		fi
		return 0
	fi
	if [[ -f "$(_orchestrate_pid_file)" ]]; then
		printf 'orchestrator supervisor: not running (stale pid file)\n'
	else
		printf 'orchestrator supervisor: not running\n'
	fi
	return 1
}

_orchestrate_stop() {
	_orchestrate_prepare_dir
	: >"$(_orchestrate_stop_file)"
	local sticky_session=""
	sticky_session=$(cat "$(_orchestrate_session_name_file)" 2>/dev/null || true)
	if [[ -n "$sticky_session" ]] && tmux has-session -t "$sticky_session" 2>/dev/null; then
		tmux kill-session -t "$sticky_session" >/dev/null 2>&1 || true
		printf 'orchestrator sticky session stopped (%s)\n' "$sticky_session"
	fi
	if _orchestrate_is_running; then
		local pid
		pid=$(cat "$(_orchestrate_pid_file)" 2>/dev/null || true)
		kill "$pid" >/dev/null 2>&1 || true
		printf 'orchestrator supervisor: stopped (pid %s)\n' "$pid"
	else
		printf 'orchestrator supervisor: not running\n'
	fi
	rm -f "$(_orchestrate_pid_file)"
}

_orchestrate_logs() {
	local log_file
	log_file=$(_orchestrate_log_file)
	if [[ ! -f "$log_file" ]]; then
		printf 'orchestrator log not found: %s\n' "$log_file"
		return 1
	fi
	tail -n 200 -f "$log_file"
}

_orchestrate_start_daemon() {
	local poll_interval="$1"
	if _orchestrate_is_running; then
		_orchestrate_status
		return 0
	fi

	if [[ -z "$poll_interval" ]]; then
		poll_interval=$(config_get "orchestrator.supervisor_poll" "")
		if [[ -z "$poll_interval" ]]; then
			poll_interval=$(config_get "autopilot_poll" "30")
		fi
	fi
	if ! [[ "$poll_interval" =~ ^[0-9]+$ ]]; then
		die "orchestrator poll interval must be integer seconds: $poll_interval"
	fi

	local log_file pid_file
	log_file=$(_orchestrate_log_file)
	pid_file=$(_orchestrate_pid_file)
	[[ -n "${ORCHD_BIN:-}" ]] || die "ORCHD_BIN not set (internal error)"

	nohup "$ORCHD_BIN" orchestrate "$poll_interval" >"$log_file" 2>&1 &
	local pid=$!
	printf '%s\n' "$pid" >"$pid_file"
	printf 'orchestrator supervisor started (pid %s)\n' "$pid"
	printf 'log: %s\n' "$log_file"
}

_orchestrate_history_append() {
	printf '[%s] %s\n' "$(now_iso)" "$*" >>"$(_orchestrate_history_file)"
}

_orchestrate_collect_state() {
	ORCH_STATE_TOTAL=0
	ORCH_STATE_PENDING=0
	ORCH_STATE_RUNNING=0
	ORCH_STATE_DONE=0
	ORCH_STATE_MERGED=0
	ORCH_STATE_FAILED=0
	ORCH_STATE_CONFLICT=0
	ORCH_STATE_NEEDS_INPUT=0
	ORCH_READY_SPAWN=0
	ORCH_READY_CHECK=0
	ORCH_READY_MERGE=0

	local task_id status
	while IFS= read -r task_id; do
		[[ -z "$task_id" ]] && continue
		ORCH_STATE_TOTAL=$((ORCH_STATE_TOTAL + 1))
		task_runtime_refresh "$task_id"
		status="$TASK_RUNTIME_STATUS"
		case "$status" in
		pending)
			ORCH_STATE_PENDING=$((ORCH_STATE_PENDING + 1))
			if task_is_ready "$task_id"; then
				ORCH_READY_SPAWN=$((ORCH_READY_SPAWN + 1))
			fi
			;;
		running)
			if [[ "$TASK_RUNTIME_AGENT_ALIVE" == "true" ]]; then
				ORCH_STATE_RUNNING=$((ORCH_STATE_RUNNING + 1))
			else
				ORCH_READY_CHECK=$((ORCH_READY_CHECK + 1))
			fi
			;;
		done)
			ORCH_STATE_DONE=$((ORCH_STATE_DONE + 1))
			if _deps_all_merged "$task_id"; then
				ORCH_READY_MERGE=$((ORCH_READY_MERGE + 1))
			fi
			;;
		merged)
			ORCH_STATE_MERGED=$((ORCH_STATE_MERGED + 1))
			;;
		failed)
			ORCH_STATE_FAILED=$((ORCH_STATE_FAILED + 1))
			;;
		conflict)
			ORCH_STATE_CONFLICT=$((ORCH_STATE_CONFLICT + 1))
			;;
		needs_input)
			ORCH_STATE_NEEDS_INPUT=$((ORCH_STATE_NEEDS_INPUT + 1))
			;;
		esac
	done <<<"$(task_list_ids)"

	ORCH_QUEUE_PENDING=$(queue_count)
	ORCH_QUEUE_IN_PROGRESS=$(queue_in_progress_count)
}

_orchestrate_state_summary() {
	printf 'tasks total=%d pending=%d running=%d done=%d merged=%d failed=%d conflict=%d needs_input=%d ready(spawn=%d check=%d merge=%d) ideas(pending=%d in_progress=%d)' \
		"$ORCH_STATE_TOTAL" "$ORCH_STATE_PENDING" "$ORCH_STATE_RUNNING" "$ORCH_STATE_DONE" "$ORCH_STATE_MERGED" \
		"$ORCH_STATE_FAILED" "$ORCH_STATE_CONFLICT" "$ORCH_STATE_NEEDS_INPUT" \
		"$ORCH_READY_SPAWN" "$ORCH_READY_CHECK" "$ORCH_READY_MERGE" \
		"$ORCH_QUEUE_PENDING" "$ORCH_QUEUE_IN_PROGRESS"
}

_orchestrate_completion_eligible() {
	if ((ORCH_STATE_PENDING > 0 || ORCH_STATE_RUNNING > 0 || ORCH_STATE_DONE > 0)); then
		return 1
	fi
	if ((ORCH_STATE_FAILED > 0 || ORCH_STATE_CONFLICT > 0 || ORCH_STATE_NEEDS_INPUT > 0)); then
		return 1
	fi
	if ((ORCH_READY_SPAWN > 0 || ORCH_READY_CHECK > 0 || ORCH_READY_MERGE > 0)); then
		return 1
	fi
	if ((ORCH_QUEUE_PENDING > 0 || ORCH_QUEUE_IN_PROGRESS > 0)); then
		return 1
	fi
	return 0
}

_orchestrate_passive_stop_detected() {
	local file=$1
	[[ -f "$file" ]] || return 1
	local tail_text pattern
	tail_text=$(tail -n 20 "$file" 2>/dev/null | tr '[:upper:]' '[:lower:]')
	for pattern in "let me know" "would you like" "shall i" "if you want" "do you want me to"; do
		if grep -Fq "$pattern" <<<"$tail_text"; then
			return 0
		fi
	done
	return 1
}

_orchestrate_parse_result() {
	local file=$1
	ORCHD_ORCH_RESULT="CONTINUE"
	ORCHD_ORCH_REASON="No explicit result found; continue orchestration."
	[[ -f "$file" ]] || return 0

	local result reason
	result=$(awk '/^ORCHD_RESULT:/ { sub(/^ORCHD_RESULT:[[:space:]]*/, ""); r=$0 } END { print r }' "$file" 2>/dev/null | tr -d '\r' | tr '[:lower:]' '[:upper:]')
	reason=$(awk '/^ORCHD_REASON:/ { sub(/^ORCHD_REASON:[[:space:]]*/, ""); r=$0 } END { print r }' "$file" 2>/dev/null | tr -d '\r')

	case "$result" in
	CONTINUE | WAIT | NEEDS_INPUT | PROJECT_COMPLETE)
		ORCHD_ORCH_RESULT="$result"
		;;
	esac
	if [[ -n "$reason" ]]; then
		ORCHD_ORCH_REASON="$reason"
	fi
}

_orchestrate_next_reason() {
	local result=$1
	local result_reason=$2
	local passive_stop=$3
	local summary=$4

	if [[ "$passive_stop" == "true" ]]; then
		printf 'system reminder: you ended with a passive handoff before the project was complete. Continue autonomously. Current summary: %s\n' "$summary"
		return 0
	fi
	if [[ "$result" == "PROJECT_COMPLETE" ]]; then
		printf 'system reminder: your previous PROJECT_COMPLETE decision was premature. Continue autonomous orchestration. Current summary: %s\n' "$summary"
		return 0
	fi
	if [[ -n "$result_reason" ]]; then
		printf 'system reminder: previous result was %s (%s). Continue orchestration until terminal state. Current summary: %s\n' "$result" "$result_reason" "$summary"
		return 0
	fi
	printf 'system reminder: continue orchestration until terminal state. Current summary: %s\n' "$summary"
}

_orchestrate_build_reminder_block() {
	local reason=$1
	local summary=$2
	if [[ "$reason" == "startup" ]]; then
		return 0
	fi
	cat <<EOF
<system-reminder>
You are the active orchestrator for this orchd project.
Your previous orchestration turn ended before the project reached a terminal state.

Resume reason: $reason
Current summary: $summary

Do not stop after a partial orchestration step.
Do not wait for user permission unless there is a real blocker.
If workers are running, let the supervisor handle waiting and then continue orchestration.
If tasks need checking or merging, do that.
If tasks are ready to spawn, do that.
If there is no active work, create the next work item with orchd ideate/plan or conclude PROJECT_COMPLETE.
Only stop when the project is complete or a genuine blocking decision is required.
</system-reminder>
EOF
}

_build_orchestrator_prompt() {
	local iteration=$1
	local reason=$2
	local state_summary=$3
	local state_json=$4
	local template_file="$ORCHD_LIB_DIR/../templates/orchestrator.prompt"
	[[ -f "$template_file" ]] || die "orchestrator template not found: $template_file"

	local prompt
	prompt=$(cat "$template_file")
	local reminder_block
	reminder_block=$(_orchestrate_build_reminder_block "$reason" "$state_summary")
	local memory_ctx
	memory_ctx=$(memory_read_context)
	if [[ -z "$memory_ctx" ]]; then
		memory_ctx="(no project memory yet)"
	fi
	local last_output_tail="(no previous orchestrator output)"
	if [[ -f "$(_orchestrate_state_dir)/last_output.txt" ]]; then
		last_output_tail=$(tail -n 120 "$(_orchestrate_state_dir)/last_output.txt" 2>/dev/null || true)
		[[ -n "$last_output_tail" ]] || last_output_tail="(no previous orchestrator output)"
	fi

	prompt=$(replace_token "$prompt" "{system_reminder_block}" "$reminder_block")
	prompt=$(replace_token "$prompt" "{iteration}" "$iteration")
	prompt=$(replace_token "$prompt" "{resume_reason}" "$reason")
	prompt=$(replace_token "$prompt" "{state_summary}" "$state_summary")
	prompt=$(replace_token "$prompt" "{state_json}" "$state_json")
	prompt=$(replace_token "$prompt" "{memory_context}" "$memory_ctx")
	prompt=$(replace_token "$prompt" "{last_output_tail}" "$last_output_tail")
	printf '%s\n' "$prompt"
}

_orchestrate_invoke_runner() {
	local runner=$1
	local prompt=$2
	local out_file=$3
	local err_file=$4
	local raw_file=$5

	case "$runner" in
	codex)
		local codex_bin codex_flags
		codex_bin=$(config_get "codex_bin" "codex")
		codex_flags=$(config_get "codex_flags" "--dangerously-bypass-approvals-and-sandbox")
		# shellcheck disable=SC2086
		"$codex_bin" $codex_flags exec "$prompt" -C "$PROJECT_ROOT" --json >"$raw_file" 2>"$err_file" || return 1
		_extract_text_from_jsonl <"$raw_file" >"$out_file" || return 1
		;;
	claude)
		local claude_bin
		claude_bin=$(config_get "claude_bin" "claude")
		(cd "$PROJECT_ROOT" && "$claude_bin" -p "$prompt" --output-format text >"$out_file" 2>"$err_file") || return 1
		;;
	opencode)
		(cd "$PROJECT_ROOT" && opencode -p "$prompt" >"$out_file" 2>"$err_file") || return 1
		;;
	aider)
		(cd "$PROJECT_ROOT" && aider --message "$prompt" --yes --no-git >"$out_file" 2>"$err_file") || return 1
		;;
	custom)
		local custom_cmd
		custom_cmd=$(config_get "custom_runner_cmd" "")
		[[ -n "$custom_cmd" ]] || die "custom runner requires 'custom_runner_cmd' in .orchd.toml"
		custom_cmd=$(replace_token "$custom_cmd" "{prompt}" "$(printf '%q' "$prompt")")
		custom_cmd=$(replace_token "$custom_cmd" "{worktree}" "$(printf '%q' "$PROJECT_ROOT")")
		custom_cmd=$(replace_token "$custom_cmd" "{task_id}" "$(printf '%q' "orchestrate")")
		custom_cmd=$(replace_token "$custom_cmd" "{log_file}" "$(printf '%q' "$out_file")")
		eval "$custom_cmd" >"$out_file" 2>"$err_file" || return 1
		;;
	*)
		return 1
		;;
	esac
	return 0
}

_orchestrate_sticky_session_name() {
	local hash
	hash=$(printf '%s' "$PROJECT_ROOT" | git hash-object --stdin)
	printf 'orchd-orchestrator-%s\n' "${hash:0:10}"
}

_orchestrate_sticky_start_session() {
	local session_name=$1
	if tmux has-session -t "$session_name" 2>/dev/null; then
		return 0
	fi
	tmux new -d -s "$session_name" "cd $(printf '%q' "$PROJECT_ROOT") && opencode" || return 1
	sleep 1
	return 0
}

_orchestrate_tmux_send_text() {
	local session_name=$1
	local text=$2
	local stamp
	stamp=$(date +%s)
	local msg_file="$(_orchestrate_state_dir)/inject-${stamp}.txt"
	local buf_name="orchd-orchestrator-${stamp}"
	printf '%s\n' "$text" >"$msg_file"
	tmux load-buffer -b "$buf_name" "$msg_file" || return 1
	tmux paste-buffer -b "$buf_name" -t "$session_name" || return 1
	tmux send-keys -t "$session_name" Enter || return 1
	tmux delete-buffer -b "$buf_name" >/dev/null 2>&1 || true
	rm -f "$msg_file" >/dev/null 2>&1 || true
	return 0
}

_orchestrate_sticky_capture_output() {
	local session_name=$1
	local out_file=$2
	tmux capture-pane -p -J -S -1600 -t "$session_name" >"$out_file" 2>/dev/null
}

_orchestrate_loop_sticky() {
	local runner=$1
	local poll_interval=$2
	local continue_delay=$3
	local max_iterations=$4
	local max_stagnation=$5
	local idle_timeout=$6
	local reminder_cooldown=$7
	local max_reminders=$8
	local fallback_on_inject_failure=$9

	if [[ "$runner" != "opencode" ]]; then
		return 93
	fi

	local fallback_enabled=true
	if ! is_truthy "$fallback_on_inject_failure"; then
		fallback_enabled=false
	fi

	local session_name
	session_name=$(_orchestrate_sticky_session_name)
	printf '%s\n' "$session_name" >"$(_orchestrate_session_name_file)"
	printf 'sticky\n' >"$(_orchestrate_session_mode_file)"

	local iteration=0
	local reminder_count=0
	local reason="startup"
	local should_inject=true
	local last_output_hash=""
	local last_fingerprint=""
	local last_state_fingerprint=""
	local stagnation=0
	local last_reminder_epoch=0
	local last_activity_epoch
	last_activity_epoch=$(date +%s)

	log_event "INFO" "orchestrator sticky supervisor started (runner=$runner poll=${poll_interval}s session=$session_name)"
	printf 'orchestrator sticky supervisor started\n'
	printf '  runner: %s\n' "$runner"
	printf '  poll:   %ss\n' "$poll_interval"
	printf '  mode:   sticky-session\n'
	printf '  tmux:   %s\n\n' "$session_name"

	while true; do
		if [[ -f "$(_orchestrate_stop_file)" ]]; then
			log_event "INFO" "orchestrator sticky supervisor stop file detected"
			printf 'orchestrator sticky supervisor stopped\n'
			return 0
		fi

		if [[ "$should_inject" == "true" ]]; then
			iteration=$((iteration + 1))
			printf '%s\n' "$iteration" >"$(_orchestrate_state_dir)/iteration"
			if ((max_iterations > 0)) && ((iteration > max_iterations)); then
				log_event "WARN" "orchestrator sticky iteration limit reached ($max_iterations)"
				printf 'orchestrator reached iteration limit (%d)\n' "$max_iterations"
				return 1
			fi

			_orchestrate_collect_state
			local pre_summary pre_state_json prompt
			pre_summary=$(_orchestrate_state_summary)
			pre_state_json=$(cmd_state --json)
			printf '%s\n' "$pre_state_json" >"$(_orchestrate_state_dir)/current_state.json"
			prompt=$(_build_orchestrator_prompt "$iteration" "$reason" "$pre_summary" "$pre_state_json")

			local prefix prompt_file
			prefix=$(printf '%04d' "$iteration")
			prompt_file="$(_orchestrate_iteration_dir)/${prefix}.prompt.txt"
			printf '%s\n' "$prompt" >"$prompt_file"
			cp "$prompt_file" "$(_orchestrate_state_dir)/last_prompt.txt"

			if ! _orchestrate_sticky_start_session "$session_name"; then
				if [[ "$fallback_enabled" == "true" ]]; then
					log_event "WARN" "sticky orchestrator failed to start session; falling back"
					return 93
				fi
				return 1
			fi

			printf '[%s] sticky orchestrator inject %d - %s\n' "$(now_iso)" "$iteration" "$reason"
			_orchestrate_history_append "sticky iteration=$iteration reason=$reason before=$pre_summary"

			if ! _orchestrate_tmux_send_text "$session_name" "$prompt"; then
				if [[ "$fallback_enabled" == "true" ]]; then
					log_event "WARN" "sticky orchestrator reminder injection failed; falling back"
					return 93
				fi
				return 1
			fi

			if [[ "$reason" != "startup" ]]; then
				reminder_count=$((reminder_count + 1))
				printf '%s\n' "$reminder_count" >"$(_orchestrate_state_dir)/reminder_count"
				if ((max_reminders > 0)) && ((reminder_count > max_reminders)); then
					if [[ "$fallback_enabled" == "true" ]]; then
						log_event "WARN" "sticky orchestrator max reminders reached; falling back"
						return 93
					fi
					log_event "ERROR" "sticky orchestrator max reminders reached"
					return 1
				fi
			fi

			last_reminder_epoch=$(date +%s)
			should_inject=false
			reason=""
			if ((continue_delay > 0)); then
				sleep "$continue_delay"
			fi
		fi

		if ! tmux has-session -t "$session_name" 2>/dev/null; then
			reason="system reminder: orchestrator session exited unexpectedly. Continue from current state."
			should_inject=true
			continue
		fi

		local out_file
		out_file="$(_orchestrate_iteration_dir)/sticky-live.out.txt"
		if ! _orchestrate_sticky_capture_output "$session_name" "$out_file"; then
			sleep "$poll_interval"
			continue
		fi
		cp "$out_file" "$(_orchestrate_state_dir)/last_output.txt"

		local output_hash now_epoch idle_secs
		output_hash=$(git hash-object "$out_file")
		now_epoch=$(date +%s)
		if [[ "$output_hash" != "$last_output_hash" ]]; then
			last_output_hash="$output_hash"
			last_activity_epoch="$now_epoch"
			printf '%s\n' "$last_activity_epoch" >"$(_orchestrate_state_dir)/last_activity_epoch"
		fi
		idle_secs=$((now_epoch - last_activity_epoch))

		_orchestrate_parse_result "$out_file"
		local result result_reason passive_stop=false
		result="$ORCHD_ORCH_RESULT"
		result_reason="$ORCHD_ORCH_REASON"
		if _orchestrate_passive_stop_detected "$out_file"; then
			passive_stop=true
		fi

		_orchestrate_collect_state
		local post_summary post_state_json state_fingerprint combined_fingerprint
		post_summary=$(_orchestrate_state_summary)
		post_state_json=$(cmd_state --json)
		printf '%s\n' "$post_state_json" >"$(_orchestrate_state_dir)/current_state.json"
		printf '%s\n' "$result" >"$(_orchestrate_state_dir)/last_result"
		printf '%s\n' "$result_reason" >"$(_orchestrate_state_dir)/last_reason"
		state_fingerprint=$(printf '%s' "$post_state_json" | git hash-object --stdin)
		combined_fingerprint=$(printf '%s|%s' "$state_fingerprint" "$output_hash" | git hash-object --stdin)

		if [[ -n "$last_fingerprint" ]] && [[ "$combined_fingerprint" == "$last_fingerprint" ]]; then
			stagnation=$((stagnation + 1))
		else
			stagnation=0
		fi
		last_fingerprint="$combined_fingerprint"
		printf '%s\n' "$stagnation" >"$(_orchestrate_state_dir)/stagnation_count"

		if [[ "$result" == "NEEDS_INPUT" ]]; then
			log_event "WARN" "orchestrator reported needs_input: ${result_reason:-no reason given}"
			printf 'orchestrator needs input: %s\n' "$result_reason"
			return 2
		fi

		if [[ "$result" == "PROJECT_COMPLETE" ]] && _orchestrate_completion_eligible; then
			log_event "INFO" "orchestrator completed project"
			printf 'project complete (orchestrator)\n'
			return 0
		fi

		if ((stagnation >= max_stagnation)); then
			if [[ "$fallback_enabled" == "true" ]]; then
				log_event "WARN" "sticky orchestrator stagnated; falling back"
				return 93
			fi
			log_event "ERROR" "sticky orchestrator stalled after $stagnation unchanged cycles"
			printf 'orchestrator stalled after %d unchanged cycles\n' "$stagnation"
			return 1
		fi

		local cooldown_ok=false
		if ((now_epoch - last_reminder_epoch >= reminder_cooldown)); then
			cooldown_ok=true
		fi

		if ((ORCH_STATE_RUNNING > 0)); then
			local wait_output=""
			if wait_output=$(cmd_await --all --json --timeout "$poll_interval"); then
				printf '%s\n' "$wait_output" >"$(_orchestrate_state_dir)/last_wait.json"
				local wait_event
				wait_event=$(printf '%s' "$wait_output" | awk -F '"' '/"event":/ { print $4; exit }')
				reason="system reminder: worker state changed (${wait_event:-action_required}). Re-read orchd state and continue orchestration."
				should_inject=true
				continue
			fi
		fi

		if [[ "$cooldown_ok" == "true" ]]; then
			if [[ -n "$last_state_fingerprint" ]] && [[ "$state_fingerprint" != "$last_state_fingerprint" ]]; then
				reason="system reminder: orchd state changed. Re-read state and continue orchestration. Current summary: $post_summary"
				should_inject=true
				last_state_fingerprint="$state_fingerprint"
				continue
			fi
			if ((idle_secs >= idle_timeout)); then
				reason=$(_orchestrate_next_reason "$result" "$result_reason" "$passive_stop" "$post_summary")
				should_inject=true
				last_state_fingerprint="$state_fingerprint"
				continue
			fi
		fi

		last_state_fingerprint="$state_fingerprint"
		sleep "$poll_interval"
	done
}

_orchestrate_loop() {
	local runner=$1
	local poll_interval=$2
	local continue_delay=$3
	local max_iterations=$4
	local max_stagnation=$5
	local once=$6

	local iteration=0
	local reason="startup"
	local last_fingerprint=""
	local stagnation=0

	log_event "INFO" "orchestrator supervisor started (runner=$runner poll=${poll_interval}s once=$once)"
	printf 'orchestrator supervisor started\n'
	printf '  runner: %s\n' "$runner"
	printf '  poll:   %ss\n' "$poll_interval"
	printf '  mode:   %s\n\n' "$([[ "$once" == "true" ]] && printf 'single-turn' || printf 'supervised-loop')"

	while true; do
		if [[ -f "$(_orchestrate_stop_file)" ]]; then
			log_event "INFO" "orchestrator supervisor stop file detected"
			printf 'orchestrator supervisor stopped\n'
			return 0
		fi

		iteration=$((iteration + 1))
		printf '%s\n' "$iteration" >"$(_orchestrate_state_dir)/iteration"
		if ((max_iterations > 0)) && ((iteration > max_iterations)); then
			log_event "WARN" "orchestrator supervisor iteration limit reached ($max_iterations)"
			printf 'orchestrator reached iteration limit (%d)\n' "$max_iterations"
			return 1
		fi

		_orchestrate_collect_state
		local pre_summary pre_state_json
		pre_summary=$(_orchestrate_state_summary)
		pre_state_json=$(cmd_state --json)
		printf '%s\n' "$pre_state_json" >"$(_orchestrate_state_dir)/current_state.json"

		local prompt
		prompt=$(_build_orchestrator_prompt "$iteration" "$reason" "$pre_summary" "$pre_state_json")

		local prefix prompt_file out_file err_file raw_file
		prefix=$(printf '%04d' "$iteration")
		prompt_file="$(_orchestrate_iteration_dir)/${prefix}.prompt.txt"
		out_file="$(_orchestrate_iteration_dir)/${prefix}.out.txt"
		err_file="$(_orchestrate_iteration_dir)/${prefix}.stderr.log"
		raw_file="$(_orchestrate_iteration_dir)/${prefix}.raw.jsonl"
		printf '%s\n' "$prompt" >"$prompt_file"
		cp "$prompt_file" "$(_orchestrate_state_dir)/last_prompt.txt"

		printf '[%s] orchestrator iteration %d - %s\n' "$(now_iso)" "$iteration" "$reason"
		_orchestrate_history_append "iteration=$iteration reason=$reason before=$pre_summary"

		local invoke_rc=0
		if _orchestrate_invoke_runner "$runner" "$prompt" "$out_file" "$err_file" "$raw_file"; then
			invoke_rc=0
		else
			invoke_rc=$?
		fi
		if [[ -f "$out_file" ]]; then
			cp "$out_file" "$(_orchestrate_state_dir)/last_output.txt"
		else
			: >"$(_orchestrate_state_dir)/last_output.txt"
		fi

		_orchestrate_parse_result "$out_file"
		local result result_reason passive_stop=false
		result="$ORCHD_ORCH_RESULT"
		result_reason="$ORCHD_ORCH_REASON"
		if _orchestrate_passive_stop_detected "$out_file"; then
			passive_stop=true
		fi

		_orchestrate_collect_state
		local post_summary post_state_json fingerprint
		post_summary=$(_orchestrate_state_summary)
		post_state_json=$(cmd_state --json)
		printf '%s\n' "$post_state_json" >"$(_orchestrate_state_dir)/current_state.json"
		printf '%s\n' "$result" >"$(_orchestrate_state_dir)/last_result"
		printf '%s\n' "$result_reason" >"$(_orchestrate_state_dir)/last_reason"
		fingerprint=$(printf '%s' "$post_state_json" | git hash-object --stdin)
		if [[ -n "$last_fingerprint" ]] && [[ "$fingerprint" == "$last_fingerprint" ]]; then
			stagnation=$((stagnation + 1))
		else
			stagnation=0
		fi
		last_fingerprint="$fingerprint"
		printf '%s\n' "$stagnation" >"$(_orchestrate_state_dir)/stagnation_count"

		_orchestrate_history_append "iteration=$iteration result=$result passive_stop=$passive_stop rc=$invoke_rc after=$post_summary"

		if ((invoke_rc != 0)); then
			log_event "WARN" "orchestrator runner failed (iteration=$iteration rc=$invoke_rc)"
			if [[ "$once" == "true" ]]; then
				return 1
			fi
			reason="system reminder: orchestrator runner exited with an error. Re-read orchd state and continue orchestration."
			sleep "$poll_interval"
			continue
		fi

		if [[ "$once" == "true" ]]; then
			printf 'orchestrator result: %s\n' "$result"
			return 0
		fi

		if [[ "$result" == "NEEDS_INPUT" ]]; then
			log_event "WARN" "orchestrator reported needs_input: ${result_reason:-no reason given}"
			printf 'orchestrator needs input: %s\n' "$result_reason"
			return 2
		fi

		if [[ "$result" == "PROJECT_COMPLETE" ]] && _orchestrate_completion_eligible; then
			log_event "INFO" "orchestrator completed project"
			printf 'project complete (orchestrator)\n'
			return 0
		fi

		if ((ORCH_STATE_RUNNING > 0)); then
			printf '  workers running - awaiting state change...\n\n'
			local wait_output=""
			if wait_output=$(cmd_await --all --json); then
				printf '%s\n' "$wait_output" >"$(_orchestrate_state_dir)/last_wait.json"
				local wait_event
				wait_event=$(printf '%s' "$wait_output" | awk -F '"' '/"event":/ { print $4; exit }')
				reason="system reminder: worker state changed (${wait_event:-action_required}). Re-read orchd state and continue orchestration."
			else
				reason="system reminder: await returned early. Re-read orchd state and continue orchestration."
			fi
			continue
		fi

		if ((stagnation >= max_stagnation)); then
			log_event "ERROR" "orchestrator supervisor stalled after $stagnation unchanged iterations"
			printf 'orchestrator stalled after %d unchanged iterations\n' "$stagnation"
			return 1
		fi

		reason=$(_orchestrate_next_reason "$result" "$result_reason" "$passive_stop" "$post_summary")
		if ((continue_delay > 0)); then
			sleep "$continue_delay"
		fi
	done
}
