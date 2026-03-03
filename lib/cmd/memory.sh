#!/usr/bin/env bash
# lib/cmd/memory.sh - orchd memory command
# Manage the project memory bank (docs/memory/).

cmd_memory() {
	local subcmd="${1:-}"
	shift || true

	case "$subcmd" in
	-h | --help)
		cat <<'EOF'
usage:
  orchd memory              Show memory bank status
  orchd memory init         Initialize memory bank scaffold
  orchd memory show         Print all memory bank contents
  orchd memory update       Update progress and active context from task state
  orchd memory reset        Remove all memory bank files (requires --force)
EOF
		return 0
		;;
	init)
		_memory_init
		;;
	show)
		_memory_show
		;;
	update)
		_memory_update
		;;
	reset)
		_memory_reset "$@"
		;;
	"")
		_memory_status
		;;
	*)
		die "unknown memory subcommand: $subcmd (try: orchd memory --help)"
		;;
	esac
}

_memory_init() {
	require_project
	memory_ensure_scaffold

	printf 'memory bank initialized: %s/docs/memory/\n' "$PROJECT_ROOT"
	printf '\nfiles:\n'
	local f
	for f in "${MEMORY_BANK_FILES[@]}"; do
		if [[ -f "$PROJECT_ROOT/docs/memory/$f" ]]; then
			printf '  %s\n' "$f"
		fi
	done
	if [[ -d "$PROJECT_ROOT/docs/memory/lessons" ]]; then
		local lesson_count
		lesson_count=$(find "$PROJECT_ROOT/docs/memory/lessons" -name '*.md' 2>/dev/null | wc -l | tr -d '[:space:]')
		printf '  lessons/ (%s entries)\n' "$lesson_count"
	fi
	printf '\nnext: edit docs/memory/projectbrief.md to define project goals\n'
}

_memory_show() {
	require_project
	local mem_dir="$PROJECT_ROOT/docs/memory"

	if [[ ! -d "$mem_dir" ]]; then
		printf 'no memory bank found (run: orchd memory init)\n'
		return 1
	fi

	local f
	for f in "${MEMORY_BANK_FILES[@]}"; do
		if [[ -f "$mem_dir/$f" ]]; then
			printf '=== %s ===\n\n' "$f"
			cat "$mem_dir/$f"
			printf '\n\n'
		fi
	done

	if [[ -d "$mem_dir/lessons" ]]; then
		local lesson_files=()
		local lf
		while IFS= read -r lf; do
			[[ -n "$lf" ]] && lesson_files+=("$lf")
		done < <(ls -t "$mem_dir/lessons"/*.md 2>/dev/null || true)

		if ((${#lesson_files[@]} > 0)); then
			printf '=== lessons/ (%d entries) ===\n\n' "${#lesson_files[@]}"
			for lf in "${lesson_files[@]}"; do
				cat "$lf"
				printf '\n'
			done
		fi
	fi
}

_memory_update() {
	require_project

	local mem_dir="$PROJECT_ROOT/docs/memory"
	if [[ ! -d "$mem_dir" ]]; then
		memory_ensure_scaffold
	fi

	memory_update_progress
	memory_update_active_context
	printf 'memory bank updated:\n'
	printf '  progress.md      — task state snapshot\n'
	printf '  activeContext.md  — current orchestration state\n'
}

_memory_reset() {
	local force=false
	if [[ "${1:-}" == "--force" ]]; then
		force=true
	fi

	require_project

	local mem_dir="$PROJECT_ROOT/docs/memory"
	if [[ ! -d "$mem_dir" ]]; then
		printf 'no memory bank found\n'
		return 0
	fi

	if ! $force; then
		die "this will delete all memory bank files. Use: orchd memory reset --force"
	fi

	rm -rf "$mem_dir"
	printf 'memory bank removed: %s\n' "$mem_dir"
	log_event "WARN" "memory bank reset by user"
}

_memory_status() {
	require_project
	local mem_dir="$PROJECT_ROOT/docs/memory"

	if [[ ! -d "$mem_dir" ]]; then
		printf 'memory bank: not initialized\n'
		printf '  run: orchd memory init\n'
		return 0
	fi

	printf 'memory bank: %s/docs/memory/\n\n' "$PROJECT_ROOT"

	local f
	for f in "${MEMORY_BANK_FILES[@]}"; do
		if [[ -f "$mem_dir/$f" ]]; then
			local lines
			lines=$(wc -l <"$mem_dir/$f" 2>/dev/null | tr -d '[:space:]')
			printf '  %-22s %s lines\n' "$f" "$lines"
		else
			printf '  %-22s (missing)\n' "$f"
		fi
	done

	if [[ -d "$mem_dir/lessons" ]]; then
		local lesson_count
		lesson_count=$(find "$mem_dir/lessons" -name '*.md' 2>/dev/null | wc -l | tr -d '[:space:]')
		printf '  %-22s %s entries\n' "lessons/" "$lesson_count"
	else
		printf '  %-22s (empty)\n' "lessons/"
	fi

	local total_chars
	local files=()
	local fpath
	for fpath in "$mem_dir"/*.md; do
		[[ -f "$fpath" ]] && files+=("$fpath")
	done
	for fpath in "$mem_dir"/lessons/*.md; do
		[[ -f "$fpath" ]] && files+=("$fpath")
	done
	if ((${#files[@]} > 0)); then
		total_chars=$(cat "${files[@]}" 2>/dev/null | wc -c | tr -d '[:space:]')
	else
		total_chars=0
	fi
	local max_chars
	max_chars=$(config_get "memory_max_chars" "12000")
	printf '\n  total: %s chars (prompt budget: %s)\n' "$total_chars" "$max_chars"
}
