#!/usr/bin/env bash
# config_get.sh - Regression tests for config_get parser behavior
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"

# shellcheck source=../lib/core.sh
source "$ROOT_DIR/lib/core.sh"

PASS=0
FAIL=0
TOTAL=0

pass() {
	PASS=$((PASS + 1))
	TOTAL=$((TOTAL + 1))
	printf '  PASS: %s\n' "$1"
}

fail() {
	FAIL=$((FAIL + 1))
	TOTAL=$((TOTAL + 1))
	printf '  FAIL: %s\n' "$1" >&2
}

assert_eq() {
	local desc=$1
	local expected=$2
	local actual=$3
	if [[ "$actual" == "$expected" ]]; then
		pass "$desc"
	else
		fail "$desc (expected '$expected', got '$actual')"
	fi
}

cleanup() {
	if [[ -n "${TMPDIR_CONFIG:-}" ]] && [[ -d "$TMPDIR_CONFIG" ]]; then
		rm -rf "$TMPDIR_CONFIG"
	fi
}

trap cleanup EXIT

printf '=== config_get regression tests ===\n\n'

TMPDIR_CONFIG=$(mktemp -d)
cat >"$TMPDIR_CONFIG/.orchd.toml" <<'EOF'
name = "top-level"

[project]
name = "project-name"
base_branch = "main"

[worker]
runner = "claude"

[orchestrator]
runner = "codex"
max_parallel = 4

[quality]
test_cmd = "npm test"

[runners.custom]
name = "custom-name"
runner = "custom-runner"
custom_runner_cmd = "my-agent --worktree {worktree} --prompt {prompt}"
EOF

export PROJECT_ROOT="$TMPDIR_CONFIG"

printf '[1] Unscoped key precedence\n'
assert_eq "runner resolves to worker section" "claude" "$(config_get "runner" "")"
assert_eq "base_branch resolves to project section" "main" "$(config_get "base_branch" "")"
assert_eq "quality key resolves correctly" "npm test" "$(config_get "test_cmd" "")"
assert_eq "unknown key uses default" "fallback" "$(config_get "does_not_exist" "fallback")"

printf '\n[2] Explicit section addressing\n'
assert_eq "project.name lookup works" "project-name" "$(config_get "project.name" "")"
assert_eq "worker.runner lookup works" "claude" "$(config_get "worker.runner" "")"
assert_eq "orchestrator.runner lookup works" "codex" "$(config_get "orchestrator.runner" "")"
assert_eq "runners.custom.name lookup works" "custom-name" "$(config_get "runners.custom.name" "")"
assert_eq "runners.custom.runner lookup works" "custom-runner" "$(config_get "runners.custom.runner" "")"

printf '\n[3] Value parsing\n'
assert_eq "string value keeps spaces" "my-agent --worktree {worktree} --prompt {prompt}" "$(config_get "custom_runner_cmd" "")"
assert_eq "numeric value parsed as text" "4" "$(config_get "max_parallel" "")"

printf '\n=== Results: %d passed, %d failed, %d total ===\n' "$PASS" "$FAIL" "$TOTAL"

if ((FAIL > 0)); then
	exit 1
fi
