#!/usr/bin/env bash
# lib/verify.sh - Adaptive verification tier selection
# Sourced by bin/orchd — do not execute directly.

verify_select_tier() {
	local task_id=$1
	local recommended risk
	recommended=$(printf '%s' "$(task_get "$task_id" "recommended_verification" "")" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
	risk=$(printf '%s' "$(task_get "$task_id" "risk" "")" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')

	case "$recommended" in
	smoke | targeted | full)
		VERIFY_SELECTED_TIER="$recommended"
		VERIFY_TIER_REASON="task requests ${recommended} verification"
		printf '%s\n' "$VERIFY_SELECTED_TIER"
		return 0
		;;
	esac

	case "$risk" in
	low | trivial)
		VERIFY_SELECTED_TIER="smoke"
		VERIFY_TIER_REASON="low-risk task defaults to smoke verification"
		;;
	medium | med | "")
		VERIFY_SELECTED_TIER="targeted"
		VERIFY_TIER_REASON="medium-risk task defaults to targeted verification"
		;;
	high | critical)
		VERIFY_SELECTED_TIER="full"
		VERIFY_TIER_REASON="high-risk task escalates to full verification"
		;;
	*)
		VERIFY_SELECTED_TIER="targeted"
		VERIFY_TIER_REASON="unknown risk defaults to targeted verification"
		;;
	esac

	printf '%s\n' "$VERIFY_SELECTED_TIER"
}

verify_tier_reason() {
	printf '%s\n' "${VERIFY_TIER_REASON:-verification tier not selected}"
}

verify_tier_rank() {
	local tier
	tier=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
	case "$tier" in
	smoke)
		printf '1\n'
		;;
	targeted)
		printf '2\n'
		;;
	full)
		printf '3\n'
		;;
	*)
		printf '0\n'
		;;
	esac
}

verify_required_merge_tier() {
	local task_id=$1
	local risk
	risk=$(printf '%s' "$(task_get "$task_id" "risk" "")" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
	case "$risk" in
	low | trivial)
		printf 'smoke\n'
		;;
	high | critical)
		printf 'full\n'
		;;
	*)
		printf 'targeted\n'
		;;
	esac
}

verify_merge_requires_review() {
	local task_id=$1
	local risk blast_radius
	risk=$(printf '%s' "$(task_get "$task_id" "risk" "")" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
	blast_radius=$(printf '%s' "$(task_get "$task_id" "blast_radius" "")" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
	case "$risk:$blast_radius" in
	high:* | critical:* | *:wide | *:large)
		return 0
		;;
	esac
	return 1
}

verify_merge_accepts_task() {
	local task_id=$1
	local actual_tier required_tier actual_rank required_rank review_status review_required=false checked_at risk
	actual_tier=$(printf '%s' "$(task_get "$task_id" "verification_tier" "")" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
	required_tier=$(verify_required_merge_tier "$task_id")
	actual_rank=$(verify_tier_rank "$actual_tier")
	required_rank=$(verify_tier_rank "$required_tier")
	review_status=$(printf '%s' "$(task_get "$task_id" "review_status" "")" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
	checked_at=$(task_get "$task_id" "checked_at" "")
	risk=$(printf '%s' "$(task_get "$task_id" "risk" "")" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
	if verify_merge_requires_review "$task_id"; then
		review_required=true
	fi

	VERIFY_MERGE_ALLOWED=false
	VERIFY_MERGE_REQUIRED_TIER="$required_tier"
	VERIFY_MERGE_REVIEW_REQUIRED="$review_required"
	VERIFY_MERGE_REASON=""

	if [[ -z "$checked_at" && -z "$risk" && -z "$actual_tier" ]]; then
		VERIFY_MERGE_ALLOWED=true
		VERIFY_MERGE_REASON="legacy done task has no recorded verification metadata; allowing merge"
		return 0
	fi

	if [[ -z "$checked_at" ]]; then
		VERIFY_MERGE_REASON="task has not passed orchd check yet"
		return 1
	fi

	if ((actual_rank >= required_rank)); then
		VERIFY_MERGE_ALLOWED=true
		VERIFY_MERGE_REASON="verification tier ${actual_tier} satisfies merge requirement ${required_tier}"
		return 0
	fi

	if $review_required && [[ "$review_status" == "approved" ]] && ((actual_rank >= 2)); then
		VERIFY_MERGE_ALLOWED=true
		VERIFY_MERGE_REASON="review approval compensates for verification tier ${actual_tier} on risky task"
		return 0
	fi

	if $review_required; then
		VERIFY_MERGE_REASON="merge requires ${required_tier} verification or approved review for this risk profile"
	else
		VERIFY_MERGE_REASON="merge requires at least ${required_tier} verification; found ${actual_tier:-none}"
	fi
	return 1
}

verify_select_commands() {
	local task_id=$1
	local lint_cmd=${2:-}
	local test_cmd=${3:-}
	local build_cmd=${4:-}

	verify_select_tier "$task_id" >/dev/null
	VERIFY_SELECTED_LINT_CMD=""
	VERIFY_SELECTED_TEST_CMD=""
	VERIFY_SELECTED_BUILD_CMD=""

	case "$VERIFY_SELECTED_TIER" in
	smoke)
		if [[ -n "$lint_cmd" ]]; then
			VERIFY_SELECTED_LINT_CMD="$lint_cmd"
		elif [[ -n "$test_cmd" ]]; then
			VERIFY_SELECTED_TEST_CMD="$test_cmd"
		elif [[ -n "$build_cmd" ]]; then
			VERIFY_SELECTED_BUILD_CMD="$build_cmd"
		fi
		;;
	targeted)
		VERIFY_SELECTED_LINT_CMD="$lint_cmd"
		VERIFY_SELECTED_TEST_CMD="$test_cmd"
		;;
	full)
		VERIFY_SELECTED_LINT_CMD="$lint_cmd"
		VERIFY_SELECTED_TEST_CMD="$test_cmd"
		VERIFY_SELECTED_BUILD_CMD="$build_cmd"
		;;
	esac

	printf '%s\n' "$VERIFY_SELECTED_TIER"
}
