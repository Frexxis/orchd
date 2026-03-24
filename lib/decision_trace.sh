#!/usr/bin/env bash
# lib/decision_trace.sh - Shared scheduler decision helpers
# Sourced by bin/orchd — do not execute directly.

scheduler_decision_reason() {
	local action=$1
	local merge_ready=${2:-0}
	local check_ready=${3:-0}
	local spawn_ready=${4:-0}
	local recover_ready=${5:-0}
	local ideate_ready=${6:-0}

	case "$action" in
	complete)
		printf 'no actionable work remains; completion is eligible\n'
		;;
	blocked)
		printf 'only genuine blocker states remain; waiting for human input\n'
		;;
	merge)
		printf 'merge-ready work exists (%s task(s))\n' "$merge_ready"
		;;
	check)
		printf 'completed worker sessions need checking (%s task(s))\n' "$check_ready"
		;;
	spawn)
		printf 'ready tasks can be spawned (%s task(s))\n' "$spawn_ready"
		;;
	recover)
		printf 'failed or conflicted work can be resumed (%s task(s))\n' "$recover_ready"
		;;
	ideate)
		printf 'no active task work remains; backlog/ideation work exists (%s item(s))\n' "$ideate_ready"
		;;
	wait)
		printf 'no higher-priority action is ready; safe to wait\n'
		;;
	*)
		printf 'scheduler action %s selected\n' "$action"
		;;
	esac
}

scheduler_next_action() {
	local merge_ready=${1:-0}
	local check_ready=${2:-0}
	local spawn_ready=${3:-0}
	local recover_ready=${4:-0}
	local ideate_ready=${5:-0}
	local blocked_only=${6:-false}
	local completion_eligible=${7:-false}
	local action="wait"

	if [[ "$completion_eligible" == "true" ]]; then
		action="complete"
	elif [[ "$blocked_only" == "true" ]]; then
		action="blocked"
	elif ((merge_ready > 0)); then
		action="merge"
	elif ((check_ready > 0)); then
		action="check"
	elif ((spawn_ready > 0)); then
		action="spawn"
	elif ((recover_ready > 0)); then
		action="recover"
	elif ((ideate_ready > 0)); then
		action="ideate"
	fi

	SCHEDULER_ACTION="$action"
	SCHEDULER_REASON=$(scheduler_decision_reason "$action" "$merge_ready" "$check_ready" "$spawn_ready" "$recover_ready" "$ideate_ready")
	printf '%s\n' "$action"
}

_scheduler_trace_dir() {
	printf '%s/scheduler\n' "$ORCHD_DIR"
}

scheduler_record_decision() {
	local scope=$1
	local action=$2
	local reason=$3
	local trace_dir scope_action_file scope_reason_file scope_updated_file existing_action existing_reason
	trace_dir=$(_scheduler_trace_dir)
	scope_action_file="$trace_dir/${scope}.action"
	scope_reason_file="$trace_dir/${scope}.reason"
	scope_updated_file="$trace_dir/${scope}.updated_at"
	mkdir -p "$(_scheduler_trace_dir)"
	existing_action=$(cat "$scope_action_file" 2>/dev/null || true)
	existing_reason=$(cat "$scope_reason_file" 2>/dev/null || true)
	if [[ "$existing_action" != "$action" || "$existing_reason" != "$reason" || ! -f "$scope_updated_file" ]]; then
		printf '%s\n' "$action" >"$scope_action_file"
		printf '%s\n' "$reason" >"$scope_reason_file"
		printf '%s\n' "$(now_iso)" >"$scope_updated_file"
	fi
	if [[ "$scope" == "orchestrate" ]]; then
		if [[ "$(cat "$trace_dir/last_action" 2>/dev/null || true)" != "$action" ]]; then
			printf '%s\n' "$action" >"$trace_dir/last_action"
		fi
		if [[ "$(cat "$trace_dir/last_reason" 2>/dev/null || true)" != "$reason" ]]; then
			printf '%s\n' "$reason" >"$trace_dir/last_reason"
		fi
	fi
}
