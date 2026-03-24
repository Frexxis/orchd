#!/usr/bin/env bash

_agent_prompt_git_root() {
	git -C "${1:-$PWD}" rev-parse --show-toplevel 2>/dev/null || true
}

_agent_prompt_initialized_hint() {
	local repo_root=$1
	if [[ -n "$repo_root" && -f "$repo_root/.orchd.toml" ]]; then
		printf '%s\n' "The repository already has orchd configured. Start by reading the local orchd docs, then inspect state with \`orchd doctor\` and \`orchd state --json\`."
	else
		printf '%s\n' "If \`.orchd.toml\` does not exist yet, run \`orchd init .\` first, then \`orchd doctor\`, then \`orchd state --json\`."
	fi
}

_agent_prompt_orchestrator() {
	local repo_root=$1
	local goal=$2
	cat <<EOF
You are the active orchestrator for this repository.
Use \`orchd\` as the orchestration system instead of ad-hoc task tracking.

Repository root: ${repo_root:-$PWD}

$(_agent_prompt_initialized_hint "$repo_root")

First actions:
1. Read \`AGENTS.md\`.
2. Read \`ORCHESTRATOR.md\` and \`orchestrator-runbook.md\`.
3. Run \`orchd doctor\`.
4. Run \`orchd state --json\`.
5. If no meaningful task graph exists yet, create one with \`orchd plan\`.
6. Prefer \`orchd finish\` for end-to-end execution unless a manual step-by-step flow is clearly safer.

Operating rules:
- Use orchd commands directly from the repo root.
- Keep the user out of the mechanical loop; do not ask them to manually run orchd commands unless there is a real blocker.
- Use \`orchd board --watch\`, \`orchd state --json\`, \`orchd finish --status\`, and \`orchd finish --logs\` to monitor progress.
- If work already exists, continue it; do not re-plan from scratch unless the current plan is missing or clearly broken.
- If tasks fail, use orchd recovery flow (\`check\`, \`resume\`, \`finish\`) before escalating.

Recommended execution path:
- If initialized and work is already in flight: inspect -> continue with \`orchd finish\`
- If initialized but no plan exists: \`orchd plan "<goal>"\` -> \`orchd finish\`
- If not initialized: \`orchd init .\` -> adjust \`.orchd.toml\` if needed -> \`orchd plan "<goal>"\` -> \`orchd finish\`
EOF
	if [[ -n "$goal" ]]; then
		cat <<EOF

User goal:
$goal

Unless repo state strongly suggests a better continuation path, start by planning or continuing work toward that goal with orchd.
EOF
	fi
}

_agent_prompt_worker() {
	local repo_root=$1
	local goal=$2
	cat <<EOF
MODE: WORKER

You are an orchd worker operating inside repository root: ${repo_root:-$PWD}

First actions:
1. Read \`AGENTS.md\`.
2. Read \`WORKER.md\`.
3. Follow the assigned task scope exactly.

Rules:
- Work only in the assigned task worktree.
- Do not merge to the base branch.
- Leave a complete \`TASK_REPORT.md\` with evidence and rollback notes.
- Let orchd handle orchestration, checking, and merging.
EOF
	if [[ -n "$goal" ]]; then
		cat <<EOF

Assigned task:
$goal
EOF
	fi
}

_agent_prompt_reviewer() {
	local repo_root=$1
	local goal=$2
	cat <<EOF
MODE: REVIEWER

You are an orchd reviewer for repository root: ${repo_root:-$PWD}

First actions:
1. Read \`AGENTS.md\`.
2. Follow review-only constraints.

Rules:
- Do not change code unless explicitly instructed.
- Review the provided diff or task output.
- Return a clear approval or changes-requested outcome with concise reasoning.
EOF
	if [[ -n "$goal" ]]; then
		cat <<EOF

Review target:
$goal
EOF
	fi
}

cmd_agent_prompt() {
	local role="orchestrator"
	case "${1:-}" in
	"") ;;
	orchestrator | worker | reviewer)
		role=$1
		shift
		;;
	-h | --help | help)
		cat <<'EOF'
Usage: orchd agent-prompt [orchestrator|worker|reviewer] [goal...]

Print a copy-paste prompt for an external coding agent.

Examples:
  orchd agent-prompt orchestrator "ship the next release with tests"
  orchd agent-prompt worker "implement task abc-123 in the assigned worktree"
  orchd agent-prompt reviewer "review the diff for task abc-123"
EOF
		return 0
		;;
	esac

	local goal="${*:-}"
	local repo_root
	repo_root=$(_agent_prompt_git_root "$PWD")
	if [[ -z "$repo_root" ]]; then
		repo_root=$PWD
	fi

	case "$role" in
	orchestrator)
		_agent_prompt_orchestrator "$repo_root" "$goal"
		;;
	worker)
		_agent_prompt_worker "$repo_root" "$goal"
		;;
	reviewer)
		_agent_prompt_reviewer "$repo_root" "$goal"
		;;
	*)
		die "unknown agent-prompt role: $role"
		;;
	esac
}
