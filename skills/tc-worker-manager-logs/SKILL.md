---
name: tc-worker-manager-logs
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
Do not build raw Cloud Logging queries for this workflow.

## References

- [README](references/README.md): setup, config, routing.
- [Log schema](references/log-schema.md): fields, output modes, query patterns.

## USE FOR:

Provisioning failures, registration errors, Azure scanner health, worker
lifecycle gaps, and single-VM traces.

## Out Of Scope

Task status, live task logs, artifacts, retriggers, in-VM worker logs, and
Azure VM/disk/NIC control-plane lifecycle events are outside this skill.

## Prerequisites

`tc-logview` on `PATH`, `fx-ci` in `~/.config/tc-logview/config.yaml`, synced
references with `tc-logview sync -e fx-ci`, and `jq` for aggregation.

## Examples

```bash
tc-logview list --service worker-manager
tc-logview query -e fx-ci --type worker-removed \
  --where 'workerPoolId=gecko-t/win11-64-25h2' --since 24h --json
```

## Workflow

List types, choose a typed event, filter pools with `--where`, trace VMs with
`--service worker-manager --filter '"vm-..."' --raw`, and use `--json` for
local aggregation.

## Gotchas / Troubleshooting

- Pass `-e fx-ci`; environment auto-detection can fail.
- Use unquoted `--where` values, despite the help text.
- If types are missing, run `tc-logview sync -e fx-ci`.
