#!/usr/bin/env bash
# lib/cmd/state.sh - orchd state command
# Prints a machine-friendly snapshot of orchd task state.

_json_escape() {
	local s=${1-}
	s=${s//\\/\\\\}
	s=${s//"/\\"/}
	s=${s//$'\n'/\\n}
	s=${s//$'\r'/\\r}
	s=${s//$'\t'/\\t}
	printf '%s' "$s"
}

_json_bool() {
	local raw=${1:-false}
	raw=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
	case "$raw" in
	true | 1 | yes | on)
		printf 'true'
		;;
	false | 0 | no | off | "")
		printf 'false'
		;;
	*)
		printf 'false'
		;;
	esac
}

_json_int() {
	local raw=${1:-0}
	if [[ "$raw" =~ ^-?[0-9]+$ ]]; then
		printf '%s' "$raw"
	else
		printf '0'
	fi
}

_state_read_file() {
	local path=$1
	cat "$path" 2>/dev/null || true
}

_state_scheduler_file() {
	local name=$1
	printf '%s/scheduler/%s\n' "$ORCHD_DIR" "$name"
}

_state_orchestrator_file() {
	local name=$1
	printf '%s/orchestrator/%s\n' "$ORCHD_DIR" "$name"
}

_task_log_file() {
	local task_id=$1
	local log_file=""
	if [[ -f "$LOGS_DIR/${task_id}.log" ]]; then
		log_file="$LOGS_DIR/${task_id}.log"
	elif [[ -f "$LOGS_DIR/${task_id}.jsonl" ]]; then
		log_file="$LOGS_DIR/${task_id}.jsonl"
	fi
	printf '%s\n' "$log_file"
}

_deps_all_merged() {
	local task_id=$1
	local deps
	deps=$(task_get "$task_id" "deps" "")
	[[ -n "$deps" ]] || return 0

	local dep dep_status
	while IFS=',' read -ra dep_arr; do
		for dep in "${dep_arr[@]}"; do
			dep=$(printf '%s' "$dep" | tr -d '[:space:]')
			[[ -z "$dep" ]] && continue
			dep_status=$(task_status "$dep")
			[[ "$dep_status" == "merged" ]] || return 1
		done
	done <<<"$deps"
	return 0
}

cmd_state() {
	local mode="${1:-}"

	require_project

	case "$mode" in
	--json | -j)
		_state_json
		;;
	"" | --text | -t)
		_state_text
		;;
	-h | --help)
		printf '%s\n' "usage: orchd state [--json]"
		;;
	*)
		die "usage: orchd state [--json]"
		;;
	esac
}

_state_text() {
	local base_branch worktree_dir max_parallel runner
	base_branch=$(config_get "base_branch" "main")
	worktree_dir=$(config_get "worktree_dir" ".worktrees")
	max_parallel=$(config_get "max_parallel" "3")
	runner=$(detect_runner)

	local total=0 pending=0 running=0 done_count=0 merged=0 split_count=0 failed=0 conflict=0 needs_input=0
	local checkable=0 mergeable=0 spawnable=0

	local task_id status
	while IFS= read -r task_id; do
		[[ -z "$task_id" ]] && continue
		total=$((total + 1))
		task_runtime_refresh "$task_id"
		status="$TASK_RUNTIME_STATUS"
		case "$status" in
		pending)
			pending=$((pending + 1))
			if task_is_ready "$task_id"; then
				spawnable=$((spawnable + 1))
			fi
			;;
		running)
			if [[ "$TASK_RUNTIME_AGENT_ALIVE" == "true" ]]; then
				running=$((running + 1))
			fi
			if [[ "$TASK_RUNTIME_AGENT_ALIVE" != "true" ]]; then
				checkable=$((checkable + 1))
			fi
			;;
		done)
			done_count=$((done_count + 1))
			if _deps_all_merged "$task_id"; then
				mergeable=$((mergeable + 1))
			fi
			;;
		merged) merged=$((merged + 1)) ;;
		split) split_count=$((split_count + 1)) ;;
		failed) failed=$((failed + 1)) ;;
		conflict) conflict=$((conflict + 1)) ;;
		needs_input) needs_input=$((needs_input + 1)) ;;
		esac
	done <<<"$(task_list_ids)"

	printf 'project:      %s\n' "$PROJECT_ROOT"
	printf 'base_branch:  %s\n' "$base_branch"
	printf 'worktrees:    %s/%s\n' "$PROJECT_ROOT" "$worktree_dir"
	printf 'worker_runner:%s\n' "$runner"
	printf 'tasks:        total=%d pending=%d running=%d done=%d merged=%d split=%d failed=%d conflict=%d needs_input=%d\n' \
		"$total" "$pending" "$running" "$done_count" "$merged" "$split_count" "$failed" "$conflict" "$needs_input"
	printf 'ready:        spawn=%d check=%d merge=%d (max_parallel=%s)\n' "$spawnable" "$checkable" "$mergeable" "$max_parallel"

	if ((total == 0)); then
		printf '\nno tasks found (run: orchd plan ...)\n'
		return 0
	fi

	printf '\nnext:\n'
	if ((checkable > 0)); then
		printf '  orchd check --all\n'
	fi
	if ((mergeable > 0)); then
		printf '  orchd merge --all\n'
	fi
	if ((spawnable > 0)) && ((running < max_parallel)); then
		printf '  orchd spawn --all\n'
	fi
}

_state_json() {
	local base_branch worktree_dir max_parallel runner
	base_branch=$(config_get "base_branch" "main")
	worktree_dir=$(config_get "worktree_dir" ".worktrees")
	max_parallel=$(config_get "max_parallel" "3")
	runner=$(detect_runner)

	local total=0 pending=0 running=0 done_count=0 merged=0 split_count=0 failed=0 conflict=0 needs_input=0
	local checkable=0 mergeable=0 spawnable=0

	local ids=()
	local task_id
	while IFS= read -r task_id; do
		[[ -z "$task_id" ]] && continue
		ids+=("$task_id")
	done <<<"$(task_list_ids)"

	local status
	for task_id in "${ids[@]}"; do
		total=$((total + 1))
		task_runtime_refresh "$task_id"
		status="$TASK_RUNTIME_STATUS"
		case "$status" in
		pending)
			pending=$((pending + 1))
			if task_is_ready "$task_id"; then spawnable=$((spawnable + 1)); fi
			;;
		running)
			if [[ "$TASK_RUNTIME_AGENT_ALIVE" == "true" ]]; then
				running=$((running + 1))
			fi
			if [[ "$TASK_RUNTIME_AGENT_ALIVE" != "true" ]]; then checkable=$((checkable + 1)); fi
			;;
		done)
			done_count=$((done_count + 1))
			if _deps_all_merged "$task_id"; then mergeable=$((mergeable + 1)); fi
			;;
		merged) merged=$((merged + 1)) ;;
		split) split_count=$((split_count + 1)) ;;
		failed) failed=$((failed + 1)) ;;
		conflict) conflict=$((conflict + 1)) ;;
		needs_input) needs_input=$((needs_input + 1)) ;;
		esac
	done

	printf '{'
	printf '"project_root":"%s",' "$(_json_escape "$PROJECT_ROOT")"
	printf '"base_branch":"%s",' "$(_json_escape "$base_branch")"
	printf '"worktree_dir":"%s",' "$(_json_escape "$worktree_dir")"
	printf '"worker_runner":"%s",' "$(_json_escape "$runner")"
	printf '"max_parallel":%s,' "$(_json_int "$max_parallel")"
	printf '"counts":{'
	printf '"total":%d,' "$total"
	printf '"pending":%d,' "$pending"
	printf '"running":%d,' "$running"
	printf '"done":%d,' "$done_count"
	printf '"merged":%d,' "$merged"
	printf '"split":%d,' "$split_count"
	printf '"failed":%d,' "$failed"
	printf '"conflict":%d,' "$conflict"
	printf '"needs_input":%d' "$needs_input"
	printf '},'
	printf '"ready":{'
	printf '"spawn":%d,' "$spawnable"
	printf '"check":%d,' "$checkable"
	printf '"merge":%d' "$mergeable"
	printf '},'
	local finish_state finish_reason finish_updated_at
	finish_state=$(cat "$ORCHD_DIR/finish/state" 2>/dev/null || true)
	finish_reason=$(cat "$ORCHD_DIR/finish/reason" 2>/dev/null || true)
	finish_updated_at=$(cat "$ORCHD_DIR/finish/updated_at" 2>/dev/null || true)
	printf '"finisher":{'
	printf '"state":"%s",' "$(_json_escape "$finish_state")"
	printf '"reason":"%s",' "$(_json_escape "$finish_reason")"
	printf '"updated_at":"%s"' "$(_json_escape "$finish_updated_at")"
	printf '},'
	local scheduler_last_action scheduler_last_reason scheduler_autopilot_action scheduler_autopilot_reason scheduler_autopilot_updated_at scheduler_orchestrate_action scheduler_orchestrate_reason scheduler_orchestrate_updated_at scheduler_updated_at
	scheduler_last_action=$(_state_read_file "$(_state_scheduler_file "last_action")")
	scheduler_last_reason=$(_state_read_file "$(_state_scheduler_file "last_reason")")
	scheduler_autopilot_action=$(_state_read_file "$(_state_scheduler_file "autopilot.action")")
	scheduler_autopilot_reason=$(_state_read_file "$(_state_scheduler_file "autopilot.reason")")
	scheduler_autopilot_updated_at=$(_state_read_file "$(_state_scheduler_file "autopilot.updated_at")")
	scheduler_orchestrate_action=$(_state_read_file "$(_state_scheduler_file "orchestrate.action")")
	scheduler_orchestrate_reason=$(_state_read_file "$(_state_scheduler_file "orchestrate.reason")")
	scheduler_orchestrate_updated_at=$(_state_read_file "$(_state_scheduler_file "orchestrate.updated_at")")
	if [[ -z "$scheduler_last_action" ]]; then
		scheduler_last_action="$scheduler_orchestrate_action"
	fi
	if [[ -z "$scheduler_last_action" ]]; then
		scheduler_last_action="$scheduler_autopilot_action"
	fi
	if [[ -z "$scheduler_last_reason" ]]; then
		scheduler_last_reason="$scheduler_orchestrate_reason"
	fi
	if [[ -z "$scheduler_last_reason" ]]; then
		scheduler_last_reason="$scheduler_autopilot_reason"
	fi
	scheduler_updated_at="$scheduler_orchestrate_updated_at"
	if [[ -z "$scheduler_updated_at" ]]; then
		scheduler_updated_at="$scheduler_autopilot_updated_at"
	fi
	printf '"scheduler":{'
	printf '"last_action":"%s",' "$(_json_escape "$scheduler_last_action")"
	printf '"last_reason":"%s",' "$(_json_escape "$scheduler_last_reason")"
	printf '"updated_at":"%s",' "$(_json_escape "$scheduler_updated_at")"
	printf '"autopilot":{'
	printf '"action":"%s",' "$(_json_escape "$scheduler_autopilot_action")"
	printf '"reason":"%s",' "$(_json_escape "$scheduler_autopilot_reason")"
	printf '"updated_at":"%s"' "$(_json_escape "$scheduler_autopilot_updated_at")"
	printf '},'
	printf '"orchestrate":{'
	printf '"action":"%s",' "$(_json_escape "$scheduler_orchestrate_action")"
	printf '"reason":"%s",' "$(_json_escape "$scheduler_orchestrate_reason")"
	printf '"updated_at":"%s"' "$(_json_escape "$scheduler_orchestrate_updated_at")"
	printf '}'
	printf '},'
	local orch_route_role orch_selected_runner orch_route_reason orch_route_fallback orch_session_mode orch_last_result orch_last_reason orch_last_idle_decision orch_last_reminder_reason
	orch_route_role=$(_state_read_file "$(_state_orchestrator_file "route_role")")
	orch_selected_runner=$(_state_read_file "$(_state_orchestrator_file "selected_runner")")
	orch_route_reason=$(_state_read_file "$(_state_orchestrator_file "route_reason")")
	orch_route_fallback=$(_state_read_file "$(_state_orchestrator_file "route_fallback_used")")
	orch_session_mode=$(_state_read_file "$(_state_orchestrator_file "session_mode")")
	orch_last_result=$(_state_read_file "$(_state_orchestrator_file "last_result")")
	orch_last_reason=$(_state_read_file "$(_state_orchestrator_file "last_reason")")
	orch_last_idle_decision=$(_state_read_file "$(_state_orchestrator_file "last_idle_decision")")
	orch_last_reminder_reason=$(_state_read_file "$(_state_orchestrator_file "last_reminder_reason")")
	printf '"orchestrator":{'
	printf '"route_role":"%s",' "$(_json_escape "$orch_route_role")"
	printf '"selected_runner":"%s",' "$(_json_escape "$orch_selected_runner")"
	printf '"route_reason":"%s",' "$(_json_escape "$orch_route_reason")"
	printf '"route_fallback_used":%s,' "$(_json_bool "$orch_route_fallback")"
	printf '"session_mode":"%s",' "$(_json_escape "$orch_session_mode")"
	printf '"last_result":"%s",' "$(_json_escape "$orch_last_result")"
	printf '"last_reason":"%s",' "$(_json_escape "$orch_last_reason")"
	printf '"last_idle_decision":"%s",' "$(_json_escape "$orch_last_idle_decision")"
	printf '"last_reminder_reason":"%s"' "$(_json_escape "$orch_last_reminder_reason")"
	printf '},'
	printf '"swarm_routing":{'
	local route_first=true
	local route_role
	for route_role in planner builder reviewer recovery; do
		if $route_first; then route_first=false; else printf ','; fi
		swarm_resolve_route "$route_role" "$runner" >/dev/null
		printf '"%s":{' "$(_json_escape "$route_role")"
		printf '"selected_runner":"%s",' "$(_json_escape "$SWARM_ROUTE_SELECTED_RUNNER")"
		printf '"preferred_runner":"%s",' "$(_json_escape "$SWARM_ROUTE_PREFERRED_RUNNER")"
		printf '"default_runner":"%s",' "$(_json_escape "$SWARM_ROUTE_DEFAULT_RUNNER")"
		printf '"candidates":"%s",' "$(_json_escape "$SWARM_ROUTE_CANDIDATES")"
		printf '"fallback_used":%s,' "$(_json_bool "$SWARM_ROUTE_FALLBACK_USED")"
		printf '"reason":"%s"' "$(_json_escape "$SWARM_ROUTE_REASON")"
		printf '}'
	done
	printf '},'

	printf '"tasks":['
	local first=true
	for task_id in "${ids[@]}"; do
		if $first; then first=false; else printf ','; fi

		local title role deps branch worktree session attempts checked_at merged_at last_failure_reason
		local task_runner routing_role routing_selected_runner routing_default_runner routing_reason routing_fallback_used routing_candidates
		local verification_tier verification_reason failure_class failure_summary failure_streak recovery_policy recovery_next_action recovery_policy_reason review_status review_reason review_required reviewed_at review_runner review_output_file merge_gate_status merge_gate_reason merge_required_verification_tier routing_fallback_count split_children
		title=$(task_get "$task_id" "title" "")
		role=$(task_get "$task_id" "role" "")
		deps=$(task_get "$task_id" "deps" "")
		branch=$(task_get "$task_id" "branch" "")
		worktree=$(task_get "$task_id" "worktree" "")
		session=$(task_get "$task_id" "session" "")
		task_runner=$(task_get "$task_id" "runner" "")
		attempts=$(task_get "$task_id" "attempts" "0")
		checked_at=$(task_get "$task_id" "checked_at" "")
		merged_at=$(task_get "$task_id" "merged_at" "")
		last_failure_reason=$(task_get "$task_id" "last_failure_reason" "")
		verification_tier=$(task_get "$task_id" "verification_tier" "")
		verification_reason=$(task_get "$task_id" "verification_reason" "")
		failure_class=$(task_get "$task_id" "failure_class" "")
		failure_summary=$(task_get "$task_id" "failure_summary" "")
		failure_streak=$(task_get "$task_id" "failure_streak" "0")
		recovery_policy=$(task_get "$task_id" "recovery_policy" "")
		recovery_next_action=$(task_get "$task_id" "recovery_next_action" "")
		recovery_policy_reason=$(task_get "$task_id" "recovery_policy_reason" "")
		review_status=$(task_get "$task_id" "review_status" "")
		review_reason=$(task_get "$task_id" "review_reason" "")
		reviewed_at=$(task_get "$task_id" "reviewed_at" "")
		review_runner=$(task_get "$task_id" "review_runner" "")
		review_output_file=$(task_get "$task_id" "review_output_file" "")
		merge_gate_status=$(task_get "$task_id" "merge_gate_status" "")
		merge_gate_reason=$(task_get "$task_id" "merge_gate_reason" "")
		merge_required_verification_tier=$(task_get "$task_id" "merge_required_verification_tier" "")
		routing_fallback_count=$(task_get "$task_id" "routing_fallback_count" "0")
		split_children=$(task_get "$task_id" "split_children" "")
		routing_role=$(task_get "$task_id" "routing_role" "")
		routing_selected_runner=$(task_get "$task_id" "routing_selected_runner" "")
		routing_default_runner=$(task_get "$task_id" "routing_default_runner" "")
		routing_reason=$(task_get "$task_id" "routing_reason" "")
		routing_fallback_used=$(task_get "$task_id" "routing_fallback_used" "")
		routing_candidates=$(task_get "$task_id" "routing_candidates" "")

		task_runtime_refresh "$task_id"
		status="$TASK_RUNTIME_STATUS"
		if [[ -z "$routing_role" ]]; then
			case "$status" in
			failed | needs_input | conflict)
				routing_role="recovery"
				;;
			*)
				routing_role="builder"
				;;
			esac
		fi
		if [[ -z "$routing_selected_runner" || -z "$routing_reason" || -z "$routing_fallback_used" || -z "$routing_candidates" ]]; then
			swarm_resolve_route "$routing_role" "$runner" >/dev/null
			[[ -n "$routing_selected_runner" ]] || routing_selected_runner="$SWARM_ROUTE_SELECTED_RUNNER"
			[[ -n "$routing_default_runner" ]] || routing_default_runner="$SWARM_ROUTE_DEFAULT_RUNNER"
			[[ -n "$routing_reason" ]] || routing_reason="$SWARM_ROUTE_REASON"
			[[ -n "$routing_fallback_used" ]] || routing_fallback_used="$SWARM_ROUTE_FALLBACK_USED"
			[[ -n "$routing_candidates" ]] || routing_candidates="$SWARM_ROUTE_CANDIDATES"
		fi
		if [[ -n "$task_runner" ]]; then
			routing_selected_runner="$task_runner"
		fi
		review_required="false"
		if verify_merge_requires_review "$task_id"; then
			review_required="true"
		fi
		local agent_alive
		agent_alive="$TASK_RUNTIME_AGENT_ALIVE"
		local effective_status
		effective_status="$TASK_RUNTIME_EFFECTIVE_STATUS"
		local session_state="none"
		if [[ "$TASK_RUNTIME_SESSION_PRESENT" == "true" ]]; then
			if [[ "$TASK_RUNTIME_AGENT_ALIVE" == "true" ]]; then
				session_state="alive"
			else
				session_state="stale"
			fi
		fi
		local log_file
		log_file=$(_task_log_file "$task_id")
		local needs_input_source needs_input_file needs_input_code needs_input_summary needs_input_question needs_input_blocking needs_input_options needs_input_error
		needs_input_source=$(task_get "$task_id" "needs_input_source" "")
		needs_input_file=$(task_get "$task_id" "needs_input_file" "")
		needs_input_code=$(task_get "$task_id" "needs_input_code" "")
		needs_input_summary=$(task_get "$task_id" "needs_input_summary" "")
		needs_input_question=$(task_get "$task_id" "needs_input_question" "")
		needs_input_blocking=$(task_get "$task_id" "needs_input_blocking" "")
		needs_input_options=$(task_get "$task_id" "needs_input_options" "")
		needs_input_error=$(task_get "$task_id" "needs_input_error" "")

		if [[ "$status" == "needs_input" ]] && [[ -z "$needs_input_source" ]] && [[ -n "$worktree" ]] && [[ -d "$worktree" ]]; then
			needs_input_detect "$worktree"
			if [[ "$ORCHD_NEEDS_INPUT_PRESENT" == "true" ]]; then
				needs_input_source="$ORCHD_NEEDS_INPUT_SOURCE"
				needs_input_file="$ORCHD_NEEDS_INPUT_FILE"
				needs_input_code="$ORCHD_NEEDS_INPUT_CODE"
				needs_input_summary="$ORCHD_NEEDS_INPUT_SUMMARY"
				needs_input_question="$ORCHD_NEEDS_INPUT_QUESTION"
				needs_input_blocking="$ORCHD_NEEDS_INPUT_BLOCKING"
				needs_input_options="$ORCHD_NEEDS_INPUT_OPTIONS"
				needs_input_error="$ORCHD_NEEDS_INPUT_ERROR"
			fi
		fi

		printf '{'
		printf '"id":"%s",' "$(_json_escape "$task_id")"
		printf '"title":"%s",' "$(_json_escape "$title")"
		printf '"role":"%s",' "$(_json_escape "$role")"
		printf '"status":"%s",' "$(_json_escape "$status")"
		printf '"effective_status":"%s",' "$(_json_escape "$effective_status")"
		printf '"deps":"%s",' "$(_json_escape "$deps")"
		printf '"branch":"%s",' "$(_json_escape "$branch")"
		printf '"worktree":"%s",' "$(_json_escape "$worktree")"
		printf '"runner":"%s",' "$(_json_escape "$task_runner")"
		printf '"routing_role":"%s",' "$(_json_escape "$routing_role")"
		printf '"selected_runner":"%s",' "$(_json_escape "$routing_selected_runner")"
		printf '"routing_default_runner":"%s",' "$(_json_escape "$routing_default_runner")"
		printf '"routing_candidates":"%s",' "$(_json_escape "$routing_candidates")"
		printf '"routing_fallback_used":%s,' "$(_json_bool "$routing_fallback_used")"
		printf '"routing_reason":"%s",' "$(_json_escape "$routing_reason")"
		printf '"session":"%s",' "$(_json_escape "$session")"
		printf '"session_state":"%s",' "$(_json_escape "$session_state")"
		printf '"agent_alive":%s,' "$(_json_bool "$agent_alive")"
		printf '"attempts":%s,' "$(_json_int "$attempts")"
		printf '"checked_at":"%s",' "$(_json_escape "$checked_at")"
		printf '"merged_at":"%s",' "$(_json_escape "$merged_at")"
		printf '"last_failure_reason":"%s",' "$(_json_escape "$last_failure_reason")"
		printf '"verification_tier":"%s",' "$(_json_escape "$verification_tier")"
		printf '"verification_reason":"%s",' "$(_json_escape "$verification_reason")"
		printf '"failure_class":"%s",' "$(_json_escape "$failure_class")"
		printf '"failure_summary":"%s",' "$(_json_escape "$failure_summary")"
		printf '"failure_streak":%s,' "$(_json_int "$failure_streak")"
		printf '"recovery_policy":"%s",' "$(_json_escape "$recovery_policy")"
		printf '"recovery_next_action":"%s",' "$(_json_escape "$recovery_next_action")"
		printf '"recovery_policy_reason":"%s",' "$(_json_escape "$recovery_policy_reason")"
		printf '"review_status":"%s",' "$(_json_escape "$review_status")"
		printf '"review_reason":"%s",' "$(_json_escape "$review_reason")"
		printf '"review_required":%s,' "$(_json_bool "$review_required")"
		printf '"reviewed_at":"%s",' "$(_json_escape "$reviewed_at")"
		printf '"review_runner":"%s",' "$(_json_escape "$review_runner")"
		printf '"review_output_file":"%s",' "$(_json_escape "$review_output_file")"
		printf '"merge_gate_status":"%s",' "$(_json_escape "$merge_gate_status")"
		printf '"merge_gate_reason":"%s",' "$(_json_escape "$merge_gate_reason")"
		printf '"merge_required_verification_tier":"%s",' "$(_json_escape "$merge_required_verification_tier")"
		printf '"routing_fallback_count":%s,' "$(_json_int "$routing_fallback_count")"
		printf '"split_children":"%s",' "$(_json_escape "$split_children")"
		printf '"log_file":"%s",' "$(_json_escape "$log_file")"
		if [[ -n "$needs_input_source" || -n "$needs_input_file" || "$status" == "needs_input" ]]; then
			printf '"needs_input":{'
			printf '"source":"%s",' "$(_json_escape "$needs_input_source")"
			printf '"file":"%s",' "$(_json_escape "$needs_input_file")"
			printf '"code":"%s",' "$(_json_escape "$needs_input_code")"
			printf '"summary":"%s",' "$(_json_escape "$needs_input_summary")"
			printf '"question":"%s",' "$(_json_escape "$needs_input_question")"
			printf '"blocking":"%s",' "$(_json_escape "$needs_input_blocking")"
			printf '"options":"%s",' "$(_json_escape "$needs_input_options")"
			printf '"error":"%s"' "$(_json_escape "$needs_input_error")"
			printf '}'
		else
			printf '"needs_input":null'
		fi
		printf '}'
	done
	printf ']'
	printf '}\n'
}
