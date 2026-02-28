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
	runner_config=$(config_get "runner" "")
	runner_effective=$(detect_runner)
	base_branch=$(config_get "base_branch" "main")
	worktree_dir=$(config_get "worktree_dir" ".worktrees")
	max_parallel=$(config_get "max_parallel" "3")

	local lint_cmd test_cmd build_cmd
	lint_cmd=$(config_get "lint_cmd" "")
	test_cmd=$(config_get "test_cmd" "")
	build_cmd=$(config_get "build_cmd" "")

	quality_detect_cmds "$PROJECT_ROOT"

	local eff_lint eff_test eff_build
	eff_lint="${lint_cmd:-$ORCHD_DETECTED_LINT_CMD}"
	eff_test="${test_cmd:-$ORCHD_DETECTED_TEST_CMD}"
	eff_build="${build_cmd:-$ORCHD_DETECTED_BUILD_CMD}"

	printf '== orchd doctor ==\n'
	printf 'project: %s\n' "$PROJECT_ROOT"
	printf 'config:  %s\n' "$PROJECT_ROOT/.orchd.toml"
	printf 'runner:  %s\n' "$runner_effective"
	if [[ -n "$runner_config" ]]; then
		printf 'runner (config): %s\n' "$runner_config"
	else
		printf 'runner (config): <auto>\n'
	fi
	printf 'base_branch:   %s\n' "$base_branch"
	printf 'worktree_dir:  %s\n' "$worktree_dir"
	printf 'max_parallel:  %s\n' "$max_parallel"

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
}
