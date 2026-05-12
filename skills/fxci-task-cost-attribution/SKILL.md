---
name: fxci-task-cost-attribution
description: >
  Compute per-task or per-push cost for FXCI tasks across both clouds (GCP +
  Azure) by joining BigQuery billing exports, Taskcluster worker metrics,
  `fxci_derived.task_runs_v1`, and `fxci_derived.tasks_v2`. Use when answering "how much did task X cost",
  "how much did this push cost", "what does an autoland run cost", or "what's
  the cost breakdown by kind/label/tree for this window". This is the
  per-task counterpart to `azure-cost-analysis` (which does pool/SKU-level
  rollups). Implements the RELOPS-2330 reference query, including the
  cross-account auth split and the local DuckDB join required while the
  end-to-end BigQuery pipeline is still pending. Runs on macOS and Windows.
  Triggers on "per-task cost", "task cost", "cost per task", "task cost
  attribution", "push cost", "autoland cost", "RELOPS-2330", "cross-cloud
  cost", "task_run_costs", "fxci task cost".
---

# FXCI Task Cost Attribution

Per-task and per-push cost attribution for FXCI tasks across both clouds.

For pool-level cost trend / diagnostic work (rate vs volume, spot eviction, SKU
pricing changes), use the [`azure-cost-analysis`](../azure-cost-analysis/) skill
instead — it queries the Azure Cost Management REST API and answers different
questions.

## What this skill does

Joins four datasets to produce a per-task cost row:

1. **GCP billing export** (`moz-fx-data-shared-prod.billing_syndicate.gcp_billing_export_resource_v1_*`) — VM cost per resource per day, GCP side
2. **Azure billing export** (`moz-fx-data-billing-prod-9147.azure_billing_raw.fxci_daily_actual_load`) — VM cost per resource per day, Azure side
3. **Taskcluster worker metrics** (`moz-fx-data-shared-prod.taskclusteretl.worker_metrics`) — Azure generic-worker lifecycle intervals
4. **FXCI task data** (`moz-fx-data-shared-prod.fxci_derived.task_runs_v1`, `tasks_v2`) — task starts/resolves, tree, kind, label

The GCP side already exists in `fxci_derived.task_run_costs_v1`; this skill
joins to that table directly. The Azure side has no production equivalent yet
(RELOPS-2330 is open) — the queries here build it ad-hoc and join locally with
DuckDB because no single human principal currently has read access to both
billing datasets.

## Knowledge References

**Read first:**
- @references/README.md
- @references/auth-split.md — *which gcloud account reads which dataset*
- @references/duckdb-local-join.md — *macOS + Windows install and run instructions*

**Methodology and caveats:**
- @references/methodology.md — *worker-metrics uptime, attribution limits, and what is not covered*

**Background:**
- @references/jira-context.md — *RELOPS-2330 ticket summary and what the production version will look like*

**Standalone queries** (one file per stage, in `queries/`):
- `01_gcp_per_task.sql` — GCP per-task cost via existing `task_run_costs_v1` (single-account)
- `02_azure_vm_cost.sql` — Azure per-VM-day cost from `azure_billing_raw`
- `03_azure_task_runs_all.sql` — All `vm-*` task_runs in window
- `04_azure_worker_metrics.sql` — Azure worker uptime from generic-worker lifecycle events
- `05_local_join.sql` — DuckDB cross-cloud join + per-task cost computation
- `06_summary.sql` — DuckDB aggregations (by tree, kind, label, push)

## Prerequisites

- **Google Cloud SDK (`bq` CLI)**
  - macOS: `brew install --cask google-cloud-sdk`
  - Windows (elevated PowerShell): `choco install -y gcloudsdk`
- **DuckDB CLI**
  - macOS: `brew install duckdb`
  - Windows (elevated PowerShell): `choco install -y duckdb`
  - Full install + run notes in `references/duckdb-local-join.md`
- **Two authenticated gcloud accounts**:
  - `<user>@mozilla.com` — for `moz-fx-data-shared-prod` (`fxci_derived.*`, GCP billing export)
  - `<user>@firefox.gcp.mozilla.com` — for `moz-fx-data-billing-prod-9147` (`azure_billing_raw`)
  - Sign in once each with `gcloud auth login <email>`; switch with `gcloud config set account <email>`
  - See `references/auth-split.md` for why two accounts are required

Without the second account you can still run the GCP-only half (most builds and
all Linux tests) but you cannot attribute Azure (Windows) cost.

## Quick Start

Pick a date window where **both** clouds have complete billing data. Azure
typically lags GCP by 1–2 days. Stick to windows that ended at least 2 days
before today.

### macOS / Linux / Git Bash

```bash
# 1. Pull GCP per-task costs (one account)
gcloud config set account <user>@mozilla.com
bq query --project_id=mozdata --use_legacy_sql=false --format=csv --max_rows=2000000 \
  < queries/01_gcp_per_task.sql > gcp_per_task.csv

# 2. Pull Azure per-VM-day costs (different account, different project)
gcloud config set account <user>@firefox.gcp.mozilla.com
bq query --project_id=moz-fx-data-billing-prod-9147 --use_legacy_sql=false --format=csv --max_rows=200000 \
  < queries/02_azure_vm_cost.sql > azure_vm_cost.csv

# 3. Pull task_runs for vm-* workers across ALL trees (back to first account)
gcloud config set account <user>@mozilla.com
bq query --project_id=mozdata --use_legacy_sql=false --format=csv --max_rows=5000000 \
  < queries/03_azure_task_runs_all.sql > azure_task_runs_all.csv

# 4. Pull Azure worker uptime from Taskcluster worker metrics
bq query --project_id=mozdata --use_legacy_sql=false --format=csv --max_rows=5000000 \
  < queries/04_azure_worker_metrics.sql > azure_worker_uptime.csv

# 5. Local cross-cloud join (DuckDB)
duckdb < queries/05_local_join.sql

# 6. Aggregations
duckdb < queries/06_summary.sql
```

### Windows (PowerShell)

```powershell
# 1. GCP per-task costs
gcloud config set account "<user>@mozilla.com"
Get-Content queries\01_gcp_per_task.sql |
  bq query --project_id=mozdata --use_legacy_sql=false --format=csv --max_rows=2000000 |
  Out-File -Encoding utf8 gcp_per_task.csv

# 2. Azure per-VM-day costs (different account)
gcloud config set account "<user>@firefox.gcp.mozilla.com"
Get-Content queries\02_azure_vm_cost.sql |
  bq query --project_id=moz-fx-data-billing-prod-9147 --use_legacy_sql=false --format=csv --max_rows=200000 |
  Out-File -Encoding utf8 azure_vm_cost.csv

# 3. All vm-* task_runs (back to first account)
gcloud config set account "<user>@mozilla.com"
Get-Content queries\03_azure_task_runs_all.sql |
  bq query --project_id=mozdata --use_legacy_sql=false --format=csv --max_rows=5000000 |
  Out-File -Encoding utf8 azure_task_runs_all.csv

# 4. Azure worker uptime from Taskcluster worker metrics
Get-Content queries\04_azure_worker_metrics.sql |
  bq query --project_id=mozdata --use_legacy_sql=false --format=csv --max_rows=5000000 |
  Out-File -Encoding utf8 azure_worker_uptime.csv

# 5. Local cross-cloud join
Get-Content queries\05_local_join.sql | duckdb

# 6. Aggregations
Get-Content queries\06_summary.sql | duckdb
```

The BigQuery CSVs (`gcp_per_task.csv`, `azure_vm_cost.csv`,
`azure_task_runs_all.csv`, `azure_worker_uptime.csv`) plus the DuckDB-emitted
`azure_per_task.csv` and `autoland_per_task.csv` all land in the working
directory. Use any working dir — DuckDB reads relative paths.

## Editing the date window

Each `.sql` file has placeholders at the top:

```sql
-- WINDOW_START = 'YYYY-MM-DD'
-- WINDOW_END   = 'YYYY-MM-DD'
```

Find-and-replace `2026-04-28` and `2026-05-02` with your window across all six
files before running. Keep the window the same in all files or the join will
miss rows.

## Common follow-up questions

- **"How much did push X cost?"** — Filter `autoland_per_task.csv` by
  `task_group_id`, sum `run_cost_usd`. See `06_summary.sql` for the pattern.
- **"How much does an average autoland run cost?"** — Sum `run_cost_usd`,
  divide by `COUNT(DISTINCT task_group_id)`.
- **"What kind of test costs the most per run on Windows?"** — Filter to
  `cloud='azure'`, group by `kind`, average.

## Caveats (important — read before quoting numbers)

Two systematic accuracy issues. See `references/methodology.md` for the full
treatment.

**1. Worker-metrics uptime is a Taskcluster signal.** Azure uptime comes from
generic-worker lifecycle events in `taskclusteretl.worker_metrics`. This is
better than a first-task/last-task proxy, but it still does not include cloud
resource lifetime after the worker has shut down and before Azure finishes
deleting the VM.

**2. Coverage is VM compute on ephemeral `vm-*` workers.** Network, storage,
bandwidth, management VMs, image-build VMs, and persistent scriptworkers are
not joined. Per-tree numbers should be read as attributable VM-compute cost,
not as a full Azure invoice reconstruction. RELOPS-2330 has the same scope.

**Marginal vs attributed cost.** The skill answers "what share of
attributable VM-compute cost was caused by this task?" *not* "what would we
save by killing this task?" Pool overhead is largely fixed — don't use
these numbers for "cut autoland in half, save half the cost" reasoning.

GCP (`task_run_costs_v1`) uses Cloud Monitoring uptime. Azure uses
Taskcluster worker metrics. `releng-hardware` (talos,
browsertime, Mac, Windows hardware) is bare-metal and never appears in
either billing export.
