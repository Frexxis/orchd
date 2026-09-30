#!/usr/bin/env bash
# lib/metrics.sh - Throughput metrics helpers

_metrics_json_escape() {
	local s=${1-}
	s=${s//\\/\\\\}
	s=${s//"/\\"/}
	s=${s//$'\n'/\\n}
	s=${s//$'\r'/\\r}
	s=${s//$'\t'/\\t}
	printf '%s' "$s"
}

metrics_init() {
	[[ -n "${ORCHD_DIR:-}" ]] || return 0
	mkdir -p "$ORCHD_DIR/metrics"
	touch "$ORCHD_DIR/metrics/events.jsonl"
}

metrics_emit() {
	[[ -n "${ORCHD_DIR:-}" ]] || return 0
	metrics_init

	local event_type=${1:-unknown}
	local task_id=${2:-}
	local status=${3:-}
	local duration_ms=${4:-0}
	local details_json=${5:-"{}"}
	local ts
	ts=$(now_iso)

	printf '{"ts":"%s","event":"%s","task_id":"%s","status":"%s","duration_ms":%s,"details":%s}\n' \
		"$(_metrics_json_escape "$ts")" \
		"$(_metrics_json_escape "$event_type")" \
		"$(_metrics_json_escape "$task_id")" \
		"$(_metrics_json_escape "$status")" \
		"${duration_ms:-0}" \
		"${details_json:-"{}"}" >>"$ORCHD_DIR/metrics/events.jsonl"
}

metrics_rollup_today() {
	local merged_tasks_per_day=0
	local cycle_time_p50_seconds=0
	local cycle_time_p90_seconds=0
	local first_pass_check_success_rate=0

	local events_file="$ORCHD_DIR/metrics/events.jsonl"
	if [[ -f "$events_file" ]]; then
		if command -v python3 >/dev/null 2>&1; then
			local rollup
			rollup=$(
				python3 - "$events_file" <<'PY'
import datetime as dt
import json
import math
import sys

events_path = sys.argv[1]
today = dt.datetime.now(dt.timezone.utc).date()

def parse_ts(raw: str):
    raw = (raw or "").strip()
    if not raw:
        return None
    try:
        return dt.datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except Exception:
        return None

events = []
with open(events_path, "r", encoding="utf-8", errors="ignore") as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except Exception:
            continue
        ts = parse_ts(obj.get("ts", ""))
        if ts is None:
            continue
        if ts.astimezone(dt.timezone.utc).date() != today:
            continue
        events.append((ts, obj))

events.sort(key=lambda it: it[0])

merged = sum(1 for _, e in events if e.get("event") == "merge.completed")

spawn_first = {}
merge_first = {}
for ts, e in events:
    ev = e.get("event")
    tid = (e.get("task_id") or "").strip()
    if not tid:
        continue
    if ev == "spawn.started" and tid not in spawn_first:
        spawn_first[tid] = ts
    if ev == "merge.completed" and tid not in merge_first:
        merge_first[tid] = ts

durations = []
for tid, merge_ts in merge_first.items():
    spawn_ts = spawn_first.get(tid)
    if spawn_ts is None:
        continue
    sec = (merge_ts - spawn_ts).total_seconds()
    if sec >= 0:
        durations.append(int(round(sec)))

def percentile(values, p):
    if not values:
        return 0
    values = sorted(values)
    rank = math.ceil((p / 100.0) * len(values)) - 1
    if rank < 0:
        rank = 0
    if rank >= len(values):
        rank = len(values) - 1
    return int(values[rank])

p50 = percentile(durations, 50)
p90 = percentile(durations, 90)

first_checks = {}
for _, e in events:
    if e.get("event") != "check.completed":
        continue
    tid = (e.get("task_id") or "").strip()
    if not tid or tid in first_checks:
        continue
    status = (e.get("status") or "").strip().lower()
    first_checks[tid] = 1 if status == "done" else 0

if first_checks:
    rate = (sum(first_checks.values()) * 100.0) / len(first_checks)
else:
    rate = 0.0

if float(rate).is_integer():
    rate_out = str(int(rate))
else:
    rate_out = f"{rate:.2f}".rstrip("0").rstrip(".")

print(f"{merged} {p50} {p90} {rate_out}")
PY
			)
			if [[ -n "$rollup" ]]; then
				read -r merged_tasks_per_day cycle_time_p50_seconds cycle_time_p90_seconds first_pass_check_success_rate <<<"$rollup"
			fi
		else
			merged_tasks_per_day=$(grep -c '"event":"merge.completed"' "$events_file" 2>/dev/null || printf '0')
		fi
	fi

	printf '%s %s %s %s\n' \
		"$merged_tasks_per_day" \
		"$cycle_time_p50_seconds" \
		"$cycle_time_p90_seconds" \
		"$first_pass_check_success_rate"
}

metrics_rollup_window_hours() {
	metrics_rollup_today
}

metrics_kpi_json() {
	local merged p50 p90 first_pass
	read -r merged p50 p90 first_pass < <(metrics_rollup_today)
	printf '{"merged_tasks_per_day":%s,"cycle_time_p50_seconds":%s,"cycle_time_p90_seconds":%s,"first_pass_check_success_rate":%s}' \
		"${merged:-0}" \
		"${p50:-0}" \
		"${p90:-0}" \
		"${first_pass:-0}"
}
