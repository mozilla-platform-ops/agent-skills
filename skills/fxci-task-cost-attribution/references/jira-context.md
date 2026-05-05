# JIRA context — RELOPS-2330

This skill implements the reference query from
[RELOPS-2330: Enable cross-cloud (Azure + GCP) per-task cost attribution for
FXCI](https://mozilla-hub.atlassian.net/browse/RELOPS-2330).

## What the production version will look like

The intent of RELOPS-2330 is to extend the existing
`fxci_derived.task_run_costs_v1` table (currently GCP-only) to cover Azure
VMs as well. The shape of the work:

| Repo | Change |
|---|---|
| `mozilla/bigquery-etl` | New `sql/moz-fx-data-shared-prod/fxci_derived/worker_costs_azure_v1/` mirroring the existing `worker_costs_v1`, reading from `azure_billing_raw.*_load`, regex VM name out of `ResourceId`. |
| `mozilla/bigquery-etl` | Modify `sql/moz-fx-data-shared-prod/fxci_derived/task_run_costs_v1/query.sql` to UNION Azure cost into the `worker_cost` CTE and approximated Azure uptime into `worker_metric`. |
| `mozilla/global-platform-admin` | Terraform PR granting `roles/bigquery.dataViewer` on `moz-fx-data-billing-prod-9147:azure_billing_raw` to the bigquery-etl CI dry-run SA + the Airflow SA running `bqetl_fxci`. |

`mozilla/docker-etl` is not touched. The Airflow DAG (`bqetl_fxci`) is
auto-generated from the SQL.

## When this skill becomes obsolete

Once the bigquery-etl PR + Terraform PR land, `task_run_costs_v1` will cover
both clouds and most users will not need this skill — `SELECT * FROM
fxci_derived.task_run_costs_v1` will be the answer.

This skill stays useful for:

- **Validation work** before the production pipeline lands
- **Ad-hoc analysis** with the Azure-side methodology (e.g., experimenting
  with `>=` vs `>` filter, cross-tree uptime denominators)
- **Backfill / historical attribution** in windows the production pipeline
  has not yet processed

## Reading the ticket

The ticket is the source of truth for:

- The methodology decision (`MAX(resolved) - MIN(started)` uptime proxy and
  why it was chosen over building an Azure Monitor puller)
- The IAM split between `<user>@mozilla.com` and `<user>@firefox.gcp.mozilla.com`
- Validation results from 2026-05-05 (Azure regex match rate, cross-cloud
  join sanity)
- Pending work: which Terraform PR needs to land for end-to-end execution

## Related tickets

- [MZCLD-2783](https://mozilla-hub.atlassian.net/browse/MZCLD-2783) — Granted
  human access to `moz-fx-data-billing-prod-9147` via `finops/viewers`
- SREIN-1173 — Adjacent workgroup membership work; not blocking once
  MZCLD-2783 was completed

## Known related work

- `fxci-etl` architecture overview:
  <https://docs.mozilla-releng.net/en/latest/explanations/fxci-etl.html>
- Existing GCP pattern to mirror:
  `mozilla/bigquery-etl:sql/moz-fx-data-shared-prod/fxci_derived/worker_costs_v1/`
- Owner of `fxci-etl` and the bigquery-etl `fxci_derived` tables: Andrew
  Halberstadt (`ahalberstadt@mozilla.com`)
