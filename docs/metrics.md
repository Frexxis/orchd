# orchd Throughput Metrics

This document defines the throughput metrics exposed by `orchd state --json` and surfaced in `orchd tui`.

## KPI Block

`orchd state --json` now includes:

```json
"kpi": {
  "merged_tasks_per_day": 0,
  "cycle_time_p50_seconds": 0,
  "cycle_time_p90_seconds": 0,
  "first_pass_check_success_rate": 0
}
```

## Metric Dictionary

- `merged_tasks_per_day`: Count of tasks merged in the current window (currently based on merge completion events).
- `cycle_time_p50_seconds`: Median task cycle time in seconds (spawn -> merged).
- `cycle_time_p90_seconds`: 90th percentile cycle time in seconds.
- `first_pass_check_success_rate`: Percent of tasks that pass quality gate on first check attempt.

## Data Source

Metrics are computed from telemetry events written to:

- `.orchd/metrics/events.jsonl`

Each line is JSON and includes `ts`, `event`, `task_id`, `status`, `duration_ms`, and `details`.

## Throughput Modes

Configure in `.orchd.toml`:

```toml
[orchestrator]
throughput_mode = "on" # off | observe | on
```

- `off`: Disable throughput-oriented scheduling behavior.
- `observe`: Keep current behavior but collect/report throughput metrics.
- `on`: Enable throughput-oriented scheduling and adaptive controls.

## Target SLOs (Suggested)

- 2x increase in merged tasks/day over baseline
- 40%+ reduction in p50 cycle time
- 25%+ increase in first-pass check success rate
- No increase in permanent `needs_input` blockers
