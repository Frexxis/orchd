#!/usr/bin/env bash
# lib/cmd/refresh_docs.sh - orchd refresh-docs command
# Refreshes AGENTS/WORKER/ORCHESTRATOR/CLAUDE docs in a project

cmd_refresh_docs() {
	local target="${1:-$PWD}"
	local start_dir=$PWD

	[[ -d "$target" ]] || die "repo_dir not found: $target"
	cd "$target" || die "repo_dir not found: $target"
	require_project
	cd "$start_dir" || true

	printf 'refreshing agent docs in %s\n' "$PROJECT_ROOT"
	refresh_agent_docs "$PROJECT_ROOT"
}
