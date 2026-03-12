#!/usr/bin/env bash
# lib/cmd/doctor.sh - orchd doctor command
# Displays effective config and auto-detected quality commands

cmd_doctor() {
	local target="${1:-$PWD}"
	local start_dir=$PWD

	[[ -d "$target" ]] || die "repo_dir not found: $target"
	cd "$target" || die "repo_dir not found: $target"
	require_project
	cd "$start_dir" || true

	local runner_config runner_effective base_branch worktree_dir max_parallel
	local profile autopilot_poll await_poll retry_backoff verification_profile post_merge_test
	runner_config=$(config_get "worker.runner" "")
	if [[ -z "$runner_config" ]]; then
		runner_config=$(config_get "orchestrator.runner" "")
	fi
	if [[ -z "$runner_config" ]]; then
		runner_config=$(config_get "runner" "")
	fi
	runner_effective=$(detect_runner)
	profile=$(orchd_profile)
	base_branch=$(config_get "base_branch" "main")
	worktree_dir=$(config_get "worktree_dir" ".worktrees")
	max_parallel=$(config_get_effective_int "max_parallel" "3")
	autopilot_poll=$(config_get_effective_int "autopilot_poll" "30")
	await_poll=$(config_get_effective_int "await_poll" "5")
	retry_backoff=$(config_get_effective_int "autopilot_retry_backoff" "60")
	verification_profile=$(config_get_effective "quality.verification_profile" "strict")
	post_merge_test=$(config_get_effective "quality.post_merge_test" "always")

	local lint_cmd test_cmd build_cmd
	lint_cmd=$(config_get "lint_cmd" "")
	test_cmd=$(config_get "test_cmd" "")
	build_cmd=$(config_get "build_cmd" "")

	local ideate_max_ideas ideate_cooldown ideate_max_cycles ideate_max_failures
	ideate_max_ideas=$(config_get_int "ideate.max_ideas" "5")
	ideate_cooldown=$(config_get_int "ideate.cooldown_seconds" "30")
	ideate_max_cycles=$(config_get_int "ideate.max_cycles" "20")
	ideate_max_failures=$(config_get_int "ideate.max_consecutive_failures" "3")

	quality_detect_cmds "$PROJECT_ROOT"

	local eff_lint eff_test eff_build
	eff_lint="${lint_cmd:-$ORCHD_DETECTED_LINT_CMD}"
	eff_test="${test_cmd:-$ORCHD_DETECTED_TEST_CMD}"
	eff_build="${build_cmd:-$ORCHD_DETECTED_BUILD_CMD}"

	printf '== orchd doctor ==\n'
	printf 'project: %s\n' "$PROJECT_ROOT"
	printf 'config:  %s\n' "$PROJECT_ROOT/.orchd.toml"
	printf 'runner:  %s\n' "$runner_effective"
	printf 'profile: %s\n' "$profile"
	if [[ -n "$runner_config" ]]; then
		printf 'runner (config): %s\n' "$runner_config"
	else
		printf 'runner (config): <auto>\n'
	fi
	printf 'base_branch:   %s\n' "$base_branch"
	printf 'worktree_dir:  %s\n' "$worktree_dir"
	printf 'max_parallel:  %s\n' "$max_parallel"
	printf 'autopilot_poll: %s\n' "$autopilot_poll"
	printf 'await_poll:    %s\n' "$await_poll"
	printf 'retry_backoff: %s\n' "$retry_backoff"

	printf '\nideate:\n'
	printf '  max_ideas:                 %s\n' "$ideate_max_ideas"
	printf '  cooldown_seconds:          %s\n' "$ideate_cooldown"
	printf '  max_cycles:                %s\n' "$ideate_max_cycles"
	printf '  max_consecutive_failures:  %s\n' "$ideate_max_failures"

	printf '\nquality (config):\n'
	printf '  lint_cmd:  %s\n' "${lint_cmd:-<auto>}"
	printf '  test_cmd:  %s\n' "${test_cmd:-<auto>}"
	printf '  build_cmd: %s\n' "${build_cmd:-<auto>}"

	printf '\nquality (auto-detect):\n'
	printf '  stack:     %s\n' "${ORCHD_DETECTED_STACK:-unknown}"
	printf '  lint_cmd:  %s\n' "${ORCHD_DETECTED_LINT_CMD:-<none>}"
	printf '  test_cmd:  %s\n' "${ORCHD_DETECTED_TEST_CMD:-<none>}"
	printf '  build_cmd: %s\n' "${ORCHD_DETECTED_BUILD_CMD:-<none>}"
	if [[ -n "$ORCHD_DETECTED_NOTES" ]]; then
		while IFS= read -r line; do
			[[ -n "$line" ]] && printf '  note: %s\n' "$line"
		done <<<"$ORCHD_DETECTED_NOTES"
	fi

	printf '\nquality (effective):\n'
	printf '  lint_cmd:  %s\n' "${eff_lint:-<none>}"
	printf '  test_cmd:  %s\n' "${eff_test:-<none>}"
	printf '  build_cmd: %s\n' "${eff_build:-<none>}"
	printf '  verification_profile: %s\n' "$verification_profile"
	printf '  post_merge_test:      %s\n' "$post_merge_test"
}
