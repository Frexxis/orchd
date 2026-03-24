#!/usr/bin/env bash
# lib/swarm.sh - Swarm role routing and runner fallback helpers
# Sourced by bin/orchd — do not execute directly.

swarm_policy_allows_fallback() {
	local raw
	raw=$(config_get "swarm.policy.allow_fallback" "true")
	if is_truthy "$raw"; then
		return 0
	fi
	return 1
}

swarm_role_candidates() {
	local role=$1
	config_get_list "swarm.roles.${role}"
}

swarm_role_candidates_csv() {
	local role=$1
	local out=""
	local candidate
	while IFS= read -r candidate; do
		[[ -n "$candidate" ]] || continue
		if [[ -n "$out" ]]; then
			out+=","
		fi
		out+="$candidate"
	done <<<"$(swarm_role_candidates "$role")"
	printf '%s\n' "$out"
}

swarm_resolve_route() {
	local role=$1
	local default_runner=${2:-}
	local candidate=""
	local normalized=""
	local candidates_csv=""
	local preferred_runner=""
	local selected_runner=""
	local reason=""
	local fallback_used=false
	local allow_fallback=false

	if swarm_policy_allows_fallback; then
		allow_fallback=true
	fi

	while IFS= read -r candidate; do
		candidate=$(_config_trim_spaces "$candidate")
		[[ -n "$candidate" ]] || continue
		normalized="$candidate"
		if [[ "$normalized" == "auto" ]]; then
			normalized=$(detect_runner)
		fi
		[[ -n "$normalized" && "$normalized" != "none" ]] || continue
		if ! swarm_runner_is_supported "$normalized"; then
			continue
		fi
		if [[ -n "$candidates_csv" ]]; then
			candidates_csv+=","
		fi
		candidates_csv+="$normalized"
		if [[ -z "$preferred_runner" ]]; then
			preferred_runner="$normalized"
		fi
		if ! $allow_fallback; then
			selected_runner="$normalized"
			reason="fallback disabled; using first configured runner for role ${role}"
			break
		fi
		if swarm_runner_is_available "$normalized"; then
			selected_runner="$normalized"
			break
		fi
	done <<<"$(swarm_role_candidates "$role")"

	if [[ -z "$selected_runner" && -n "$preferred_runner" && "$allow_fallback" == "false" ]]; then
		selected_runner="$preferred_runner"
	fi

	if [[ -z "$selected_runner" ]]; then
		if [[ -n "$default_runner" ]]; then
			selected_runner="$default_runner"
		else
			selected_runner=$(detect_runner)
		fi
		if [[ -n "$preferred_runner" ]]; then
			fallback_used=true
			reason="all configured runners unavailable for role ${role}; using default runner ${selected_runner}"
		else
			reason="no role-specific runners configured; using default runner ${selected_runner}"
		fi
	elif [[ -n "$preferred_runner" && "$selected_runner" != "$preferred_runner" ]]; then
		fallback_used=true
		reason="preferred runner ${preferred_runner} unavailable; fell back to ${selected_runner} for role ${role}"
	elif [[ -z "$reason" && -n "$preferred_runner" ]]; then
		reason="using preferred runner ${selected_runner} for role ${role}"
	fi

	SWARM_ROUTE_ROLE="$role"
	SWARM_ROUTE_DEFAULT_RUNNER="$default_runner"
	SWARM_ROUTE_CANDIDATES="$candidates_csv"
	SWARM_ROUTE_PREFERRED_RUNNER="$preferred_runner"
	SWARM_ROUTE_SELECTED_RUNNER="$selected_runner"
	SWARM_ROUTE_FALLBACK_USED="$fallback_used"
	SWARM_ROUTE_REASON="$reason"
	printf '%s\n' "$selected_runner"
}

swarm_runner_is_supported() {
	local runner=$1
	case "$runner" in
	auto | codex | claude | opencode | aider | custom)
		return 0
		;;
	*)
		return 1
		;;
	esac
}

swarm_runner_is_available() {
	local runner=$1
	local bin_path=""

	case "$runner" in
	auto)
		[[ "$(detect_runner)" != "none" ]]
		return
		;;
	custom)
		[[ -n "$(config_get_custom_runner_cmd)" ]]
		return
		;;
	codex)
		bin_path=$(config_get "codex_bin" "codex")
		;;
	claude)
		bin_path=$(config_get "claude_bin" "claude")
		;;
	opencode)
		bin_path=$(config_get "opencode_bin" "opencode")
		;;
	aider)
		bin_path=$(config_get "aider_bin" "aider")
		;;
	*)
		return 1
		;;
	esac

	[[ -n "$bin_path" ]] || return 1
	if [[ "$bin_path" == */* ]]; then
		[[ -x "$bin_path" ]]
	else
		command -v "$bin_path" >/dev/null 2>&1
	fi
}

swarm_select_runner_for_role() {
	local role=$1
	local default_runner=${2:-}
	swarm_resolve_route "$role" "$default_runner" >/dev/null
	printf '%s\n' "$SWARM_ROUTE_SELECTED_RUNNER"
}

swarm_select_alternate_runner_for_role() {
	local role=$1
	local exclude_runner=${2:-}
	local default_runner=${3:-}
	local candidate=""
	local selected_runner=""
	local candidates_csv=""
	local preferred_runner=""
	local fallback_used=false

	while IFS= read -r candidate; do
		candidate=$(_config_trim_spaces "$candidate")
		[[ -n "$candidate" ]] || continue
		if [[ "$candidate" == "auto" ]]; then
			candidate=$(detect_runner)
		fi
		[[ -n "$candidate" && "$candidate" != "none" ]] || continue
		if ! swarm_runner_is_supported "$candidate"; then
			continue
		fi
		if [[ -n "$candidates_csv" ]]; then
			candidates_csv+=","
		fi
		candidates_csv+="$candidate"
		if [[ -z "$preferred_runner" ]]; then
			preferred_runner="$candidate"
		fi
		if [[ -n "$exclude_runner" && "$candidate" == "$exclude_runner" ]]; then
			continue
		fi
		if swarm_runner_is_available "$candidate"; then
			selected_runner="$candidate"
			break
		fi
	done <<<"$(swarm_role_candidates "$role")"

	if [[ -z "$selected_runner" ]]; then
		fallback_used=true
		swarm_resolve_route "$role" "$default_runner" >/dev/null
		selected_runner="$SWARM_ROUTE_SELECTED_RUNNER"
		SWARM_ROUTE_REASON="no alternate runner available for role ${role}; using ${selected_runner}"
	else
		SWARM_ROUTE_ROLE="$role"
		SWARM_ROUTE_DEFAULT_RUNNER="$default_runner"
		SWARM_ROUTE_CANDIDATES="$candidates_csv"
		SWARM_ROUTE_PREFERRED_RUNNER="$preferred_runner"
		SWARM_ROUTE_SELECTED_RUNNER="$selected_runner"
		SWARM_ROUTE_FALLBACK_USED="$fallback_used"
		SWARM_ROUTE_REASON="using alternate runner ${selected_runner} for role ${role} instead of ${exclude_runner}"
	fi

	printf '%s\n' "$SWARM_ROUTE_SELECTED_RUNNER"
}

swarm_task_set_route_metadata() {
	local task_id=$1
	local route_role=$2
	local selected_runner=$3
	local default_runner=$4
	local reason=$5
	local fallback_used=$6
	local candidates_csv=$7
	task_set "$task_id" "routing_role" "$route_role"
	task_set "$task_id" "routing_selected_runner" "$selected_runner"
	task_set "$task_id" "routing_default_runner" "$default_runner"
	task_set "$task_id" "routing_reason" "$reason"
	task_set "$task_id" "routing_fallback_used" "$fallback_used"
	task_set "$task_id" "routing_candidates" "$candidates_csv"
}

_swarm_score_size() {
	local raw=${1:-}
	raw=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
	case "$raw" in
	xs | tiny)
		printf '5\n'
		;;
	s | small)
		printf '4\n'
		;;
	m | medium | "")
		printf '3\n'
		;;
	l | large)
		printf '2\n'
		;;
	xl | huge)
		printf '1\n'
		;;
	*)
		printf '3\n'
		;;
	esac
}

_swarm_score_risk() {
	local raw=${1:-}
	raw=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
	case "$raw" in
	low | trivial | "")
		printf '4\n'
		;;
	medium | med)
		printf '2\n'
		;;
	high)
		printf '0\n'
		;;
	critical)
		printf -- '-2\n'
		;;
	*)
		printf '1\n'
		;;
	esac
}

_swarm_score_verification_cost() {
	local raw=${1:-}
	raw=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
	case "$raw" in
	smoke | quick | "")
		printf '3\n'
		;;
	targeted | standard)
		printf '1\n'
		;;
	full | strict)
		printf -- '-1\n'
		;;
	*)
		printf '0\n'
		;;
	esac
}

_swarm_list_count() {
	local raw=${1:-}
	local count=0
	local item
	if [[ -z "$raw" ]] || [[ "$raw" == "none" ]]; then
		printf '0\n'
		return 0
	fi
	raw=${raw//$'\n'/,}
	while IFS=',' read -r -a items; do
		for item in "${items[@]}"; do
			item=$(printf '%s' "$item" | tr -d '[:space:]')
			[[ -n "$item" ]] || continue
			count=$((count + 1))
		done
	done <<<"$raw"
	printf '%s\n' "$count"
}

swarm_score_task_for_spawn() {
	local task_id=$1
	local size risk verification file_hints deps blast_radius
	local score=0

	size=$(task_get "$task_id" "size" "")
	risk=$(task_get "$task_id" "risk" "")
	verification=$(task_get "$task_id" "recommended_verification" "")
	file_hints=$(task_get "$task_id" "file_hints" "")
	deps=$(task_get "$task_id" "deps" "")
	blast_radius=$(task_get "$task_id" "blast_radius" "")

	score=$((score + $(_swarm_score_size "$size")))
	score=$((score + $(_swarm_score_risk "$risk")))
	score=$((score + $(_swarm_score_verification_cost "$verification")))

	local dep_count file_hint_count
	dep_count=$(_swarm_list_count "$deps")
	file_hint_count=$(_swarm_list_count "$file_hints")
	score=$((score - dep_count))
	if ((file_hint_count > 0)); then
		score=$((score - (file_hint_count - 1)))
	fi

	case "$(printf '%s' "$blast_radius" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" in
	wide | large)
		score=$((score - 2))
		;;
	medium)
		score=$((score - 1))
		;;
	esac

	printf '%s\n' "$score"
}

swarm_sort_ready_tasks() {
	local task_id score
	local input=""
	if (($# > 0)); then
		input=$(printf '%s\n' "$@")
	else
		input=$(cat)
		if [[ -z "$input" ]]; then
			input=$(task_list_ids)
		fi
	fi
	while IFS= read -r task_id; do
		[[ -z "$task_id" ]] || task_is_ready "$task_id" || continue
		score=$(swarm_score_task_for_spawn "$task_id")
		printf '%08d\t%s\n' "$((99999999 - score))" "$task_id"
	done <<<"$input" | sort -k1,1 -k2,2 | while IFS=$'\t' read -r _ task_id; do
		[[ -n "$task_id" ]] && printf '%s\n' "$task_id"
	done
}
