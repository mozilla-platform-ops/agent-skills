# Methodology — Worker Metrics And Attribution

The Azure side attributes per-task VM compute cost with:

```text
run_cost(task) = LEAST(1.0, task_duration / worker_uptime) * vm_cost(VM, day)
```

`task_duration` comes from `fxci_derived.task_runs_v1`:
`resolved - started` in seconds.

`vm_cost(VM, day)` comes from the Azure billing export:
`azure_billing_raw.fxci_daily_actual_load`, grouped by VM name extracted from
`ResourceId`.

`worker_uptime` comes from `taskclusteretl.worker_metrics`, which is populated
from generic-worker `WORKER_METRICS` log events. The skill reconstructs
per-worker daily uptime from lifecycle events such as `instanceBoot`,
`workerReady`, `taskStart`, `taskFinish`, `instanceReboot`, and
`instanceShutdown`.

## Why Worker Metrics

The older fallback was:

```text
MAX(task resolved) - MIN(task started) per worker/day
```

That works as a rough proxy, but it misses boot time before the first task and
shutdown time after the last task. It also treats a single-task VM as if the VM
existed only for the exact task duration.

`taskclusteretl.worker_metrics` is closer to the source we want because the
worker reports its own lifecycle. It is still Taskcluster-side data, not an
Azure billing meter, but it captures more of the worker lifetime than task rows
alone.

## What It Still Misses

Worker metrics stop when the worker stops reporting. Azure can still bill after
that if worker-manager has logically removed the worker but the Azure VM has not
finished deleting yet.

That means this skill can attribute task-active and worker-active VM compute
time. It does not fully attribute post-worker cloud-resource tail time. For that
you need worker-manager lifecycle data, such as `worker-removed`,
`worker-stopped`, and Azure scanner deprovision events, or a production table
that captures equivalent lifecycle events.

## Cross-Tree Denominators

Do not filter the worker metrics or Azure task-run pull to a single tree before
building the denominator. A VM can run tasks from different trees on the same
day. If the denominator only sees one tree, tasks from that tree get too much of
the VM's daily cost.

The skill pulls all `vm-*` Azure task rows and all matching worker metrics for
the date window, then applies the tree filter in `05_local_join.sql`.

## Ratio Cap

The local join uses:

```sql
LEAST(1.0, task_duration_sec / uptime_sec)
```

The cap prevents a short or missing lifecycle interval from assigning more than
one full VM-day row to a task. Rows with no matching uptime are dropped rather
than guessed.

## Coverage

The skill covers VM compute rows for ephemeral `vm-*` workers. It does not join
network, storage, public IP, bandwidth, image-build VMs, management VMs, or
persistent scriptworker resources back to tasks.

Read the output as attributable VM-compute cost, not as the full Azure invoice.
This matches the current RELOPS-2330 scope.

## Marginal Vs Attributed Cost

The skill answers:

```text
What share of attributable VM compute did this task or push consume?
```

It does not answer:

```text
How much money would disappear if this task stopped running?
```

Pool warm capacity, provisioning failures, retry behavior, and post-worker cloud
cleanup can remain even when task volume changes. Use this for attribution and
investigation, not as a direct savings forecast.
