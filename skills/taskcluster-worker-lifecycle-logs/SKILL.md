---
name: taskcluster-worker-lifecycle-logs
description: >
  Use when investigating Taskcluster worker-manager/worker-scanner
  provisioning, registration, Azure scanner, lifecycle, or VM-trace issues
  with tc-logview. Covers stuck workers, registration failures,
  OperationPreempted, scan-seen health, worker-error, and worker-removed.
  DO NOT USE FOR task logs, artifacts, retriggers, in-VM logs, or Azure
  control-plane logs.
---

# Taskcluster Worker-Manager Logs

Use [`tc-logview`](https://github.com/taskcluster/tc-logview) for service logs.
The installed tool is the source of truth for flags, auth, log types, and
fields. Read its help before you build a query.

## Scope

| Log | Use |
|-----|-----|
| Taskcluster service logs (worker-manager, worker-scanner) | This skill |
| Worker guest logs (generic-worker, OS) | **papertrail** |
| Azure control-plane (VM, disk, NIC) | Azure Activity Log |
| Task logs and artifacts | **taskcluster** |

## Prerequisites

```bash
go install github.com/taskcluster/tc-logview@latest
tc-logview config init
tc-logview auth
tc-logview sync -e fx-ci
```

## Usage

```bash
tc-logview --help
tc-logview query --help
tc-logview list --service worker-manager   # types and typed fields
```

Pick a type from `list`, filter with `--where`, search payload text with
`--filter`, and use `--json` for `jq` or `--raw` for fields that are not typed.

## Gotchas

- Pass `-e fx-ci`. Auto-detection can fail.
- Do not quote `--where` values, even if the help text shows quotes.
- If `list` shows no types, run `tc-logview sync -e fx-ci`.
- Cloud Logging read quota is shared. Long windows fail with
  `RESOURCE_EXHAUSTED`. Query in 1h `--from/--to` windows.
