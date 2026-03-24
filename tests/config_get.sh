#!/usr/bin/env bash
# config_get.sh - Regression tests for config_get parser behavior
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"

# shellcheck source=../lib/core.sh
source "$ROOT_DIR/lib/core.sh"
# shellcheck source=../lib/runner.sh
source "$ROOT_DIR/lib/runner.sh"
# shellcheck source=../lib/swarm.sh
source "$ROOT_DIR/lib/swarm.sh"

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
FAKE_BIN_DIR="$TMPDIR_CONFIG/fake-bin"
mkdir -p "$FAKE_BIN_DIR"
cat >"$FAKE_BIN_DIR/claude" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$FAKE_BIN_DIR/opencode" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$FAKE_BIN_DIR/claude" "$FAKE_BIN_DIR/opencode"
export PATH="$FAKE_BIN_DIR:$PATH"

cat >"$TMPDIR_CONFIG/.orchd.toml" <<'EOF'
name = "top-level"

[project]
name = "project-name"
base_branch = "main"

[worker]
runner = "claude"

[swarm.policy]
optimize_for = "speed"
allow_fallback = true

[swarm.roles]
planner = ["codex", "claude", "opencode"]
builder = ["codex", "opencode"]
reviewer = "claude"
recovery = ["codex", "opencode"]

[swarm.capabilities.claude]
tags = ["long_context", "strong_review", "interactive_resume"]

[orchestrator]
runner = "codex"
max_parallel = 4

[quality]
test_cmd = "npm test"

[runners.custom]
name = "custom-name"
runner = "custom-runner"
custom_runner_cmd = "my-agent --worktree {worktree} --prompt {prompt}"

[runners.codex]
codex_bin = "__MISSING_CODEX__"
EOF

python - "$TMPDIR_CONFIG/.orchd.toml" "$TMPDIR_CONFIG/missing-codex" <<'PY'
from pathlib import Path
import sys

cfg = Path(sys.argv[1])
missing = sys.argv[2]
cfg.write_text(cfg.read_text().replace("__MISSING_CODEX__", missing))
PY

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

join_lines_csv() {
	awk 'NF { if (out != "") out = out ","; out = out $0 } END { print out }'
}

printf '\n[4] Swarm config parsing\n'
assert_eq "swarm policy optimize_for lookup works" "speed" "$(config_get "swarm.policy.optimize_for" "")"
assert_eq "swarm policy boolean lookup works" "true" "$(config_get "swarm.policy.allow_fallback" "")"
assert_eq "swarm roles planner raw array lookup works" '["codex", "claude", "opencode"]' "$(config_get "swarm.roles.planner" "")"
assert_eq "swarm capability tags raw array lookup works" '["long_context", "strong_review", "interactive_resume"]' "$(config_get "swarm.capabilities.claude.tags" "")"
assert_eq "config_get_list parses planner role array" "codex,claude,opencode" "$(config_get_list "swarm.roles.planner" | join_lines_csv)"
assert_eq "config_get_list parses capability tags" "long_context,strong_review,interactive_resume" "$(config_get_list "swarm.capabilities.claude.tags" | join_lines_csv)"
assert_eq "config_get_list treats singleton string as one item" "claude" "$(config_get_list "swarm.roles.reviewer" | join_lines_csv)"
assert_eq "config_get_list preserves worker runner fallback" "claude" "$(config_get_list "worker.runner" | join_lines_csv)"

printf '\n[5] Swarm role routing\n'
assert_eq "planner role falls back from unavailable codex to claude" "claude" "$(swarm_select_runner_for_role "planner" "none")"
assert_eq "builder role falls back from unavailable codex to opencode" "opencode" "$(swarm_select_runner_for_role "builder" "none")"
assert_eq "reviewer role uses singleton runner" "claude" "$(swarm_select_runner_for_role "reviewer" "none")"
assert_eq "recovery role falls back to configured opencode" "opencode" "$(swarm_select_runner_for_role "recovery" "none")"
assert_eq "unconfigured role falls back to detected runner" "claude" "$(swarm_select_runner_for_role "architect" "claude")"

printf '\n=== Results: %d passed, %d failed, %d total ===\n' "$PASS" "$FAIL" "$TOTAL"

if ((FAIL > 0)); then
	exit 1
fi
