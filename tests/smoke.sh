#!/usr/bin/env bash
# smoke.sh - Basic smoke tests for orchd
set -euo pipefail

ORCHD="$(readlink -f "$(dirname "$0")/../bin/orchd")"
PASS=0
FAIL=0
TOTAL=0

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
	if printf '%s' "$output" | grep -q "$pattern"; then
		pass "$desc"
	else
		fail "$desc (pattern '$pattern' not found in output)"
	fi
}

cleanup() {
	# Stop any test sessions
	tmux kill-session -t "orchd-smoketest" 2>/dev/null || true
	# Remove temp repo
	if [[ -n "${TMPDIR:-}" && -d "$TMPDIR" ]]; then
		rm -rf "$TMPDIR"
	fi
	# Remove test state
	rm -rf "${HOME}/.orchd/orchd-smoketest"
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
assert_output_contains "help output contains Usage" "Usage" "$ORCHD" --help

printf '\n[2] Input validation\n'
assert_exit_nonzero "start with bad dir fails" "$ORCHD" start /nonexistent/path
assert_exit_nonzero "start with bad interval fails" "$ORCHD" start "$TMPDIR" abc
assert_exit_nonzero "attach without session fails" "$ORCHD" attach
assert_exit_nonzero "stop without session fails" "$ORCHD" stop
assert_exit_nonzero "status without session fails" "$ORCHD" status
assert_exit_nonzero "unknown command fails" "$ORCHD" foobar

printf '\n[3] List (no sessions)\n'
assert_output_contains "list shows no sessions msg" "no active" "$ORCHD" list

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

# --- Summary ---

printf '\n=== Results: %d passed, %d failed, %d total ===\n' "$PASS" "$FAIL" "$TOTAL"

if ((FAIL > 0)); then
	exit 1
fi
