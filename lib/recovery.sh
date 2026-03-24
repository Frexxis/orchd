#!/usr/bin/env bash
# lib/recovery.sh - Failure classification and recovery policy helpers
# Sourced by bin/orchd - do not execute directly.

recovery_normalize_failure_class() {
	local raw=${1:-}
	raw=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
	case "$raw" in
	lint | lint_failure)
		printf 'lint_failure\n'
		;;
	test | tests | test_failure)
		printf 'test_failure\n'
		;;
	build | build_failure)
		printf 'build_failure\n'
		;;
	merge | merge_conflict | conflict)
		printf 'merge_conflict\n'
		;;
	infra | infra_flake | flaky | transient)
		printf 'infra_flake\n'
		;;
	scope | scope_confusion | confused)
		printf 'scope_confusion\n'
		;;
	needs_input | user_input | input)
		printf 'needs_input\n'
		;;
	*)
		printf '%s\n' "$raw"
		;;
	esac
}

recovery_failure_summary() {
	local failure_class=$1
	case "$failure_class" in
	lint_failure)
		printf 'lint command failed during verification\n'
		;;
	test_failure)
		printf 'test command failed during verification\n'
		;;
	build_failure)
		printf 'build command failed during verification\n'
		;;
	merge_conflict)
		printf 'merge conflict blocks integration\n'
		;;
	infra_flake)
		printf 'transient infrastructure or runner failure detected\n'
		;;
	scope_confusion)
		printf 'implementation appears incomplete or mismatched to scope\n'
		;;
	needs_input)
		printf 'task is waiting on explicit human input\n'
		;;
	*)
		printf 'task failure needs recovery triage\n'
		;;
	esac
}

_recovery_match_transient_text() {
	local file=$1
	[[ -f "$file" ]] || return 1
	grep -Eiq 'timed out|timeout|temporar|rate limit|connection reset|connection refused|econnreset|econnrefused|tls|network|service unavailable|try again|unavailable|resource busy|broken pipe|context deadline exceeded' "$file"
}

recovery_classify_failure() {
	local task_id=$1
	local check_file=${2:-}
	local status existing_source needs_code agent_exit_code log_file failure_class

	status=$(task_status "$task_id")
	existing_source=$(task_get "$task_id" "needs_input_source" "")
	needs_code=$(task_get "$task_id" "needs_input_code" "")
	agent_exit_code=$(task_get "$task_id" "agent_exit_code" "")
	log_file=""
	if [[ -f "$LOGS_DIR/${task_id}.log" ]]; then
		log_file="$LOGS_DIR/${task_id}.log"
	elif [[ -f "$LOGS_DIR/${task_id}.jsonl" ]]; then
		log_file="$LOGS_DIR/${task_id}.jsonl"
	fi

	failure_class=""
	if [[ "$status" == "needs_input" ]] || [[ -n "$existing_source" ]] || [[ -n "$needs_code" ]]; then
		failure_class="needs_input"
	elif [[ "$status" == "conflict" ]]; then
		failure_class="merge_conflict"
	elif [[ -n "$check_file" ]] && grep -q '\[FAIL\] lint failed' "$check_file" 2>/dev/null; then
		failure_class="lint_failure"
	elif [[ -n "$check_file" ]] && grep -q '\[FAIL\] tests failed' "$check_file" 2>/dev/null; then
		failure_class="test_failure"
	elif [[ -n "$check_file" ]] && grep -q '\[FAIL\] build failed' "$check_file" 2>/dev/null; then
		failure_class="build_failure"
	elif [[ -n "$check_file" ]] && grep -Eq 'needs user input|blocked \(BLOCKER.md present' "$check_file" 2>/dev/null; then
		failure_class="needs_input"
	elif { [[ -n "$check_file" ]] && _recovery_match_transient_text "$check_file"; } || { [[ -n "$log_file" ]] && _recovery_match_transient_text "$log_file"; }; then
		failure_class="infra_flake"
	elif [[ -n "$agent_exit_code" && "$agent_exit_code" != "0" && "$agent_exit_code" != "unknown" ]] && [[ -n "$check_file" ]] && ! grep -q '\[FAIL\] .* failed' "$check_file" 2>/dev/null; then
		failure_class="scope_confusion"
	else
		failure_class="scope_confusion"
	fi

	RECOVERY_FAILURE_CLASS=$(recovery_normalize_failure_class "$failure_class")
	RECOVERY_FAILURE_SUMMARY=$(recovery_failure_summary "$RECOVERY_FAILURE_CLASS")
	printf '%s\n' "$RECOVERY_FAILURE_CLASS"
}

recovery_policy_for_class() {
	local task_id=$1
	local failure_class
	failure_class=$(recovery_normalize_failure_class "$2")
	local attempts streak size
	attempts=$(task_get "$task_id" "attempts" "0")
	streak=$(task_get "$task_id" "failure_streak" "0")
	size=$(printf '%s' "$(task_get "$task_id" "size" "")" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
	[[ "$attempts" =~ ^[0-9]+$ ]] || attempts=0
	[[ "$streak" =~ ^[0-9]+$ ]] || streak=0

	case "$failure_class" in
	needs_input)
		RECOVERY_POLICY="needs_input"
		RECOVERY_NEXT_ACTION="wait_for_human"
		RECOVERY_POLICY_REASON="task explicitly requested human input"
		;;
	merge_conflict)
		RECOVERY_POLICY="retry_same_runner"
		RECOVERY_NEXT_ACTION="resolve_merge_conflict"
		RECOVERY_POLICY_REASON="conflict can be retried with focused merge-resolution context"
		;;
	infra_flake)
		RECOVERY_POLICY="retry_same_runner"
		RECOVERY_NEXT_ACTION="retry_after_backoff"
		RECOVERY_POLICY_REASON="transient failures should retry on the same runner first"
		;;
	lint_failure | test_failure | build_failure)
		if ((streak >= 2 || attempts >= 2)); then
			RECOVERY_POLICY="retry_alternate_runner"
			RECOVERY_NEXT_ACTION="resume_with_alternate_runner"
			RECOVERY_POLICY_REASON="repeated implementation failures should escalate to another runner"
		else
			RECOVERY_POLICY="retry_same_runner"
			RECOVERY_NEXT_ACTION="resume_with_targeted_fix"
			RECOVERY_POLICY_REASON="first verification failure should retry with precise evidence"
		fi
		;;
	scope_confusion)
		if [[ "$size" == "large" || "$size" == "l" || "$size" == "xl" || "$size" == "huge" ]] && ((streak >= 2 || attempts >= 2)); then
			RECOVERY_POLICY="replan_split"
			RECOVERY_NEXT_ACTION="split_task"
			RECOVERY_POLICY_REASON="repeated oversized failures should split into smaller tasks"
		elif ((streak >= 2 || attempts >= 2)); then
			RECOVERY_POLICY="retry_alternate_runner"
			RECOVERY_NEXT_ACTION="resume_with_alternate_runner"
			RECOVERY_POLICY_REASON="repeated scope confusion should escalate to another runner"
		else
			RECOVERY_POLICY="retry_same_runner"
			RECOVERY_NEXT_ACTION="clarify_scope_and_resume"
			RECOVERY_POLICY_REASON="first scope confusion gets one focused retry"
		fi
		;;
	*)
		RECOVERY_POLICY="retry_same_runner"
		RECOVERY_NEXT_ACTION="resume_with_targeted_fix"
		RECOVERY_POLICY_REASON="default recovery policy retries the same runner once"
		;;
	esac

	printf '%s\n' "$RECOVERY_POLICY"
}

recovery_task_update_state() {
	local task_id=$1
	local failure_class=${2:-$RECOVERY_FAILURE_CLASS}
	local check_file=${3:-}
	failure_class=$(recovery_normalize_failure_class "$failure_class")
	recovery_policy_for_class "$task_id" "$failure_class" >/dev/null

	local previous_class previous_streak summary
	previous_class=$(recovery_normalize_failure_class "$(task_get "$task_id" "failure_class" "")")
	previous_streak=$(task_get "$task_id" "failure_streak" "0")
	[[ "$previous_streak" =~ ^[0-9]+$ ]] || previous_streak=0
	if [[ -n "$failure_class" && "$failure_class" == "$previous_class" ]]; then
		previous_streak=$((previous_streak + 1))
	else
		previous_streak=1
	fi
	summary=$(recovery_failure_summary "$failure_class")
	if [[ -n "$check_file" ]]; then
		task_set "$task_id" "failure_check_file" "$check_file"
	fi
	task_set "$task_id" "failure_class" "$failure_class"
	task_set "$task_id" "failure_summary" "$summary"
	task_set "$task_id" "failure_streak" "$previous_streak"
	task_set "$task_id" "recovery_policy" "$RECOVERY_POLICY"
	task_set "$task_id" "recovery_next_action" "$RECOVERY_NEXT_ACTION"
	task_set "$task_id" "last_failure_reason" "$failure_class"
	task_set "$task_id" "recovery_policy_reason" "$RECOVERY_POLICY_REASON"
	RECOVERY_FAILURE_CLASS="$failure_class"
	RECOVERY_FAILURE_SUMMARY="$summary"
	RECOVERY_FAILURE_STREAK="$previous_streak"
}

recovery_clear_task_state() {
	local task_id=$1
	task_set "$task_id" "failure_class" ""
	task_set "$task_id" "failure_summary" ""
	task_set "$task_id" "failure_streak" "0"
	task_set "$task_id" "failure_check_file" ""
	task_set "$task_id" "recovery_policy" ""
	task_set "$task_id" "recovery_next_action" ""
	task_set "$task_id" "recovery_policy_reason" ""
	task_set "$task_id" "last_failure_reason" ""
}

recovery_policy_allows_auto_retry() {
	local policy=${1:-}
	case "$policy" in
	retry_same_runner | retry_alternate_runner | replan_split)
		return 0
		;;
	esac
	return 1
}

recovery_resume_reason_for_task() {
	local task_id=$1
	local failure_class policy summary
	failure_class=$(recovery_normalize_failure_class "$(task_get "$task_id" "failure_class" "")")
	policy=$(task_get "$task_id" "recovery_policy" "")
	summary=$(task_get "$task_id" "failure_summary" "")
	[[ -n "$summary" ]] || summary=$(recovery_failure_summary "$failure_class")
	case "$policy" in
	retry_alternate_runner)
		printf 'recovery escalation: %s (%s)\n' "$failure_class" "$summary"
		;;
	replan_split)
		printf 'recovery replan: %s (%s)\n' "$failure_class" "$summary"
		;;
	*)
		printf 'recovery retry: %s (%s)\n' "$failure_class" "$summary"
		;;
	esac
}

recovery_select_runner() {
	local task_id=$1
	local default_runner=${2:-}
	local current_runner=${3:-}
	local previous_runner policy selected fallback_count
	policy=$(task_get "$task_id" "recovery_policy" "")
	previous_runner=$(task_get "$task_id" "last_runner" "")
	fallback_count=$(task_get "$task_id" "routing_fallback_count" "0")
	[[ "$fallback_count" =~ ^[0-9]+$ ]] || fallback_count=0

	if [[ "$policy" == "retry_alternate_runner" ]]; then
		swarm_select_alternate_runner_for_role "recovery" "$current_runner" "$default_runner" >/dev/null
		selected="$SWARM_ROUTE_SELECTED_RUNNER"
		if [[ -z "$selected" || "$selected" == "none" || "$selected" == "$current_runner" ]]; then
			swarm_resolve_route "recovery" "$default_runner" >/dev/null
			selected="$SWARM_ROUTE_SELECTED_RUNNER"
		fi
	else
		swarm_resolve_route "recovery" "$default_runner" >/dev/null
		selected="$SWARM_ROUTE_SELECTED_RUNNER"
	fi

	if [[ -z "$selected" || "$selected" == "none" ]]; then
		selected="$current_runner"
		SWARM_ROUTE_ROLE="recovery"
		SWARM_ROUTE_DEFAULT_RUNNER="$default_runner"
		SWARM_ROUTE_CANDIDATES="$(swarm_role_candidates_csv "recovery")"
		SWARM_ROUTE_PREFERRED_RUNNER="$current_runner"
		SWARM_ROUTE_SELECTED_RUNNER="$selected"
		SWARM_ROUTE_FALLBACK_USED="false"
		SWARM_ROUTE_REASON="reusing existing runner ${current_runner} for recovery"
	fi

	if [[ -n "$selected" && "$selected" != "$current_runner" && "$selected" != "$previous_runner" ]]; then
		fallback_count=$((fallback_count + 1))
	fi
	task_set "$task_id" "routing_fallback_count" "$fallback_count"
	printf '%s\n' "$selected"
}
