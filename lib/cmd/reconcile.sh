#!/usr/bin/env bash
# lib/cmd/reconcile.sh - orchd reconcile command
# Reconciles orchd task state with git reality and local artifacts.

cmd_reconcile() {
	local dry_run=false
	local json=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--dry-run)
			dry_run=true
			shift
			;;
		--json)
			json=true
			shift
			;;
		-h | --help)
			cat <<'EOF'
usage:
  orchd reconcile [--dry-run] [--json]

notes:
  - marks tasks as merged if their branch is already an ancestor of base_branch
  - clears missing worktree paths
  - reports stale running tasks (agent exited) so you can run `orchd check`
EOF
			return 0
			;;
		*)
			die "unknown reconcile argument: $1"
			;;
		esac
	done

	require_project

	local base_branch
	base_branch=$(config_get "base_branch" "main")

	local changed=0
	local warnings=0
	local reports=""

	local task_id
	while IFS= read -r task_id; do
		[[ -z "$task_id" ]] && continue

		local status branch worktree
		status=$(task_status "$task_id")
		branch=$(task_get "$task_id" "branch" "agent-${task_id}")
		worktree=$(task_get "$task_id" "worktree" "")

		# Clear missing worktree references (common after manual cleanup).
		if [[ -n "$worktree" ]] && [[ ! -d "$worktree" ]]; then
			reports+="- $task_id: worktree missing -> clearing worktree field ($worktree)"$'\n'
			if ! $dry_run; then
				task_set "$task_id" "worktree" ""
			fi
			changed=$((changed + 1))
		fi

		# If a task branch is already merged into base, fix status.
		if git -C "$PROJECT_ROOT" rev-parse --verify "${branch}^{commit}" >/dev/null 2>&1; then
			if git -C "$PROJECT_ROOT" merge-base --is-ancestor "$branch" "$base_branch" >/dev/null 2>&1; then
				if [[ "$status" != "merged" ]]; then
					reports+="- $task_id: branch already merged ($branch -> $base_branch) -> status=merged"$'\n'
					if ! $dry_run; then
						task_set "$task_id" "status" "merged"
						task_set "$task_id" "merged_at" "$(now_iso)"
					fi
					changed=$((changed + 1))
				fi
			fi
		else
			# Branch missing but task says merged: warn only.
			if [[ "$status" == "merged" ]]; then
				reports+="- $task_id: warning: task marked merged but branch not found ($branch)"$'\n'
				warnings=$((warnings + 1))
			fi
		fi

		# Stale running tasks: agent session exited but status still running.
		if [[ "$status" == "running" ]] && ! runner_is_alive "$task_id"; then
			local exit_code
			exit_code=$(runner_exit_code "$task_id" 2>/dev/null || true)
			if [[ -n "$exit_code" ]]; then
				reports+="- $task_id: agent exited (exit=$exit_code) -> run: orchd check $task_id"$'\n'
			else
				reports+="- $task_id: agent session not alive and exit unknown (missing marker)"$'\n'
			fi
		fi
	done <<<"$(task_list_ids)"

	if [[ "$json" == "true" ]]; then
		_reconcile_json_escape() {
			local s=${1-}
			s=${s//\\/\\\\}
			s=${s//"/\\"/}
			s=${s//$'\n'/\\n}
			s=${s//$'\r'/\\r}
			s=${s//$'\t'/\\t}
			printf '%s' "$s"
		}
		printf '{'
		printf '"dry_run":%s,' "$dry_run"
		printf '"base_branch":"%s",' "$(_reconcile_json_escape "$base_branch")"
		printf '"changed":%d,' "$changed"
		printf '"warnings":%d,' "$warnings"
		reports=${reports%$'\n'}
		printf '"report":"%s"' "$(_reconcile_json_escape "$reports")"
		printf '}\n'
		return 0
	fi

	if $dry_run; then
		printf 'reconcile (dry-run)\n'
	else
		printf 'reconcile\n'
	fi
	printf '  base_branch: %s\n' "$base_branch"
	printf '  changes:     %d\n' "$changed"
	if ((warnings > 0)); then
		printf '  warnings:    %d\n' "$warnings"
	fi

	if [[ -n "$reports" ]]; then
		printf '\n%s' "$reports"
	else
		printf '\n(no changes)\n'
	fi
}
