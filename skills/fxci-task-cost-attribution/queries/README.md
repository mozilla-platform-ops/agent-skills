# Standalone queries

Five files, run in order. Stages 1–3 hit BigQuery (with **different gcloud
accounts** — see `../references/auth-split.md`). Stages 4–5 run locally with
DuckDB.

| File | Where it runs | Account | Output |
|---|---|---|---|
| `01_gcp_per_task.sql` | BigQuery (`mozdata`) | `<user>@mozilla.com` | `gcp_per_task.csv` |
| `02_azure_vm_cost.sql` | BigQuery (`moz-fx-data-billing-prod-9147`) | `<user>@firefox.gcp.mozilla.com` | `azure_vm_cost.csv` |
| `03_azure_task_runs_all.sql` | BigQuery (`mozdata`) | `<user>@mozilla.com` | `azure_task_runs_all.csv` |
| `04_local_join.sql` | DuckDB (local) | n/a | `azure_per_task.csv` |
| `05_summary.sql` | DuckDB (local) | n/a | `autoland_per_task.csv` + reports |

## Editing the date window

Every `.sql` file has the same `WINDOW_START` / `WINDOW_END` placeholders at
the top. Find-and-replace `2026-04-28` and `2026-05-02` consistently across all
five files before running.

Pick a window where **both clouds** have complete billing data. Azure typically
lags GCP by 1–2 days. Don't run windows that include the last two days.

## Default tree filter

Stages 1 and 5 default to `tree = 'autoland'`. Change the
`t.tags.project = 'autoland'` predicate (stage 1) and the
`tr.tree = 'autoland'` predicate (stage 4) for `try`, `mozilla-central`, etc.
Stage 3 has no tree filter on purpose — uptime denominator must be cross-tree.

## How to use

1. Open the file
2. Replace the date window placeholders
3. Optional: change the tree filter
4. Run via `bq query` (stages 1–3) or `duckdb` (stages 4–5) — see `../SKILL.md`
   for full macOS and Windows command lines

## Why no consolidated query

A single SQL statement that covers both clouds end-to-end requires read access
to both billing datasets from the same principal. As of writing, no human
account has that — the production version (RELOPS-2330) will run from service
accounts inside the bigquery-etl pipeline. Until then, this five-stage split is
the workaround.
