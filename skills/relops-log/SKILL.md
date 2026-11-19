---
name: relops-log
description: >
  Use when asked for a RelOps log sweep, daily health check, or what broke in
  the last 24 hours. Sweeps Taskcluster service logs (tc-logview), worker
  guest logs (paperctl), and ronin_puppet Kitchen Windows CI failures, then
  groups findings by impact severity. DO NOT USE FOR one worker, task, or
  pool; use the specific skill.
---

# RelOps Log Sweep

## Prerequisites

`uv`, plus these CLIs on `PATH` (Windows, Linux, or macOS):

- `tc-logview` authenticated for `fx-ci` (see **taskcluster-worker-lifecycle-logs**).
- `paperctl` with `SWO_API_TOKEN` set.
- `gh` with read access to `mozilla-platform-ops/ronin_puppet`.

## Usage

```bash
uv run ~/.claude/skills/relops-log/scripts/sweep.py
```

It takes approximately 1-3 minutes. Options: `--hours N`, `--skip taskcluster|papertrail|kitchen`,
`--out FILE` (default `relops-log.json` in the temp dir).

| Section | Source |
|---------|--------|
| `taskcluster` | Taskcluster service errors (mozlog severity <= ERROR) |
| `worker_errors` | worker-manager `worker-error` by pool |
| `papertrail` | **Sampled** guest ERROR/CRITICAL/ALERT, with host count and host class |
| `papertrail_emergency` | EMERGENCY lines that contain failure words |
| `kitchen_windows` | Failed runs, failed jobs, error lines, latest `master` result |

Each signature has `key`, `count`, `first_seen`, `last_seen`, `sample`, and `top` (pools or host classes).

Read [references/triage.md](references/triage.md) before you assign
severity or write the report.

## Gotchas

- Papertrail is sampled (`--pt-limit` newest events per hour). Compare
  counts only. Get real counts with `paperctl search`.
- `generic-worker`, `run-start-worker`, `run-puppet.sh`, and `sudo` log most
  lines as EMERGENCY. That is why EMERGENCY is filtered by text.
- GCP `severity>=ERROR` is useless in tc-logview: GKE marks all stderr as Error.
- Cloud Logging quota is shared. The script queries 1h windows and retries on
  `RESOURCE_EXHAUSTED`. Report any `window_errors` as gaps.

## Related Skills

**taskcluster-worker-lifecycle-logs**, **queue-diagnosis**, **production-image-deploy**.
