#!/usr/bin/env bash
# smoke.sh - Basic smoke tests for orchd
set -euo pipefail

resolve_path() {
	local target=$1
	if command -v realpath >/dev/null 2>&1; then
		realpath "$target"
	else
		local dir
		dir=$(dirname "$target")
		printf '%s/%s\n' "$(cd "$dir" && pwd -P)" "$(basename "$target")"
	fi
}

ORCHD="$(resolve_path "$(dirname "$0")/../bin/orchd")"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
PASS=0
FAIL=0
TOTAL=0

# Isolate monitor state from the user's home directory.
ORCHD_TEST_STATE_DIR=$(mktemp -d)
export ORCHD_STATE_DIR="$ORCHD_TEST_STATE_DIR"
trap 'rm -rf "$ORCHD_TEST_STATE_DIR"' EXIT

# --- Helpers ---

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

assert_exit_0() {
	local desc=$1
	shift
	if "$@" >/dev/null 2>&1; then
		pass "$desc"
	else
		fail "$desc (exit $?)"
	fi
}

assert_exit_nonzero() {
	local desc=$1
	shift
	if "$@" >/dev/null 2>&1; then
		fail "$desc (expected nonzero, got 0)"
	else
		pass "$desc"
	fi
}

assert_output_contains() {
	local desc=$1
	shift
	local pattern=$1
	shift
	local output
	output=$("$@" 2>&1) || true
	if printf '%s' "$output" | grep -q -- "$pattern"; then
		pass "$desc"
	else
		fail "$desc (pattern '$pattern' not found in output)"
	fi
}

run_in_dir() {
	local dir=$1
	shift
	(cd "$dir" && "$@")
}

set_test_cmd() {
	local cfg=$1
	local cmd=$2
	local tmp
	tmp=$(mktemp)
	awk -v cmd="$cmd" '
		/^[[:space:]]*test_cmd[[:space:]]*=/ {
			print "test_cmd = \"" cmd "\""
			next
		}
		{ print }
	' "$cfg" >"$tmp"
	mv "$tmp" "$cfg"
}

set_config_value() {
	local cfg=$1
	local section=$2
	local key=$3
	local value=$4
	python - "$cfg" "$section" "$key" "$value" <<'PY'
from pathlib import Path
import sys

cfg_path = Path(sys.argv[1])
section = sys.argv[2]
key = sys.argv[3]
value = sys.argv[4]
lines = cfg_path.read_text().splitlines()
out = []
current = ""
updated = False

for line in lines:
    stripped = line.strip()
    if stripped.startswith("[") and stripped.endswith("]"):
        current = stripped[1:-1].strip()
        out.append(line)
        continue
    if current == section and stripped.startswith(f"{key} ") and "=" in stripped and not updated:
        indent = line[: len(line) - len(line.lstrip())]
        out.append(f"{indent}{key} = {value}")
        updated = True
        continue
    out.append(line)

if not updated:
    if out and out[-1] != "":
        out.append("")
    out.append(f"[{section}]")
    out.append(f"{key} = {value}")

cfg_path.write_text("\n".join(out) + "\n")
PY
}

assert_task_status() {
	local desc=$1
	local repo_dir=$2
	local task_id=$3
	local expected=$4
	local file="$repo_dir/.orchd/tasks/$task_id/status"

	if [[ ! -f "$file" ]]; then
		fail "$desc (missing $file)"
		return
	fi

	local actual
	actual=$(<"$file")
	if [[ "$actual" == "$expected" ]]; then
		pass "$desc"
	else
		fail "$desc (expected '$expected', got '$actual')"
	fi
}

get_base_branch() {
	local repo_dir=$1
	local cfg="$repo_dir/.orchd.toml"
	awk -F '=' '
		/^[[:space:]]*base_branch[[:space:]]*=/ {
			val = $2
			gsub(/^[[:space:]]*"?|"?[[:space:]]*$/, "", val)
			print val
			exit
		}
	' "$cfg"
}

cleanup() {
	# Stop any test sessions
	tmux kill-session -t "orchd-smoketest" 2>/dev/null || true
	tmux kill-session -t "orchd-test-await-live" 2>/dev/null || true
	tmux kill-session -t "orchd-test-await-stale" 2>/dev/null || true
	tmux kill-session -t "orchd-test-reconcile-stale" 2>/dev/null || true
	tmux kill-session -t "orchd-agent-resume-stale" 2>/dev/null || true
	# Remove temp repo
	if [[ -n "${TMPDIR:-}" && -d "$TMPDIR" ]]; then
		rm -rf "$TMPDIR"
	fi
	# Remove test state
	rm -rf "${HOME}/.orchd/orchd-smoketest"
	# Remove init test dir
	if [[ -n "${INIT_DIR:-}" && -d "$INIT_DIR" ]]; then
		rm -rf "$INIT_DIR"
	fi
	if [[ -n "${LIFE_DIR:-}" && -d "$LIFE_DIR" ]]; then
		rm -rf "$LIFE_DIR"
	fi
	if [[ -n "${CLAUDE_DIR:-}" && -d "$CLAUDE_DIR" ]]; then
		rm -rf "$CLAUDE_DIR"
	fi
	if [[ -n "${CLAUDE_STICKY_DIR:-}" && -d "$CLAUDE_STICKY_DIR" ]]; then
		rm -rf "$CLAUDE_STICKY_DIR"
	fi
	if [[ -n "${CLAUDE_AUTO_FALLBACK_DIR:-}" && -d "$CLAUDE_AUTO_FALLBACK_DIR" ]]; then
		rm -rf "$CLAUDE_AUTO_FALLBACK_DIR"
	fi
	if [[ -n "${ROUTE_DIR:-}" && -d "$ROUTE_DIR" ]]; then
		rm -rf "$ROUTE_DIR"
	fi
	if [[ -n "${ORCH_ROUTE_DIR:-}" && -d "$ORCH_ROUTE_DIR" ]]; then
		rm -rf "$ORCH_ROUTE_DIR"
	fi
}

trap cleanup EXIT

# --- Setup ---

printf '=== orchd smoke tests ===\n\n'

# Check dependencies first
for dep in git tmux; do
	if ! command -v "$dep" >/dev/null 2>&1; then
		printf 'SKIP: %s not installed\n' "$dep"
		exit 0
	fi
done

# Create a temporary git repo
TMPDIR=$(mktemp -d)
git -C "$TMPDIR" init -q
git -C "$TMPDIR" config user.name "orchd-test"
git -C "$TMPDIR" config user.email "test@orchd.dev"
git -C "$TMPDIR" commit --allow-empty -m "init" -q

# --- Tests ---

printf '[1] Help and usage\n'
assert_exit_0 "orchd --help exits 0" "$ORCHD" --help
assert_exit_0 "orchd help exits 0" "$ORCHD" help
assert_exit_0 "orchd (no args) exits 0" "$ORCHD"
assert_output_contains "help output contains orchd" "orchestrator" "$ORCHD" --help

printf '\n[2] Input validation\n'
assert_exit_nonzero "start with bad dir fails" "$ORCHD" start /nonexistent/path
assert_exit_nonzero "start with bad interval fails" "$ORCHD" start "$TMPDIR" abc
assert_exit_nonzero "attach without session fails" "$ORCHD" attach
assert_exit_nonzero "stop without session fails" "$ORCHD" stop
assert_exit_nonzero "status without session fails" "$ORCHD" status
assert_exit_nonzero "unknown command fails" "$ORCHD" foobar
assert_exit_0 "spawn --help exits 0" "$ORCHD" spawn --help

printf '\n[3] List (no sessions)\n'
assert_exit_0 "list exits 0" "$ORCHD" list

printf '\n[4] Start / list / status / stop lifecycle\n'
export ORCHD_SESSION="orchd-smoketest"

assert_exit_0 "start succeeds" "$ORCHD" start "$TMPDIR" 60
sleep 1

# Verify session is listed
assert_output_contains "list shows session" "orchd-smoketest" "$ORCHD" list

# Verify status works
assert_output_contains "status shows running" "running" "$ORCHD" status orchd-smoketest

# Stop it
assert_exit_0 "stop succeeds" "$ORCHD" stop orchd-smoketest
sleep 1

# Verify it's gone
assert_exit_nonzero "status after stop fails" "$ORCHD" status orchd-smoketest

printf '\n[5] Double-start prevention\n'
export ORCHD_SESSION="orchd-smoketest"
assert_exit_0 "start for double-test" "$ORCHD" start "$TMPDIR" 60
sleep 1
assert_exit_nonzero "double start is rejected" "$ORCHD" start "$TMPDIR" 60
"$ORCHD" stop orchd-smoketest >/dev/null 2>&1 || true

printf '\n[6] Init command\n'
INIT_DIR=$(mktemp -d)
git -C "$INIT_DIR" init -q
git -C "$INIT_DIR" config user.name "orchd-test"
git -C "$INIT_DIR" config user.email "test@orchd.dev"
git -C "$INIT_DIR" commit --allow-empty -m "init" -q

assert_exit_0 "init succeeds" "$ORCHD" init "$INIT_DIR"
assert_exit_nonzero "double init is rejected" "$ORCHD" init "$INIT_DIR"
BASE_BRANCH=$(get_base_branch "$INIT_DIR")
if [[ -z "$BASE_BRANCH" ]]; then
	BASE_BRANCH="main"
fi

# Verify files were created
if [[ -f "$INIT_DIR/.orchd.toml" ]]; then
	pass "config file created"
else
	fail "config file not created"
fi

if [[ -d "$INIT_DIR/.orchd/tasks" ]]; then
	pass "state directory created"
else
	fail "state directory not created"
fi

if [[ -f "$INIT_DIR/.gitignore" ]] && grep -q '.orchd/' "$INIT_DIR/.gitignore"; then
	pass ".gitignore updated"
else
	fail ".gitignore not updated"
fi

if [[ -f "$INIT_DIR/.gitignore" ]] && grep -q '.orchd_needs_input.json' "$INIT_DIR/.gitignore"; then
	pass ".gitignore includes needs_input JSON artifact"
else
	fail ".gitignore includes needs_input JSON artifact"
fi

if [[ -f "$INIT_DIR/.orchd.toml" ]] && grep -q '^\[swarm.policy\]' "$INIT_DIR/.orchd.toml"; then
	pass "config includes swarm policy scaffold"
else
	fail "config includes swarm policy scaffold"
fi

if [[ -f "$INIT_DIR/.orchd.toml" ]] && grep -q '^# \[swarm.roles\]' "$INIT_DIR/.orchd.toml"; then
	pass "config includes swarm role examples"
else
	fail "config includes swarm role examples"
fi

ROUTE_DIR=$(mktemp -d)
git -C "$ROUTE_DIR" init -q
git -C "$ROUTE_DIR" config user.name "orchd-test"
git -C "$ROUTE_DIR" config user.email "test@orchd.dev"
git -C "$ROUTE_DIR" commit --allow-empty -m "init" -q
assert_exit_0 "init swarm route repo succeeds" "$ORCHD" init "$ROUTE_DIR"

ROUTE_FAKE_CLAUDE="$ROUTE_DIR/fake-claude"
ROUTE_FAKE_OPENCODE="$ROUTE_DIR/fake-opencode"
ROUTE_MISSING_CODEX="$ROUTE_DIR/missing-codex"
cat >"$ROUTE_FAKE_CLAUDE" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$ROUTE_FAKE_OPENCODE" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$ROUTE_FAKE_CLAUDE" "$ROUTE_FAKE_OPENCODE"
set_config_value "$ROUTE_DIR/.orchd.toml" "swarm.roles" "planner" '["codex", "claude"]'
set_config_value "$ROUTE_DIR/.orchd.toml" "swarm.roles" "builder" '["codex", "opencode"]'
set_config_value "$ROUTE_DIR/.orchd.toml" "swarm.roles" "reviewer" '["claude"]'
set_config_value "$ROUTE_DIR/.orchd.toml" "swarm.roles" "recovery" '["codex", "opencode"]'
printf '\nclaude_bin = "%s"\nopencode_bin = "%s"\ncodex_bin = "%s"\n' "$ROUTE_FAKE_CLAUDE" "$ROUTE_FAKE_OPENCODE" "$ROUTE_MISSING_CODEX" >>"$ROUTE_DIR/.orchd.toml"

assert_output_contains "doctor shows planner swarm route" 'planner:  claude' run_in_dir "$ROUTE_DIR" "$ORCHD" doctor
assert_output_contains "doctor shows builder swarm route" 'builder:  opencode' run_in_dir "$ROUTE_DIR" "$ORCHD" doctor
assert_output_contains "doctor shows recovery swarm route" 'recovery: opencode' run_in_dir "$ROUTE_DIR" "$ORCHD" doctor

mkdir -p "$ROUTE_DIR/.orchd/tasks/route-pending"
printf 'pending\n' >"$ROUTE_DIR/.orchd/tasks/route-pending/status"
printf 'Route Pending\n' >"$ROUTE_DIR/.orchd/tasks/route-pending/title"
ROUTE_STATE_JSON=$(run_in_dir "$ROUTE_DIR" "$ORCHD" state --json)
if printf '%s' "$ROUTE_STATE_JSON" | grep -q '"swarm_routing":{"planner":{"selected_runner":"claude"' && printf '%s' "$ROUTE_STATE_JSON" | grep -q '"builder":{"selected_runner":"opencode"'; then
	pass "state exposes top-level swarm routing metadata"
else
	fail "state exposes top-level swarm routing metadata"
fi
if printf '%s' "$ROUTE_STATE_JSON" | grep -q '"id":"route-pending"' && printf '%s' "$ROUTE_STATE_JSON" | grep -q '"routing_role":"builder"' && printf '%s' "$ROUTE_STATE_JSON" | grep -q '"selected_runner":"opencode"' && printf '%s' "$ROUTE_STATE_JSON" | grep -q '"routing_fallback_used":true'; then
	pass "state exposes task-level routing metadata"
else
	fail "state exposes task-level routing metadata"
fi

ORCH_ROUTE_DIR=$(mktemp -d)
git -C "$ORCH_ROUTE_DIR" init -q
git -C "$ORCH_ROUTE_DIR" config user.name "orchd-test"
git -C "$ORCH_ROUTE_DIR" config user.email "test@orchd.dev"
git -C "$ORCH_ROUTE_DIR" commit --allow-empty -m "init" -q
assert_exit_0 "init orchestrator route repo succeeds" "$ORCHD" init "$ORCH_ROUTE_DIR"
ORCH_ROUTE_FAKE_CLAUDE="$ORCH_ROUTE_DIR/fake-orchestrator-claude.sh"
ORCH_ROUTE_MISSING_CODEX="$ORCH_ROUTE_DIR/missing-codex"
cat >"$ORCH_ROUTE_FAKE_CLAUDE" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'ORCHD_RESULT: NEEDS_INPUT\n'
printf 'ORCHD_REASON: orchestrator route probe\n'
EOF
chmod +x "$ORCH_ROUTE_FAKE_CLAUDE"
set_config_value "$ORCH_ROUTE_DIR/.orchd.toml" "worker" "runner" '"auto"'
set_config_value "$ORCH_ROUTE_DIR/.orchd.toml" "orchestrator" "session_mode" '"reinvoke"'
set_config_value "$ORCH_ROUTE_DIR/.orchd.toml" "orchestrator" "continue_delay" '0'
set_config_value "$ORCH_ROUTE_DIR/.orchd.toml" "orchestrator" "max_iterations" '2'
set_config_value "$ORCH_ROUTE_DIR/.orchd.toml" "swarm.roles" "planner" '["codex", "claude"]'
printf '\nclaude_bin = "%s"\ncodex_bin = "%s"\n' "$ORCH_ROUTE_FAKE_CLAUDE" "$ORCH_ROUTE_MISSING_CODEX" >>"$ORCH_ROUTE_DIR/.orchd.toml"

assert_exit_0 "orchestrate uses planner route fallback" run_in_dir "$ORCH_ROUTE_DIR" bash -lc '"$0" orchestrate 0 >/dev/null 2>&1; test "$?" -eq 2' "$ORCHD"
if [[ "$(cat "$ORCH_ROUTE_DIR/.orchd/orchestrator/route_role" 2>/dev/null || true)" == "planner" ]] && [[ "$(cat "$ORCH_ROUTE_DIR/.orchd/orchestrator/selected_runner" 2>/dev/null || true)" == "claude" ]] && [[ "$(cat "$ORCH_ROUTE_DIR/.orchd/orchestrator/route_fallback_used" 2>/dev/null || true)" == "true" ]]; then
	pass "orchestrate records planner route fallback metadata"
else
	fail "orchestrate records planner route fallback metadata"
fi

assert_exit_0 "autopilot ai mode inherits orchestrator route" run_in_dir "$ORCH_ROUTE_DIR" bash -lc '"$0" autopilot 0 >/dev/null 2>&1; test "$?" -eq 2' "$ORCHD"

if [[ -f "$INIT_DIR/AGENTS.md" ]]; then
	pass "AGENTS.md created"
else
	fail "AGENTS.md not created"
fi

if [[ -f "$INIT_DIR/ORCHESTRATOR.md" ]]; then
	pass "ORCHESTRATOR.md created"
else
	fail "ORCHESTRATOR.md not created"
fi

if [[ -f "$INIT_DIR/WORKER.md" ]]; then
	pass "WORKER.md created"
else
	fail "WORKER.md not created"
fi

if [[ -f "$INIT_DIR/CLAUDE.md" ]]; then
	pass "CLAUDE.md created"
else
	fail "CLAUDE.md not created"
fi

if [[ -f "$INIT_DIR/OPENCODE.md" ]]; then
	pass "OPENCODE.md created"
else
	fail "OPENCODE.md not created"
fi

if [[ -f "$INIT_DIR/orchestrator-runbook.md" ]]; then
	pass "orchestrator-runbook.md created"
else
	fail "orchestrator-runbook.md not created"
fi

printf '\n[6b] Plan import parses quality overrides\n'
run_in_dir "$INIT_DIR" bash -c 'cat > .orchd/plan_in.txt <<"EOF"
TASK: t1
TITLE: Test overrides
ROLE: domain
DEPS: none
DESCRIPTION: do a thing
ACCEPTANCE: done
TEST_CMD: echo test
LINT_CMD: echo lint
BUILD_CMD: none
EXECUTION_ONLY: true
NO_PLANNING: yes
COMMIT_REQUIRED: 1
SIZE: small
RISK: high
BLAST_RADIUS: wide
FILE_HINTS: src/api,src/ui
RECOMMENDED_VERIFICATION: full
EOF'
assert_exit_0 "plan --file succeeds" run_in_dir "$INIT_DIR" "$ORCHD" plan --file .orchd/plan_in.txt
assert_output_contains "task test_cmd stored" "echo test" cat "$INIT_DIR/.orchd/tasks/t1/test_cmd"
assert_output_contains "task lint_cmd stored" "echo lint" cat "$INIT_DIR/.orchd/tasks/t1/lint_cmd"
assert_output_contains "task execution_only stored" "true" cat "$INIT_DIR/.orchd/tasks/t1/execution_only"
assert_output_contains "task no_planning stored" "true" cat "$INIT_DIR/.orchd/tasks/t1/no_planning"
assert_output_contains "task commit_required stored" "true" cat "$INIT_DIR/.orchd/tasks/t1/commit_required"
assert_output_contains "task size stored" "small" cat "$INIT_DIR/.orchd/tasks/t1/size"
assert_output_contains "task risk stored" "high" cat "$INIT_DIR/.orchd/tasks/t1/risk"
assert_output_contains "task blast radius stored" "wide" cat "$INIT_DIR/.orchd/tasks/t1/blast_radius"
assert_output_contains "task file hints stored" "src/api,src/ui" cat "$INIT_DIR/.orchd/tasks/t1/file_hints"
assert_output_contains "task verification recommendation stored" "full" cat "$INIT_DIR/.orchd/tasks/t1/recommended_verification"

KICKOFF_MODE_PROMPT=$(
	cd "$INIT_DIR" || exit 1
	ORCHD_LIB_DIR="$(dirname "$ORCHD")/../lib"
	# shellcheck source=../lib/core.sh
	source "$ORCHD_LIB_DIR/core.sh"
	# shellcheck source=../lib/runner.sh
	source "$ORCHD_LIB_DIR/runner.sh"
	# shellcheck source=../lib/cmd/spawn.sh
	source "$ORCHD_LIB_DIR/cmd/spawn.sh"
	PROJECT_ROOT="$INIT_DIR"
	ORCHD_DIR="$INIT_DIR/.orchd"
	TASKS_DIR="$ORCHD_DIR/tasks"
	LOGS_DIR="$ORCHD_DIR/logs"
	_build_kickoff_prompt "t1" "$INIT_DIR"
)
if printf '%s' "$KICKOFF_MODE_PROMPT" | grep -q 'execution_only: true' && printf '%s' "$KICKOFF_MODE_PROMPT" | grep -q 'NO_PLANNING is enabled' && printf '%s' "$KICKOFF_MODE_PROMPT" | grep -q 'risk: high' && printf '%s' "$KICKOFF_MODE_PROMPT" | grep -q 'recommended_verification: full'; then
	pass "kickoff prompt includes strict execution mode directives"
else
	fail "kickoff prompt includes strict execution mode directives"
fi
# Cleanup so later autopilot tests see only the tasks they create.
rm -rf "$INIT_DIR/.orchd/tasks/t1" "$INIT_DIR/.orchd/plan_in.txt"

printf '\n[6c] JSONL text extraction is tolerant\n'
ORCHD_LIB_DIR="$(dirname "$ORCHD")/../lib"
EXTRACT_OUT=$(
	cd "$INIT_DIR" || exit 1
	# shellcheck source=../lib/core.sh
	source "$ORCHD_LIB_DIR/core.sh"
	# shellcheck source=../lib/cmd/plan.sh
	source "$ORCHD_LIB_DIR/cmd/plan.sh"
	cat <<'EOF' | _extract_text_from_jsonl
{"type":"item.completed","item":{"type":"assistant_message","text":"TASK: t1\nTITLE: X"}}
EOF
)
if printf '%s' "$EXTRACT_OUT" | grep -q 'TASK: t1'; then
	pass "extractor reads item.completed text"
else
	fail "extractor reads item.completed text"
fi

EXTRACT_OUT2=$(
	cd "$INIT_DIR" || exit 1
	# shellcheck source=../lib/core.sh
	source "$ORCHD_LIB_DIR/core.sh"
	# shellcheck source=../lib/cmd/plan.sh
	source "$ORCHD_LIB_DIR/cmd/plan.sh"
	cat <<'EOF' | _extract_text_from_jsonl
{"type":"response.output_text.delta","delta":"TASK: t2\\n"}
{"type":"response.output_text.delta","delta":"TITLE: Y\\n"}
EOF
)
if printf '%s' "$EXTRACT_OUT2" | grep -q 'TASK: t2'; then
	pass "extractor falls back to delta stream"
else
	fail "extractor falls back to delta stream"
fi

printf '\n[7] Orchestration commands (no-project validation)\n'
# These should fail gracefully when not in an orchd project
assert_exit_nonzero "plan without project fails" "$ORCHD" plan "test"
assert_exit_nonzero "spawn without project fails" "$ORCHD" spawn --all
assert_exit_nonzero "check without project fails" "$ORCHD" check --all
assert_exit_nonzero "merge without project fails" "$ORCHD" merge --all
assert_exit_nonzero "resume without project fails" "$ORCHD" resume foo

printf '\n[8] Board command (in initialized project)\n'
# Board should work in an initialized project (shows empty board)
assert_exit_0 "board in init dir" run_in_dir "$INIT_DIR" "$ORCHD" board

printf '\n[9] Utility commands (in initialized project)\n'
assert_exit_0 "doctor in init dir" run_in_dir "$INIT_DIR" "$ORCHD" doctor
assert_exit_0 "refresh-docs in init dir" run_in_dir "$INIT_DIR" "$ORCHD" refresh-docs
assert_output_contains "agent-prompt works in init dir" 'Use `orchd` as the orchestration system' run_in_dir "$INIT_DIR" "$ORCHD" agent-prompt orchestrator "ship the next release"

AGENT_PROMPT_DIR="$TMPDIR/agent-prompt-raw"
mkdir -p "$AGENT_PROMPT_DIR"
run_in_dir "$AGENT_PROMPT_DIR" git init -q
run_in_dir "$AGENT_PROMPT_DIR" git config user.name "orchd-test"
run_in_dir "$AGENT_PROMPT_DIR" git config user.email "test@example.com"
run_in_dir "$AGENT_PROMPT_DIR" git commit --allow-empty -q -m "init"
assert_output_contains "agent-prompt suggests init before orchd setup" 'orchd init .' run_in_dir "$AGENT_PROMPT_DIR" "$ORCHD" agent-prompt orchestrator "bootstrap this repo"
assert_output_contains "agent-prompt includes user goal" 'bootstrap this repo' run_in_dir "$AGENT_PROMPT_DIR" "$ORCHD" agent-prompt orchestrator "bootstrap this repo"

printf '\n[9b] Python auto-detect prefers venv bins\n'
mkdir -p "$INIT_DIR/.venv/bin"
printf '#!/usr/bin/env bash\nexit 0\n' >"$INIT_DIR/.venv/bin/python"
chmod +x "$INIT_DIR/.venv/bin/python"
printf '#!/usr/bin/env bash\nexit 0\n' >"$INIT_DIR/.venv/bin/ruff"
chmod +x "$INIT_DIR/.venv/bin/ruff"
printf '[build-system]\nrequires = []\n' >"$INIT_DIR/pyproject.toml"
DETECT_OUT=$(
	cd "$INIT_DIR" || exit 1
	# shellcheck source=../lib/core.sh
	source "$ORCHD_LIB_DIR/core.sh"
	quality_detect_cmds "$INIT_DIR"
	printf '%s\n' "$ORCHD_DETECTED_LINT_CMD"
)
if printf '%s' "$DETECT_OUT" | grep -q '^\.venv/bin/ruff'; then
	pass "python lint auto-detect uses .venv/bin/ruff"
else
	fail "python lint auto-detect uses .venv/bin/ruff"
fi

printf '\n[10] Help includes orchestration commands\n'
assert_output_contains "help shows init" "init" "$ORCHD" --help
assert_output_contains "help shows plan" "plan" "$ORCHD" --help
assert_output_contains "help shows review" "review" "$ORCHD" --help
assert_output_contains "help shows spawn" "spawn" "$ORCHD" --help
assert_output_contains "help shows board" "board" "$ORCHD" --help
assert_output_contains "help shows tui" "tui" "$ORCHD" --help
assert_output_contains "help shows state" "state" "$ORCHD" --help
assert_output_contains "help shows await" "await" "$ORCHD" --help
assert_output_contains "help shows check" "check" "$ORCHD" --help
assert_output_contains "help shows merge" "merge" "$ORCHD" --help
assert_output_contains "help shows resume" "resume" "$ORCHD" --help
assert_output_contains "help shows autopilot" "autopilot" "$ORCHD" --help
assert_output_contains "help shows finish" "finish" "$ORCHD" --help
assert_output_contains "help shows agent-prompt" "agent-prompt" "$ORCHD" --help
assert_output_contains "help shows doctor" "doctor" "$ORCHD" --help
assert_output_contains "help shows refresh-docs" "refresh-docs" "$ORCHD" --help
assert_output_contains "agent-prompt help works" "copy-paste prompt" "$ORCHD" agent-prompt --help
assert_exit_0 "finish help works" run_in_dir "$INIT_DIR" "$ORCHD" finish --help
assert_exit_nonzero "finish status reports not running by default" run_in_dir "$INIT_DIR" "$ORCHD" finish --status

printf '\n[11] Merge checks out base branch before merge\n'
run_in_dir "$INIT_DIR" git checkout -q -b "agent-merge-base-safety"
printf 'merge-base-safety\n' >"$INIT_DIR/merge_base_safety.txt"
run_in_dir "$INIT_DIR" git add "merge_base_safety.txt"
run_in_dir "$INIT_DIR" git commit -q -m "test: merge base safety"

mkdir -p "$INIT_DIR/.orchd/tasks/merge-base-safety"
printf 'done\n' >"$INIT_DIR/.orchd/tasks/merge-base-safety/status"
printf 'agent-merge-base-safety\n' >"$INIT_DIR/.orchd/tasks/merge-base-safety/branch"

assert_exit_0 "merge single succeeds from non-base HEAD" run_in_dir "$INIT_DIR" "$ORCHD" merge "merge-base-safety"

current_branch=$(run_in_dir "$INIT_DIR" git rev-parse --abbrev-ref HEAD)
if [[ "$current_branch" == "$BASE_BRANCH" ]]; then
	pass "merge leaves repository on base branch"
else
	fail "merge leaves repository on base branch (expected '$BASE_BRANCH', got '$current_branch')"
fi
assert_task_status "merged task marked as merged" "$INIT_DIR" "merge-base-safety" "merged"

printf '\n[12] Autopilot merges done tasks\n'
run_in_dir "$INIT_DIR" git checkout -q "$BASE_BRANCH"
run_in_dir "$INIT_DIR" git checkout -q -b "agent-autopilot-merge"
printf 'autopilot-merge\n' >"$INIT_DIR/autopilot_merge.txt"
run_in_dir "$INIT_DIR" git add "autopilot_merge.txt"
run_in_dir "$INIT_DIR" git commit -q -m "test: autopilot merge"
run_in_dir "$INIT_DIR" git checkout -q "$BASE_BRANCH"

mkdir -p "$INIT_DIR/.orchd/tasks/autopilot-merge"
printf 'done\n' >"$INIT_DIR/.orchd/tasks/autopilot-merge/status"
printf 'agent-autopilot-merge\n' >"$INIT_DIR/.orchd/tasks/autopilot-merge/branch"

assert_exit_0 "autopilot merges done task" run_in_dir "$INIT_DIR" "$ORCHD" autopilot --deterministic 0
assert_task_status "autopilot task marked as merged" "$INIT_DIR" "autopilot-merge" "merged"

printf '\n[13] Merge --all stops after post-merge test failure\n'
set_test_cmd "$INIT_DIR/.orchd.toml" "false"

run_in_dir "$INIT_DIR" git checkout -q "$BASE_BRANCH"
run_in_dir "$INIT_DIR" git checkout -q -b "agent-a-fail-stop"
printf 'a-fail-stop\n' >"$INIT_DIR/a_fail_stop.txt"
run_in_dir "$INIT_DIR" git add "a_fail_stop.txt"
run_in_dir "$INIT_DIR" git commit -q -m "test: fail stop A"

run_in_dir "$INIT_DIR" git checkout -q "$BASE_BRANCH"
run_in_dir "$INIT_DIR" git checkout -q -b "agent-z-fail-stop"
printf 'z-fail-stop\n' >"$INIT_DIR/z_fail_stop.txt"
run_in_dir "$INIT_DIR" git add "z_fail_stop.txt"
run_in_dir "$INIT_DIR" git commit -q -m "test: fail stop Z"
run_in_dir "$INIT_DIR" git checkout -q "$BASE_BRANCH"

mkdir -p "$INIT_DIR/.orchd/tasks/a-fail-stop" "$INIT_DIR/.orchd/tasks/z-fail-stop"
printf 'done\n' >"$INIT_DIR/.orchd/tasks/a-fail-stop/status"
printf 'agent-a-fail-stop\n' >"$INIT_DIR/.orchd/tasks/a-fail-stop/branch"
printf 'done\n' >"$INIT_DIR/.orchd/tasks/z-fail-stop/status"
printf 'agent-z-fail-stop\n' >"$INIT_DIR/.orchd/tasks/z-fail-stop/branch"

assert_exit_nonzero "merge --all fails when post-merge tests fail" run_in_dir "$INIT_DIR" "$ORCHD" merge --all
assert_task_status "first failing task marked failed" "$INIT_DIR" "a-fail-stop" "failed"
assert_task_status "later task remains unmerged" "$INIT_DIR" "z-fail-stop" "done"

printf '\n[13b] Task review persists review status\n'
REVIEW_RUNNER_SCRIPT="$INIT_DIR/review-runner.sh"
REVIEW_PROMPT_CAPTURE="$INIT_DIR/review-prompt-capture.txt"
REVIEW_WORKTREE_CAPTURE="$INIT_DIR/review-worktree-capture.txt"
REVIEW_TASK_ID_CAPTURE="$INIT_DIR/review-task-id-capture.txt"
cat >"$REVIEW_RUNNER_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
worktree=$1
task_id=$2
prompt=$3
printf '%s' "$prompt" > review-prompt-capture.txt
printf '%s' "$worktree" > review-worktree-capture.txt
printf '%s' "$task_id" > review-task-id-capture.txt
if [[ -f "$worktree/review_untracked.txt" ]]; then
	cat "$worktree/review_untracked.txt" > review-worktree-file-capture.txt
else
	printf 'missing\n' > review-worktree-file-capture.txt
fi
cat <<'OUT'
REVIEW_STATUS: approved
REVIEW_REASON: focused diff looks safe to merge
No issues found.
OUT
EOF
chmod +x "$REVIEW_RUNNER_SCRIPT"
set_config_value "$INIT_DIR/.orchd.toml" "swarm.roles" "reviewer" '"custom"'
set_config_value "$INIT_DIR/.orchd.toml" "runners.custom" "custom_runner_cmd" "\"$REVIEW_RUNNER_SCRIPT {worktree} {task_id} {prompt}\""
run_in_dir "$INIT_DIR" git checkout -q "$BASE_BRANCH"
run_in_dir "$INIT_DIR" git checkout -q -b "agent-review-task"
printf 'review me\n' >"$INIT_DIR/review_me.txt"
run_in_dir "$INIT_DIR" git add review_me.txt
run_in_dir "$INIT_DIR" git commit -q -m "test: add reviewable diff"
run_in_dir "$INIT_DIR" git checkout -q "$BASE_BRANCH"
mkdir -p "$INIT_DIR/.worktrees"
run_in_dir "$INIT_DIR" git worktree add -q "$INIT_DIR/.worktrees/agent-review-task" "agent-review-task"
printf 'staged review change\n' >>"$INIT_DIR/.worktrees/agent-review-task/review_me.txt"
run_in_dir "$INIT_DIR/.worktrees/agent-review-task" git add review_me.txt
printf 'unstaged review change\n' >>"$INIT_DIR/.worktrees/agent-review-task/review_me.txt"
printf 'brand new review file\n' >"$INIT_DIR/.worktrees/agent-review-task/review_untracked.txt"
mkdir -p "$INIT_DIR/.orchd/tasks/review-task"
printf 'done\n' >"$INIT_DIR/.orchd/tasks/review-task/status"
printf 'agent-review-task\n' >"$INIT_DIR/.orchd/tasks/review-task/branch"
printf '%s\n' "$INIT_DIR/.worktrees/agent-review-task" >"$INIT_DIR/.orchd/tasks/review-task/worktree"
assert_exit_0 "review --task persists review status" run_in_dir "$INIT_DIR" "$ORCHD" review --task review-task
assert_output_contains "review task stores approved status" "approved" cat "$INIT_DIR/.orchd/tasks/review-task/review_status"
assert_output_contains "review task stores review reason" "focused diff looks safe to merge" cat "$INIT_DIR/.orchd/tasks/review-task/review_reason"
assert_output_contains "review task prompt includes staged worktree changes" "staged review change" cat "$REVIEW_PROMPT_CAPTURE"
assert_output_contains "review task prompt includes unstaged worktree changes" "unstaged review change" cat "$REVIEW_PROMPT_CAPTURE"
assert_output_contains "review task prompt includes untracked worktree files" "brand new review file" cat "$REVIEW_PROMPT_CAPTURE"
assert_output_contains "review task passes task worktree to custom runner" "$INIT_DIR/.worktrees/agent-review-task" cat "$REVIEW_WORKTREE_CAPTURE"
assert_output_contains "review task passes task id to custom runner" "review-task" cat "$REVIEW_TASK_ID_CAPTURE"
assert_output_contains "review task custom runner can inspect task worktree files" "brand new review file" cat "$INIT_DIR/review-worktree-file-capture.txt"

# Restore test_cmd to empty so remaining tests aren't affected by false.
set_test_cmd "$INIT_DIR/.orchd.toml" ""

printf '\n[14] Memory bank commands\n'
assert_exit_0 "memory (no memory yet) exits 0" run_in_dir "$INIT_DIR" "$ORCHD" memory
assert_exit_0 "memory --help exits 0" run_in_dir "$INIT_DIR" "$ORCHD" memory --help
assert_exit_0 "memory init exits 0" run_in_dir "$INIT_DIR" "$ORCHD" memory init

if [[ -d "$INIT_DIR/docs/memory" ]]; then
	pass "memory init creates docs/memory/"
else
	fail "memory init creates docs/memory/"
fi

if [[ -f "$INIT_DIR/docs/memory/projectbrief.md" ]]; then
	pass "memory init creates projectbrief.md"
else
	fail "memory init creates projectbrief.md"
fi

if [[ -f "$INIT_DIR/docs/memory/activeContext.md" ]]; then
	pass "memory init creates activeContext.md"
else
	fail "memory init creates activeContext.md"
fi

if [[ -f "$INIT_DIR/docs/memory/progress.md" ]]; then
	pass "memory init creates progress.md"
else
	fail "memory init creates progress.md"
fi

if [[ -f "$INIT_DIR/docs/memory/systemPatterns.md" ]]; then
	pass "memory init creates systemPatterns.md"
else
	fail "memory init creates systemPatterns.md"
fi

if [[ -f "$INIT_DIR/docs/memory/techContext.md" ]]; then
	pass "memory init creates techContext.md"
else
	fail "memory init creates techContext.md"
fi

if [[ -d "$INIT_DIR/docs/memory/lessons" ]]; then
	pass "memory init creates lessons/"
else
	fail "memory init creates lessons/"
fi

assert_exit_0 "memory show exits 0" run_in_dir "$INIT_DIR" "$ORCHD" memory show
assert_exit_0 "memory update exits 0" run_in_dir "$INIT_DIR" "$ORCHD" memory update
assert_output_contains "memory status shows projectbrief" "projectbrief.md" run_in_dir "$INIT_DIR" "$ORCHD" memory
assert_exit_nonzero "memory reset without --force fails" run_in_dir "$INIT_DIR" "$ORCHD" memory reset
assert_exit_0 "memory reset --force exits 0" run_in_dir "$INIT_DIR" "$ORCHD" memory reset --force

if [[ ! -d "$INIT_DIR/docs/memory" ]]; then
	pass "memory reset removes docs/memory/"
else
	fail "memory reset removes docs/memory/"
fi

# Re-init memory for merge test below
run_in_dir "$INIT_DIR" "$ORCHD" memory init >/dev/null 2>&1

printf '\n[15] Memory bank merge integration\n'
# Create a task with a TASK_REPORT.md, mark done, and merge — verify lesson is written.
run_in_dir "$INIT_DIR" git checkout -q "$BASE_BRANCH"
run_in_dir "$INIT_DIR" git checkout -q -b "agent-memory-lesson-test"
printf 'memory-lesson-test\n' >"$INIT_DIR/mem_lesson_test.txt"
run_in_dir "$INIT_DIR" git add "mem_lesson_test.txt"
run_in_dir "$INIT_DIR" git commit -q -m "test: memory lesson"
# Write a minimal TASK_REPORT.md in the branch (it lives as a local file — irrelevant for merge)
run_in_dir "$INIT_DIR" git checkout -q "$BASE_BRANCH"

mkdir -p "$INIT_DIR/.orchd/tasks/memory-lesson-test"
printf 'done\n' >"$INIT_DIR/.orchd/tasks/memory-lesson-test/status"
printf 'agent-memory-lesson-test\n' >"$INIT_DIR/.orchd/tasks/memory-lesson-test/branch"
printf 'Memory lesson test task\n' >"$INIT_DIR/.orchd/tasks/memory-lesson-test/title"
printf 'Test memory lesson writing\n' >"$INIT_DIR/.orchd/tasks/memory-lesson-test/description"

assert_exit_0 "merge writes memory lesson" run_in_dir "$INIT_DIR" "$ORCHD" merge "memory-lesson-test"

if git -C "$INIT_DIR" log -n 20 --oneline | grep -q 'docs(memory): update after merging'; then
	fail "merge does not create separate docs(memory) commit"
else
	pass "merge does not create separate docs(memory) commit"
fi

if [[ -f "$INIT_DIR/docs/memory/lessons/memory-lesson-test.md" ]]; then
	pass "lesson file created after merge"
else
	fail "lesson file created after merge"
fi

if [[ -f "$INIT_DIR/docs/memory/progress.md" ]]; then
	if grep -q "memory-lesson-test" "$INIT_DIR/docs/memory/progress.md" 2>/dev/null; then
		pass "progress.md updated after merge"
	else
		fail "progress.md updated after merge (task not found in progress)"
	fi
else
	fail "progress.md updated after merge (file missing)"
fi

printf '\n[16] Idea queue commands\n'
assert_exit_0 "idea --help exits 0" run_in_dir "$INIT_DIR" "$ORCHD" idea --help
assert_exit_nonzero "idea without args fails" run_in_dir "$INIT_DIR" "$ORCHD" idea
assert_exit_0 "idea queues an idea" run_in_dir "$INIT_DIR" "$ORCHD" idea "build user dashboard"
assert_exit_0 "idea queues second idea" run_in_dir "$INIT_DIR" "$ORCHD" idea "add notifications"

if [[ -f "$INIT_DIR/.orchd/queue.md" ]]; then
	pass "queue.md created"
else
	fail "queue.md created"
fi

assert_output_contains "idea list shows first idea" "build user dashboard" run_in_dir "$INIT_DIR" "$ORCHD" idea list
assert_output_contains "idea list shows second idea" "add notifications" run_in_dir "$INIT_DIR" "$ORCHD" idea list
assert_output_contains "idea count shows 2" "2" run_in_dir "$INIT_DIR" "$ORCHD" idea count

# Verify queue drain does not consume ideas when runner is unavailable.
ORCHD_LIB_DIR="$(dirname "$ORCHD")/../lib"
QUEUE_COUNT_AFTER_NONE=$(
	cd "$INIT_DIR" || exit 1
	# shellcheck source=../lib/core.sh
	source "$ORCHD_LIB_DIR/core.sh"
	# shellcheck source=../lib/cmd/autopilot.sh
	source "$ORCHD_LIB_DIR/cmd/autopilot.sh"
	# These variables are used by sourced helpers.
	# shellcheck disable=SC2034
	PROJECT_ROOT="$INIT_DIR"
	ORCHD_DIR="$INIT_DIR/.orchd"
	# shellcheck disable=SC2034
	TASKS_DIR="$ORCHD_DIR/tasks"
	# shellcheck disable=SC2034
	LOGS_DIR="$ORCHD_DIR/logs"
	_autopilot_drain_queue "none" 0 >/dev/null 2>&1 || true
	queue_count
)
if [[ "$QUEUE_COUNT_AFTER_NONE" == "2" ]]; then
	pass "queue drain keeps ideas when runner unavailable"
else
	fail "queue drain keeps ideas when runner unavailable (got: $QUEUE_COUNT_AFTER_NONE)"
fi

# Verify plan failure does not mark in-progress idea complete (isolated state dir).
QUEUE_STATUS_AFTER_PLAN_FAIL=$(
	cd "$INIT_DIR" || exit 1
	# shellcheck source=../lib/core.sh
	source "$ORCHD_LIB_DIR/core.sh"
	# shellcheck source=../lib/cmd/autopilot.sh
	source "$ORCHD_LIB_DIR/cmd/autopilot.sh"
	# These variables are used by sourced helpers.
	# shellcheck disable=SC2034
	PROJECT_ROOT="$INIT_DIR"
	ORCHD_DIR="$INIT_DIR/.orchd_failtest"
	# shellcheck disable=SC2034
	TASKS_DIR="$ORCHD_DIR/tasks"
	# shellcheck disable=SC2034
	LOGS_DIR="$ORCHD_DIR/logs"
	mkdir -p "$TASKS_DIR" "$LOGS_DIR"

	queue_push "first idea" >/dev/null 2>&1
	queue_push "second idea" >/dev/null 2>&1

	# shellcheck disable=SC2329
	cmd_plan() { return 1; }
	_autopilot_drain_queue "opencode" 0 >/dev/null 2>&1 || true
	cat "$ORCHD_DIR/queue.md"
)
rm -rf "$INIT_DIR/.orchd_failtest" >/dev/null 2>&1 || true

if printf '%s' "$QUEUE_STATUS_AFTER_PLAN_FAIL" | grep -q -- "- \[>\]" && ! printf '%s' "$QUEUE_STATUS_AFTER_PLAN_FAIL" | grep -q -- "- \[x\]"; then
	pass "plan failure leaves idea in-progress"
else
	fail "plan failure leaves idea in-progress"
fi

# Test queue_pop via internal helper (source core.sh to get helpers)
QUEUE_POP_OUTPUT=$(
	cd "$INIT_DIR" || exit 1
	# shellcheck source=../lib/core.sh
	source "$ORCHD_LIB_DIR/core.sh"
	# These variables are used by functions in core.sh
	# shellcheck disable=SC2034
	PROJECT_ROOT="$INIT_DIR"
	ORCHD_DIR="$INIT_DIR/.orchd"
	# shellcheck disable=SC2034
	TASKS_DIR="$ORCHD_DIR/tasks"
	# shellcheck disable=SC2034
	LOGS_DIR="$ORCHD_DIR/logs"
	queue_pop
)
if [[ "$QUEUE_POP_OUTPUT" == "build user dashboard" ]]; then
	pass "queue_pop returns first idea"
else
	fail "queue_pop returns first idea (got: $QUEUE_POP_OUTPUT)"
fi

assert_output_contains "idea count after pop is 1" "1" run_in_dir "$INIT_DIR" "$ORCHD" idea count

assert_exit_nonzero "idea clear without --force fails" run_in_dir "$INIT_DIR" "$ORCHD" idea clear
assert_exit_0 "idea clear --force exits 0" run_in_dir "$INIT_DIR" "$ORCHD" idea clear --force
assert_output_contains "idea count after clear is 0" "0" run_in_dir "$INIT_DIR" "$ORCHD" idea count

printf '\n[17] Fleet commands\n'
assert_exit_0 "fleet --help exits 0" "$ORCHD" fleet --help
assert_exit_nonzero "fleet list without config fails" "$ORCHD" fleet list

# Create a temporary fleet config
FLEET_DIR=$(mktemp -d)
FLEET_CFG="$FLEET_DIR/fleet.toml"
FLEET_SPACE_PATH="$FLEET_DIR/project with space"
mkdir -p "$FLEET_SPACE_PATH"
cat >"$FLEET_CFG" <<TOML
[projects.testproj]
path = "$INIT_DIR"

[projects.missing]
path = "/nonexistent/path"

[projects.spaced]
path = "$FLEET_SPACE_PATH"
TOML
export ORCHD_STATE_DIR="$FLEET_DIR"

assert_exit_0 "fleet list with config exits 0" "$ORCHD" fleet list
assert_output_contains "fleet list shows testproj" "testproj" "$ORCHD" fleet list
assert_output_contains "fleet list shows missing" "missing" "$ORCHD" fleet list
assert_output_contains "fleet list preserves spaces" "project with space" "$ORCHD" fleet list
assert_exit_0 "fleet status exits 0" "$ORCHD" fleet status
assert_output_contains "fleet status shows testproj" "testproj" "$ORCHD" fleet status
assert_exit_0 "fleet brief exits 0" "$ORCHD" fleet brief
assert_output_contains "fleet brief shows testproj" "testproj" "$ORCHD" fleet brief
assert_exit_0 "fleet stop exits 0" "$ORCHD" fleet stop

# Restore state dir
export ORCHD_STATE_DIR="$ORCHD_TEST_STATE_DIR"
rm -rf "$FLEET_DIR"

printf '\n[18] Lifecycle hardening regressions\n'
LIFE_DIR=$(mktemp -d)
git -C "$LIFE_DIR" init -q
git -C "$LIFE_DIR" config user.name "orchd-test"
git -C "$LIFE_DIR" config user.email "test@orchd.dev"
git -C "$LIFE_DIR" commit --allow-empty -m "init" -q

assert_exit_0 "init lifecycle repo succeeds" "$ORCHD" init "$LIFE_DIR"
LIFE_BASE_BRANCH=$(get_base_branch "$LIFE_DIR")
printf '\ncustom_runner_cmd = "true"\n' >>"$LIFE_DIR/.orchd.toml"

# await --all should wait while at least one running task still has a live agent.
mkdir -p "$LIFE_DIR/.orchd/tasks/await-stale" "$LIFE_DIR/.orchd/tasks/await-live"
printf 'running\n' >"$LIFE_DIR/.orchd/tasks/await-stale/status"
printf 'orchd-test-await-stale\n' >"$LIFE_DIR/.orchd/tasks/await-stale/session"
printf 'running\n' >"$LIFE_DIR/.orchd/tasks/await-live/status"
printf 'orchd-test-await-live\n' >"$LIFE_DIR/.orchd/tasks/await-live/session"
printf '0\n' >"$LIFE_DIR/.orchd/logs/await-stale.exit"
tmux new -d -s "orchd-test-await-stale" "sleep 120"
tmux new -d -s "orchd-test-await-live" "sleep 120"

STATE_JSON=$(run_in_dir "$LIFE_DIR" "$ORCHD" state --json)
if printf '%s' "$STATE_JSON" | grep -q '"running":1' && printf '%s' "$STATE_JSON" | grep -q '"effective_status":"stale"'; then
	pass "state normalizes live running count and stale effective status"
else
	fail "state normalizes live running count and stale effective status"
fi

AWAIT_TIMEOUT_EVENT=""
AWAIT_TIMEOUT_RC=0
set +e
AWAIT_TIMEOUT_EVENT=$(run_in_dir "$LIFE_DIR" "$ORCHD" await --all --poll 1 --timeout 2 --json 2>/dev/null)
AWAIT_TIMEOUT_RC=$?
set -e
if ((AWAIT_TIMEOUT_RC != 0)) && printf '%s' "$AWAIT_TIMEOUT_EVENT" | grep -q '"event":"timeout"'; then
	pass "await waits for live running agents"
else
	fail "await waits for live running agents"
fi

tmux kill-session -t "orchd-test-await-live" 2>/dev/null || true
AWAIT_EXIT_EVENT=$(run_in_dir "$LIFE_DIR" "$ORCHD" await --all --poll 1 --timeout 2 --json 2>/dev/null || true)
if printf '%s' "$AWAIT_EXIT_EVENT" | grep -q '"event":"agent_exited"'; then
	pass "await surfaces stale running task once no live agents remain"
else
	fail "await surfaces stale running task once no live agents remain"
fi

# reconcile should clean stale live sessions for terminal statuses.
mkdir -p "$LIFE_DIR/.orchd/tasks/reconcile-stale"
printf 'failed\n' >"$LIFE_DIR/.orchd/tasks/reconcile-stale/status"
printf 'orchd-test-reconcile-stale\n' >"$LIFE_DIR/.orchd/tasks/reconcile-stale/session"
tmux new -d -s "orchd-test-reconcile-stale" "sleep 120"
assert_exit_0 "reconcile exits 0" run_in_dir "$LIFE_DIR" "$ORCHD" reconcile
if tmux has-session -t "orchd-test-reconcile-stale" 2>/dev/null; then
	fail "reconcile cleans stale terminal session"
else
	pass "reconcile cleans stale terminal session"
fi

# resume should kill stale tmux session before relaunching.
mkdir -p "$LIFE_DIR/.worktrees"
run_in_dir "$LIFE_DIR" git worktree add -q -b "agent-resume-stale" "$LIFE_DIR/.worktrees/agent-resume-stale" "$LIFE_BASE_BRANCH"
mkdir -p "$LIFE_DIR/.orchd/tasks/resume-stale"
printf 'failed\n' >"$LIFE_DIR/.orchd/tasks/resume-stale/status"
printf '%s\n' "$LIFE_DIR/.worktrees/agent-resume-stale" >"$LIFE_DIR/.orchd/tasks/resume-stale/worktree"
printf 'custom\n' >"$LIFE_DIR/.orchd/tasks/resume-stale/runner"
printf 'orchd-agent-resume-stale\n' >"$LIFE_DIR/.orchd/tasks/resume-stale/session"
tmux new -d -s "orchd-agent-resume-stale" "sleep 120"
assert_exit_0 "resume cleans stale session and relaunches" run_in_dir "$LIFE_DIR" "$ORCHD" resume "resume-stale" "stale session retry"
assert_task_status "resume leaves task running" "$LIFE_DIR" "resume-stale" "running"

# resume should honor configured recovery routing even when the task stores its original runner.
RECOVERY_RUNNER_SCRIPT="$LIFE_DIR/recovery-runner.sh"
cat >"$RECOVERY_RUNNER_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'custom recovery\n' >> .orchd_resume_runner.log
EOF
chmod +x "$RECOVERY_RUNNER_SCRIPT"
set_config_value "$LIFE_DIR/.orchd.toml" "swarm.roles" "recovery" '"custom"'
set_config_value "$LIFE_DIR/.orchd.toml" "runners.custom" "custom_runner_cmd" "\"$RECOVERY_RUNNER_SCRIPT\""
run_in_dir "$LIFE_DIR" git worktree add -q -b "agent-resume-recovery-route" "$LIFE_DIR/.worktrees/agent-resume-recovery-route" "$LIFE_BASE_BRANCH"
mkdir -p "$LIFE_DIR/.orchd/tasks/resume-recovery-route"
printf 'failed\n' >"$LIFE_DIR/.orchd/tasks/resume-recovery-route/status"
printf '%s\n' "$LIFE_DIR/.worktrees/agent-resume-recovery-route" >"$LIFE_DIR/.orchd/tasks/resume-recovery-route/worktree"
printf 'codex\n' >"$LIFE_DIR/.orchd/tasks/resume-recovery-route/runner"
assert_exit_0 "resume applies configured recovery runner over stored runner" run_in_dir "$LIFE_DIR" "$ORCHD" resume "resume-recovery-route" "route to recovery runner"
sleep 1
if [[ "$(cat "$LIFE_DIR/.orchd/tasks/resume-recovery-route/runner" 2>/dev/null || true)" == "custom" ]] && [[ -f "$LIFE_DIR/.worktrees/agent-resume-recovery-route/.orchd_resume_runner.log" ]]; then
	pass "resume routes existing task through configured recovery runner"
else
	fail "resume routes existing task through configured recovery runner"
fi

# check should not fail solely due missing ORCHD_EXIT marker when other gates pass.
run_in_dir "$LIFE_DIR" git checkout -q "$LIFE_BASE_BRANCH"
run_in_dir "$LIFE_DIR" git checkout -q -b "agent-check-missing-exit"
printf 'check-missing-exit\n' >"$LIFE_DIR/check_missing_exit.txt"
run_in_dir "$LIFE_DIR" git add "check_missing_exit.txt"
run_in_dir "$LIFE_DIR" git commit -q -m "test: check missing exit"
run_in_dir "$LIFE_DIR" git checkout -q "$LIFE_BASE_BRANCH"
run_in_dir "$LIFE_DIR" git worktree add -q "$LIFE_DIR/.worktrees/agent-check-missing-exit" "agent-check-missing-exit"
cat >"$LIFE_DIR/.worktrees/agent-check-missing-exit/TASK_REPORT.md" <<'EOF'
Summary

EVIDENCE:
- CMD: true
  RESULT: PASS
  OUTPUT: ok

Rollback: revert commit if regression appears.
EOF
mkdir -p "$LIFE_DIR/.orchd/tasks/check-missing-exit"
printf 'failed\n' >"$LIFE_DIR/.orchd/tasks/check-missing-exit/status"
printf 'agent-check-missing-exit\n' >"$LIFE_DIR/.orchd/tasks/check-missing-exit/branch"
printf '%s\n' "$LIFE_DIR/.worktrees/agent-check-missing-exit" >"$LIFE_DIR/.orchd/tasks/check-missing-exit/worktree"
assert_exit_0 "check passes with missing exit marker when quality gates pass" run_in_dir "$LIFE_DIR" "$ORCHD" check "check-missing-exit"
assert_task_status "check marks task done when exit marker missing" "$LIFE_DIR" "check-missing-exit" "done"

# check should adapt verification depth to task risk metadata.
for tier_name in low medium high; do
	run_in_dir "$LIFE_DIR" git checkout -q "$LIFE_BASE_BRANCH"
	run_in_dir "$LIFE_DIR" git checkout -q -b "agent-check-tier-${tier_name}"
	printf 'check-tier-%s\n' "$tier_name" >"$LIFE_DIR/check_tier_${tier_name}.txt"
	run_in_dir "$LIFE_DIR" git add "check_tier_${tier_name}.txt"
	run_in_dir "$LIFE_DIR" git commit -q -m "test: check tier ${tier_name}"
	run_in_dir "$LIFE_DIR" git checkout -q "$LIFE_BASE_BRANCH"
	run_in_dir "$LIFE_DIR" git worktree add -q "$LIFE_DIR/.worktrees/agent-check-tier-${tier_name}" "agent-check-tier-${tier_name}"
	cat >"$LIFE_DIR/.worktrees/agent-check-tier-${tier_name}/TASK_REPORT.md" <<'EOF'
Summary

EVIDENCE:
- CMD: true
  RESULT: PASS
  OUTPUT: ok

Rollback: revert commit if regression appears.
EOF
	mkdir -p "$LIFE_DIR/.orchd/tasks/check-tier-${tier_name}"
	printf 'failed\n' >"$LIFE_DIR/.orchd/tasks/check-tier-${tier_name}/status"
	printf 'agent-check-tier-%s\n' "$tier_name" >"$LIFE_DIR/.orchd/tasks/check-tier-${tier_name}/branch"
	printf '%s\n' "$LIFE_DIR/.worktrees/agent-check-tier-${tier_name}" >"$LIFE_DIR/.orchd/tasks/check-tier-${tier_name}/worktree"
	printf 'printf "lint\\n" >> .orchd_trace.log\n' >"$LIFE_DIR/.orchd/tasks/check-tier-${tier_name}/lint_cmd"
	printf 'printf "test\\n" >> .orchd_trace.log\n' >"$LIFE_DIR/.orchd/tasks/check-tier-${tier_name}/test_cmd"
	printf 'printf "build\\n" >> .orchd_trace.log\n' >"$LIFE_DIR/.orchd/tasks/check-tier-${tier_name}/build_cmd"
	printf '%s\n' "$tier_name" >"$LIFE_DIR/.orchd/tasks/check-tier-${tier_name}/risk"
done

assert_exit_0 "low-risk check uses smoke verification" run_in_dir "$LIFE_DIR" "$ORCHD" check "check-tier-low"
assert_exit_0 "medium-risk check uses targeted verification" run_in_dir "$LIFE_DIR" "$ORCHD" check "check-tier-medium"
assert_exit_0 "high-risk check uses full verification" run_in_dir "$LIFE_DIR" "$ORCHD" check "check-tier-high"

assert_output_contains "low-risk task stores smoke tier" "smoke" cat "$LIFE_DIR/.orchd/tasks/check-tier-low/verification_tier"
assert_output_contains "medium-risk task stores targeted tier" "targeted" cat "$LIFE_DIR/.orchd/tasks/check-tier-medium/verification_tier"
assert_output_contains "high-risk task stores full tier" "full" cat "$LIFE_DIR/.orchd/tasks/check-tier-high/verification_tier"

if [[ "$(paste -sd ',' "$LIFE_DIR/.worktrees/agent-check-tier-low/.orchd_trace.log" 2>/dev/null || true)" == "lint" ]]; then
	pass "low-risk task runs smoke verification subset"
else
	fail "low-risk task runs smoke verification subset"
fi

if [[ "$(paste -sd ',' "$LIFE_DIR/.worktrees/agent-check-tier-medium/.orchd_trace.log" 2>/dev/null || true)" == "lint,test" ]]; then
	pass "medium-risk task runs targeted verification subset"
else
	fail "medium-risk task runs targeted verification subset"
fi

if [[ "$(paste -sd ',' "$LIFE_DIR/.worktrees/agent-check-tier-high/.orchd_trace.log" 2>/dev/null || true)" == "lint,test,build" ]]; then
	pass "high-risk task runs full verification suite"
else
	fail "high-risk task runs full verification suite"
fi

# check should parse structured needs_input payloads.
run_in_dir "$LIFE_DIR" git checkout -q "$LIFE_BASE_BRANCH"
run_in_dir "$LIFE_DIR" git checkout -q -b "agent-check-needs-json"
printf 'check-needs-json\n' >"$LIFE_DIR/check_needs_json.txt"
run_in_dir "$LIFE_DIR" git add "check_needs_json.txt"
run_in_dir "$LIFE_DIR" git commit -q -m "test: check needs input json"
run_in_dir "$LIFE_DIR" git checkout -q "$LIFE_BASE_BRANCH"
run_in_dir "$LIFE_DIR" git worktree add -q "$LIFE_DIR/.worktrees/agent-check-needs-json" "agent-check-needs-json"
cat >"$LIFE_DIR/.worktrees/agent-check-needs-json/.orchd_needs_input.json" <<'EOF'
{
  "code": "decision_required",
  "summary": "Need product direction before continuing",
  "question": "Should we use provider A or provider B?",
  "blocking": true,
  "options": ["provider_a", "provider_b"]
}
EOF
mkdir -p "$LIFE_DIR/.orchd/tasks/check-needs-json"
printf 'running\n' >"$LIFE_DIR/.orchd/tasks/check-needs-json/status"
printf 'agent-check-needs-json\n' >"$LIFE_DIR/.orchd/tasks/check-needs-json/branch"
printf '%s\n' "$LIFE_DIR/.worktrees/agent-check-needs-json" >"$LIFE_DIR/.orchd/tasks/check-needs-json/worktree"
assert_exit_0 "check parses .orchd_needs_input.json" run_in_dir "$LIFE_DIR" "$ORCHD" check "check-needs-json"
assert_task_status "check marks task needs_input from JSON artifact" "$LIFE_DIR" "check-needs-json" "needs_input"
STATE_NEEDS_JSON=$(run_in_dir "$LIFE_DIR" "$ORCHD" state --json)
if printf '%s' "$STATE_NEEDS_JSON" | grep -q '"source":"json"' && printf '%s' "$STATE_NEEDS_JSON" | grep -q '"code":"decision_required"'; then
	pass "state exposes structured needs_input payload"
else
	fail "state exposes structured needs_input payload"
fi

mkdir -p "$LIFE_DIR/.orchd/tasks/state-json-hardening"
printf 'pending\n' >"$LIFE_DIR/.orchd/tasks/state-json-hardening/status"
printf 'maybe\n' >"$LIFE_DIR/.orchd/tasks/state-json-hardening/routing_fallback_used"
printf 'abc\n' >"$LIFE_DIR/.orchd/tasks/state-json-hardening/failure_streak"
printf 'oops\n' >"$LIFE_DIR/.orchd/tasks/state-json-hardening/routing_fallback_count"
STATE_JSON_HARDENING=$(run_in_dir "$LIFE_DIR" "$ORCHD" state --json)
STATE_JSON_HARDENING_RESULT=$(python -c 'import json, sys; data = json.load(sys.stdin); task = next(t for t in data["tasks"] if t["id"] == "state-json-hardening"); print("{}|{}|{}".format(str(task["routing_fallback_used"]).lower(), task["failure_streak"], task["routing_fallback_count"]))' <<<"$STATE_JSON_HARDENING")
if [[ "$STATE_JSON_HARDENING_RESULT" == "false|0|0" ]]; then
	pass "state json sanitizes malformed boolean and numeric task metadata"
else
	fail "state json sanitizes malformed boolean and numeric task metadata"
fi

printf '\n[19] Help includes new commands\n'
assert_output_contains "help shows memory" "memory" "$ORCHD" --help
assert_output_contains "help shows idea" "idea" "$ORCHD" --help
assert_output_contains "help shows fleet" "fleet" "$ORCHD" --help

printf '\n[20] Ideate (autonomous backlog)\n'
assert_exit_0 "ideate --help exits 0" "$ORCHD" ideate --help
assert_output_contains "autopilot help shows continuous" "--continuous" "$ORCHD" autopilot --help

# Parse-only tests (no real runner invocation)
run_in_dir "$INIT_DIR" "$ORCHD" idea clear --force >/dev/null 2>&1 || true

ORCHD_LIB_DIR="$(dirname "$ORCHD")/../lib"
IDEATE_OUT="$INIT_DIR/.orchd/ideate_test_out.txt"
cat >"$IDEATE_OUT" <<'EOF'
IDEA: Add health check endpoint
REASON: Needed for ops readiness and monitoring

IDEA: Implement auth middleware
REASON: Required by project goals for secure endpoints

IDEA: Add integration tests for login
REASON: Prevent regressions and validate auth flow

IDEA: Add OpenAPI spec generation
REASON: Improves API usability and contract clarity

IDEA: Add rate limiting to auth endpoints
REASON: Security hardening for brute force prevention

IDEA: Improve logging format
REASON: Helps debugging and observability

IDEA: Add CI workflow
REASON: Enforces quality gates automatically
EOF

IDEATE_QUEUED_COUNT=$(
	cd "$INIT_DIR" || exit 1
	# shellcheck source=../lib/core.sh
	source "$ORCHD_LIB_DIR/core.sh"
	# shellcheck source=../lib/cmd/ideate.sh
	source "$ORCHD_LIB_DIR/cmd/ideate.sh"
	# These variables are used by sourced helpers.
	# shellcheck disable=SC2034
	PROJECT_ROOT="$INIT_DIR"
	ORCHD_DIR="$INIT_DIR/.orchd"
	# shellcheck disable=SC2034
	TASKS_DIR="$ORCHD_DIR/tasks"
	# shellcheck disable=SC2034
	LOGS_DIR="$ORCHD_DIR/logs"
	mkdir -p "$TASKS_DIR" "$LOGS_DIR"
	_ideate_parse_output "$IDEATE_OUT" false >/dev/null 2>&1 || exit 1
	queue_count
)
if [[ "$IDEATE_QUEUED_COUNT" == "5" ]]; then
	pass "ideate parse queues max_ideas (default 5)"
else
	fail "ideate parse queues max_ideas (expected 5, got: $IDEATE_QUEUED_COUNT)"
fi

IDEATE_COMPLETE_OUT="$INIT_DIR/.orchd/ideate_complete_out.txt"
cat >"$IDEATE_COMPLETE_OUT" <<'EOF'
PROJECT_COMPLETE
REASON: All goals in the project brief are satisfied.
EOF

IDEATE_COMPLETE_RC=$(
	cd "$INIT_DIR" || exit 1
	# shellcheck source=../lib/core.sh
	source "$ORCHD_LIB_DIR/core.sh"
	# shellcheck source=../lib/cmd/ideate.sh
	source "$ORCHD_LIB_DIR/cmd/ideate.sh"
	# shellcheck disable=SC2034
	PROJECT_ROOT="$INIT_DIR"
	ORCHD_DIR="$INIT_DIR/.orchd"
	# shellcheck disable=SC2034
	TASKS_DIR="$ORCHD_DIR/tasks"
	# shellcheck disable=SC2034
	LOGS_DIR="$ORCHD_DIR/logs"
	set +e
	_ideate_parse_output "$IDEATE_COMPLETE_OUT" true true >/dev/null 2>&1
	echo "$?"
)
if [[ "$IDEATE_COMPLETE_RC" == "2" ]]; then
	pass "ideate parse returns PROJECT_COMPLETE in strict mode"
else
	fail "ideate parse returns PROJECT_COMPLETE in strict mode (expected 2, got: $IDEATE_COMPLETE_RC)"
fi

IDEATE_FOLLOW_ON_RC=$(
	cd "$INIT_DIR" || exit 1
	# shellcheck source=../lib/core.sh
	source "$ORCHD_LIB_DIR/core.sh"
	# shellcheck source=../lib/cmd/ideate.sh
	source "$ORCHD_LIB_DIR/cmd/ideate.sh"
	# shellcheck disable=SC2034
	PROJECT_ROOT="$INIT_DIR"
	ORCHD_DIR="$INIT_DIR/.orchd"
	# shellcheck disable=SC2034
	TASKS_DIR="$ORCHD_DIR/tasks"
	# shellcheck disable=SC2034
	LOGS_DIR="$ORCHD_DIR/logs"
	set +e
	_ideate_parse_output "$IDEATE_COMPLETE_OUT" true false >/dev/null 2>&1
	echo "$?"
)
if [[ "$IDEATE_FOLLOW_ON_RC" == "2" ]]; then
	pass "ideate parse defers PROJECT_COMPLETE in follow-on mode"
else
	fail "ideate parse defers PROJECT_COMPLETE in follow-on mode (expected 2, got: $IDEATE_FOLLOW_ON_RC)"
fi

IDEATE_FOLLOW_ON_RUNNER="$INIT_DIR/.orchd/ideate_follow_on_runner.sh"
cat >"$IDEATE_FOLLOW_ON_RUNNER" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
worktree=$1
counter_file="$worktree/.orchd/ideate_follow_on_counter"
count=$(cat "$counter_file" 2>/dev/null || printf '0')
count=$((count + 1))
printf '%s\n' "$count" >"$counter_file"
if [[ "$count" == "1" ]]; then
	printf 'PROJECT_COMPLETE\n'
	printf 'REASON: The original brief is fully shipped.\n'
	exit 0
fi
printf 'IDEA: Add release telemetry dashboards\n'
printf 'REASON: Improves post-launch observability after the original scope ships.\n'
EOF
chmod +x "$IDEATE_FOLLOW_ON_RUNNER"
set_config_value "$INIT_DIR/.orchd.toml" "runners.custom" "custom_runner_cmd" "\"$IDEATE_FOLLOW_ON_RUNNER {worktree}\""
run_in_dir "$INIT_DIR" "$ORCHD" idea clear --force >/dev/null 2>&1 || true

assert_exit_0 "ideate retries with follow-on pass after PROJECT_COMPLETE" run_in_dir "$INIT_DIR" "$ORCHD" ideate --runner custom
assert_output_contains "ideate follow-on queues next-phase idea" "Add release telemetry dashboards" run_in_dir "$INIT_DIR" "$ORCHD" idea list

if [[ $(cat "$INIT_DIR/.orchd/ideate_follow_on_counter" 2>/dev/null || printf '0') == "2" ]]; then
	pass "ideate follow-on runner is invoked twice"
else
	fail "ideate follow-on runner is invoked twice"
fi

assert_output_contains "ideate records next-phase finisher state" "next_phase_available" cat "$INIT_DIR/.orchd/finish/state"

printf '\n[20b] Swarm rollout docs\n'
assert_output_contains "README documents swarm_mode rollout" "swarm_mode" cat "$REPO_ROOT/README.md"
assert_output_contains "README documents auto_review policy" "auto_review" cat "$REPO_ROOT/README.md"
assert_output_contains "README documents agent-first workflow" "agent-prompt orchestrator" cat "$REPO_ROOT/README.md"
assert_output_contains "ORCHESTRATOR docs mention finish" "orchd finish" cat "$REPO_ROOT/ORCHESTRATOR.md"
assert_output_contains "ORCHESTRATOR docs mention agent-first handoff" "agent-prompt orchestrator" cat "$REPO_ROOT/ORCHESTRATOR.md"
assert_output_contains "runbook documents observe rollout" "observe" cat "$REPO_ROOT/orchestrator-runbook.md"

printf '\n[21] Claude resume-session orchestrator\n'
CLAUDE_DIR=$(mktemp -d)
git -C "$CLAUDE_DIR" init -q
git -C "$CLAUDE_DIR" config user.name "orchd-test"
git -C "$CLAUDE_DIR" config user.email "test@orchd.dev"
git -C "$CLAUDE_DIR" commit --allow-empty -m "init" -q
assert_exit_0 "init claude lifecycle repo succeeds" "$ORCHD" init "$CLAUDE_DIR"
set_config_value "$CLAUDE_DIR/.orchd.toml" "orchestrator" "runner" '"claude"'
set_config_value "$CLAUDE_DIR/.orchd.toml" "orchestrator" "session_mode" '"resume"'
set_config_value "$CLAUDE_DIR/.orchd.toml" "orchestrator" "continue_delay" '0'
set_config_value "$CLAUDE_DIR/.orchd.toml" "orchestrator" "max_iterations" '4'
set_config_value "$CLAUDE_DIR/.orchd.toml" "orchestrator" "max_stagnation" '10'

CLAUDE_FAKE_BIN="$CLAUDE_DIR/fake-claude.sh"
cat >"$CLAUDE_FAKE_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
workdir=$(pwd)
count_file="$workdir/.orchd/fake_claude_count"
log_file="$workdir/.orchd/fake_claude_invocations.log"
count=$(cat "$count_file" 2>/dev/null || printf '0')
count=$((count + 1))
printf '%s\n' "$count" >"$count_file"
printf 'CALL %s ::' "$count" >>"$log_file"
for arg in "$@"; do
	printf ' [%s]' "$arg" >>"$log_file"
done
printf '\n' >>"$log_file"
if [[ "$count" == "1" ]]; then
	printf 'ORCHD_RESULT: CONTINUE\n'
	printf 'ORCHD_REASON: first turn complete\n'
	exit 0
fi
printf 'ORCHD_RESULT: NEEDS_INPUT\n'
printf 'ORCHD_REASON: stop after resume verification\n'
EOF
chmod +x "$CLAUDE_FAKE_BIN"
printf '\nclaude_bin = "%s"\n' "$CLAUDE_FAKE_BIN" >>"$CLAUDE_DIR/.orchd.toml"

assert_exit_0 "orchestrate reuses Claude session across turns" run_in_dir "$CLAUDE_DIR" bash -lc '"$0" orchestrate 0 >/dev/null 2>&1; test "$?" -eq 2' "$ORCHD"

if grep -q -- '--session-id' "$CLAUDE_DIR/.orchd/fake_claude_invocations.log" && grep -q -- ' -r ' <(tr '[]' ' ' <"$CLAUDE_DIR/.orchd/fake_claude_invocations.log"); then
	pass "claude orchestrator starts then resumes managed session"
else
	fail "claude orchestrator starts then resumes managed session"
fi

CLAUDE_RESUME_SID=$(cat "$CLAUDE_DIR/.orchd/orchestrator/resume_session_id" 2>/dev/null || true)
CLAUDE_LOG_SIDS=$(
	python - "$CLAUDE_DIR/.orchd/fake_claude_invocations.log" <<'PY'
from pathlib import Path
import re
import sys
text = Path(sys.argv[1]).read_text()
session_ids = re.findall(r'--session-id\] \[([^\]]+)\]|-r\] \[([^\]]+)\]', text)
flat = [a or b for a, b in session_ids]
print("\n".join(flat))
PY
)
if [[ -n "$CLAUDE_RESUME_SID" ]] && [[ $(printf '%s\n' "$CLAUDE_LOG_SIDS" | sort -u | wc -l | tr -d ' ') == "1" ]] && [[ "$CLAUDE_RESUME_SID" == "$(printf '%s\n' "$CLAUDE_LOG_SIDS" | head -n 1)" ]]; then
	pass "claude orchestrator persists one session id across iterations"
else
	fail "claude orchestrator persists one session id across iterations"
fi

if grep -q '<system-reminder>' "$CLAUDE_DIR/.orchd/orchestrator/iterations/0002.prompt.txt"; then
	pass "claude resumed prompt includes system reminder block"
else
	fail "claude resumed prompt includes system reminder block"
fi

printf '\n[22] Claude auto-fallback orchestrator\n'
CLAUDE_AUTO_FALLBACK_DIR=$(mktemp -d)
git -C "$CLAUDE_AUTO_FALLBACK_DIR" init -q
git -C "$CLAUDE_AUTO_FALLBACK_DIR" config user.name "orchd-test"
git -C "$CLAUDE_AUTO_FALLBACK_DIR" config user.email "test@orchd.dev"
git -C "$CLAUDE_AUTO_FALLBACK_DIR" commit --allow-empty -m "init" -q
assert_exit_0 "init claude auto-fallback repo succeeds" "$ORCHD" init "$CLAUDE_AUTO_FALLBACK_DIR"
set_config_value "$CLAUDE_AUTO_FALLBACK_DIR/.orchd.toml" "orchestrator" "runner" '"claude"'
set_config_value "$CLAUDE_AUTO_FALLBACK_DIR/.orchd.toml" "orchestrator" "session_mode" '"auto"'
set_config_value "$CLAUDE_AUTO_FALLBACK_DIR/.orchd.toml" "orchestrator" "continue_delay" '0'
set_config_value "$CLAUDE_AUTO_FALLBACK_DIR/.orchd.toml" "orchestrator" "max_iterations" '2'
set_config_value "$CLAUDE_AUTO_FALLBACK_DIR/.orchd.toml" "orchestrator" "max_stagnation" '4'

CLAUDE_AUTO_FALLBACK_BIN="$CLAUDE_AUTO_FALLBACK_DIR/fake-claude-auto.sh"
cat >"$CLAUDE_AUTO_FALLBACK_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
workdir=$(pwd)
log_file="$workdir/.orchd/fake_claude_auto.log"
printf 'CALL ::' >>"$log_file"
for arg in "$@"; do
	printf ' [%s]' "$arg" >>"$log_file"
done
printf '\n' >>"$log_file"
if [[ "${1:-}" == "-p" ]]; then
	printf 'ORCHD_RESULT: NEEDS_INPUT\n'
	printf 'ORCHD_REASON: managed fallback reached\n'
	exit 0
fi
printf 'Authentication required\n'
exit 1
EOF
chmod +x "$CLAUDE_AUTO_FALLBACK_BIN"
printf '\nclaude_bin = "%s"\n' "$CLAUDE_AUTO_FALLBACK_BIN" >>"$CLAUDE_AUTO_FALLBACK_DIR/.orchd.toml"

assert_exit_0 "claude auto mode falls back when sticky startup fails" run_in_dir "$CLAUDE_AUTO_FALLBACK_DIR" bash -lc '"$0" orchestrate 0 >/dev/null 2>&1; test "$?" -eq 2' "$ORCHD"
if grep -q -- '--session-id' "$CLAUDE_AUTO_FALLBACK_DIR/.orchd/fake_claude_auto.log"; then
	pass "claude auto fallback reaches managed resume path after sticky failure"
else
	fail "claude auto fallback reaches managed resume path after sticky failure"
fi

printf '\n[23] Claude sticky-session orchestrator\n'
CLAUDE_STICKY_DIR=$(mktemp -d)
git -C "$CLAUDE_STICKY_DIR" init -q
git -C "$CLAUDE_STICKY_DIR" config user.name "orchd-test"
git -C "$CLAUDE_STICKY_DIR" config user.email "test@orchd.dev"
git -C "$CLAUDE_STICKY_DIR" commit --allow-empty -m "init" -q
assert_exit_0 "init claude sticky repo succeeds" "$ORCHD" init "$CLAUDE_STICKY_DIR"
set_config_value "$CLAUDE_STICKY_DIR/.orchd.toml" "orchestrator" "runner" '"claude"'
set_config_value "$CLAUDE_STICKY_DIR/.orchd.toml" "orchestrator" "session_mode" '"sticky"'
set_config_value "$CLAUDE_STICKY_DIR/.orchd.toml" "orchestrator" "continue_delay" '0'
set_config_value "$CLAUDE_STICKY_DIR/.orchd.toml" "orchestrator" "idle_timeout" '1'
set_config_value "$CLAUDE_STICKY_DIR/.orchd.toml" "orchestrator" "reminder_cooldown" '0'
set_config_value "$CLAUDE_STICKY_DIR/.orchd.toml" "orchestrator" "max_iterations" '4'
set_config_value "$CLAUDE_STICKY_DIR/.orchd.toml" "orchestrator" "max_stagnation" '20'

CLAUDE_STICKY_FAKE_BIN="$CLAUDE_STICKY_DIR/fake-claude-sticky.sh"
cat >"$CLAUDE_STICKY_FAKE_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
workdir=$(pwd)
log_file="$workdir/.orchd/fake_claude_sticky.log"
printf 'Accessing workspace:\n\n%s\n\n' "$workdir"
printf '❯ 1. Yes, I trust this folder\n'
printf '  2. No, exit\n'
read -r _trust || exit 1
printf '▐▛███▜▌   Claude Code vTEST\n'
printf 'Welcome to Claude\n'
printf '? for shortcuts\n'
count=0
while true; do
  buffer=""
  if ! IFS= read -r line; then
    exit 0
  fi
  buffer+="$line"
  while IFS= read -r -t 0.2 line; do
    buffer+=$'\n'$line
  done
  [[ -n "${buffer//[[:space:]]/}" ]] || continue
  count=$((count + 1))
  printf 'PROMPT %s\n%s\n---\n' "$count" "$buffer" >>"$log_file"
  if [[ "$count" == "1" ]]; then
    printf 'ORCHD_RESULT: CONTINUE\n'
    printf 'ORCHD_REASON: waiting for reminder\n'
  else
    printf 'ORCHD_RESULT: NEEDS_INPUT\n'
    printf 'ORCHD_REASON: sticky reminder observed\n'
  fi
done
EOF
chmod +x "$CLAUDE_STICKY_FAKE_BIN"
printf '\nclaude_bin = "%s"\n' "$CLAUDE_STICKY_FAKE_BIN" >>"$CLAUDE_STICKY_DIR/.orchd.toml"

assert_exit_0 "claude sticky orchestrator wakes idle session" run_in_dir "$CLAUDE_STICKY_DIR" bash -lc '"$0" orchestrate 1 >/dev/null 2>&1; test "$?" -eq 2' "$ORCHD"

if grep -q 'PROMPT 2' "$CLAUDE_STICKY_DIR/.orchd/fake_claude_sticky.log"; then
	pass "claude sticky session receives reminder turn"
else
	fail "claude sticky session receives reminder turn"
fi

if grep -q '<system-reminder>' "$CLAUDE_STICKY_DIR/.orchd/fake_claude_sticky.log"; then
	pass "claude sticky reminder includes system reminder block"
else
	fail "claude sticky reminder includes system reminder block"
fi

# --- Summary ---

printf '\n=== Results: %d passed, %d failed, %d total ===\n' "$PASS" "$FAIL" "$TOTAL"

if ((FAIL > 0)); then
	exit 1
fi
