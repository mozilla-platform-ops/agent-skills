# Methodology — uptime approximation and the unattributed gap

The query attributes per-task cost from VM cost using:

```
run_cost(task) = LEAST(1.0, task_duration / vm_uptime) * vm_cost(VM, day)
```

**`task_duration`** comes from `fxci_derived.task_runs_v1` —
`resolved - started` in seconds.

**`vm_cost(VM, day)`** comes from `azure_billing_raw.fxci_daily_actual_load` —
sum of `costInBillingCurrency` for that VM on that date.

**`vm_uptime`** is *not* directly observed and is where all the error lives.

## Why uptime is approximated

The GCP side has a real uptime signal — `fxci_derived.worker_metrics_v1`
populated by a Cloud Monitoring puller in `mozilla/docker-etl`. The Azure
side has no equivalent puller. RELOPS-2330 chose to approximate Azure VM
uptime from `task_runs_v1` itself:

```
azure_vm_uptime ≈ MAX(resolved) - MIN(started)   per (worker_id, date)
```

This is the time between the start of the first task and the end of the last
task on that VM that day. It misses:

- **Provisioning time** — VM created → first task starts (typically 30s–10min)
- **Shutdown time** — last task resolves → VM terminated (typically 30s–2min)
- **Multi-day VMs straddling midnight UTC** — the `(worker_id, usage_date)`
  grouping splits one VM-lifetime into per-day buckets

The first two cause the proxy to underestimate real billed uptime. Per-task
cost computed as `task_duration / proxy_uptime × vm_cost` therefore slightly
**overstates** real per-task cost — by 5–15% for most tasks, more for very
short tasks on freshly provisioned VMs.

## Empirical gap decomposition

In a 5-day Azure window with $93,854 total VM spend, here is where every
dollar lives:

| Bucket | VM-days | Cost | Share |
|---|---:|---:|---:|
| 1. Multi-task VMs (normal case) | 44,888 | $62,365 | 66.4% |
| 2. Single-task VMs | 37,232 | $27,066 | 28.8% |
| 3. No tasks at all (provisioning failures, idle warmups) | 8,638 | $3,967 | 4.2% |
| 4. Span ≤ sum_task (overlapping runs, unusual) | 509 | $456 | 0.5% |
| **Total** | **91,267** | **$93,854** | **100%** |

### Bucket 1 — multi-task VMs

These are normal: a VM provisioned, claimed several tasks, terminated. The
attribution formula applies cleanly. Of $62,365 in this bucket, the formula
attributes $54,613 (88%) and leaves $7,751 (12%) as the genuine **idle gap**
between tasks. That 12% is honest unattributed time — there's no specific
task to bill it to.

### Bucket 2 — single-task VMs

For a VM that ran exactly one task:

```
MAX(resolved) - MIN(started)  ==  task_duration
```

So `uptime == task_duration` and `task_duration / uptime == 1.0`.

The original RELOPS-2330 reference query has `WHERE uptime_sec >
task_duration_sec` (strict `>`), which excludes these VMs entirely. The full
$27,066 on these VMs is dropped on the floor, even though the one task that
ran on each of them is the only thing the VM ever did.

**This skill defaults to `>=` and `LEAST(1.0, ratio)`**, which:

- Includes single-task VMs
- Caps the ratio at 1.0 (a single-task VM is 100% attributed to its one task)
- Recovers the entire $27,066 → drops the unattributed gap from 27% to 12%

Trade-off: this overstates per-task cost on single-task VMs by the proportion
of provisioning + shutdown time relative to task time (roughly 10–20%, since
the real billed uptime is `task_duration + 30–120s`). That's worse than the
multi-task VM error band but dramatically better than excluding the VM
entirely.

If you want exact RELOPS-2330 reproduction, change `>=` back to `>` and
remove the `LEAST(1.0, ...)` cap in `queries/04_local_join.sql`.

### Bucket 3 — VMs with no joinable task_runs

Provisioning failures (VM created, never claimed a task), idle warmups
(pools keep N hot VMs even when traffic is low), VMs preempted before any
task started, VMs whose tasks all fell outside the date window. These appear
in `vm_cost` but have no row in `vm_uptime` so the join drops them.

This is real spend that has no task to bill it to. Allocating it
proportionally across active trees is reasonable, but the methodology
doesn't do that automatically.

### Bucket 4 — span ≤ sum_task

Tasks whose intervals overlap on the same VM-day. Could be concurrent runs
on a multi-claim worker, clock-skew artifacts, or `resolved < started` on a
different task pair. Tiny share — flag if it grows.

## What the gap means for per-tree numbers

With the `>=` filter (default in this skill):

| Slice | Cost | Status |
|---|---:|---|
| Attributed to tasks (any tree) | $82,533 | Full per-task rows in `azure_per_task.csv` |
| Multi-task idle gap | $7,751 | Unattributable per-task — pool overhead |
| No-task VMs | $3,967 | Unattributable — pure pool overhead / provisioning failures |
| Overlap quirks | $456 | Numerically small, ignore |
| **Azure VM total** | **$93,854** |  |

Per-tree totals are **slight over-counts on single-task VMs** and **slight
under-counts on multi-task VMs**, with the over-counting roughly offsetting
the multi-task idle gap when summed across a long window.

If you want a defensible per-tree number, treat the per-task sum as
**within ±10%** rather than as a point estimate.

If you want a tighter bound, run the strict `>` variant (matches RELOPS-2330
exactly) and add the proportional share of the unattributed pool — see
`queries/04_local_join.sql` for how to flip filters.

## What would close the remaining 12%

In rough order of effort:

1. **Pull `task_runs` from a wider window** (e.g., ±1 day) to catch tasks
   on VMs that crossed midnight UTC. Modest improvement.
2. **Build an Azure VM lifecycle puller** in `mozilla/docker-etl` to feed a
   `worker_metrics_azure_v1` analog — eliminates the provisioning + shutdown
   error and gives real per-VM uptime. Documented as future work in
   RELOPS-2330; estimated ~1 week of docker-etl development.
3. **Use Azure activity-log VM-create / VM-delete events** as the uptime
   signal — same idea, leverages existing Splunk data instead of a new
   puller. Cheaper but messier (Splunk → BQ syndication).

Until one of those lands, the `>=` default in this skill is the best
available approximation.

## Related caveats unrelated to the gap

- **Hardware pools** (`releng-hardware`: Mac, Windows hardware, talos /
  browsertime perftest) are bare-metal. They never appear in either billing
  export. Cost is allocated to the pool by IT-ops, not per-task attributable
  via this skill.
- **`tags.project`** is the tree (autoland, try, mozilla-central), not the
  individual try-push. For per-push attribution, use `task_group_id`.
- **The GCP side** (`task_run_costs_v1`) has its own ~10–15% gap from
  similar dynamics — idle time, single-task VMs. The production table
  attributes only what it can; the rest sits in `worker_costs_v1` as
  unallocated VM cost.
