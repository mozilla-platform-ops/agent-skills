# Auth split — which gcloud account reads which dataset

The reference query joins data across **two GCP projects with different IAM
ownership**. No single human principal currently has read access to both, so
the workflow uses two separate gcloud accounts and joins locally.

## The split

| Project | Dataset | Account | Why |
|---|---|---|---|
| `moz-fx-data-shared-prod` | `fxci_derived.task_runs_v1`, `fxci_derived.tasks_v2`, `fxci_derived.task_run_costs_v1`, `billing_syndicate.gcp_billing_export_resource_v1_*` | `<user>@mozilla.com` (Mozilla SSO) | Standard Mozilla data access, granted to most engineers |
| `moz-fx-data-billing-prod-9147` | `azure_billing_raw.fxci_daily_actual_load` | `<user>@firefox.gcp.mozilla.com` | Billing project; access via `workgroup:releasesre/admins` → `finops/viewers` → `roles/viewer`. Granted by Terraform (see [MZCLD-2783](https://mozilla-hub.atlassian.net/browse/MZCLD-2783)) |

The Mozilla SSO account has **no** access to `azure_billing_raw`. The
`@firefox.gcp` account has **no** access to `moz-fx-data-shared-prod`. This is
intentional separation — the billing project is owned by a different team.

## Switching accounts with gcloud

```bash
# Pre-check: confirm both accounts are in your credential set
gcloud auth list

# If one is missing, sign it in
gcloud auth login <user>@mozilla.com
gcloud auth login <user>@firefox.gcp.mozilla.com
```

`gcloud auth login` opens a browser. Both accounts must be authenticated **once**;
afterward they live in the gcloud credential store and you switch between them
with `gcloud config set account <email>`.

### Per-query account switch

```bash
# Stage 1 + 3 (mozdata)
gcloud config set account <user>@mozilla.com

# Stage 2 (Azure billing)
gcloud config set account <user>@firefox.gcp.mozilla.com
```

## Where the official documentation lives

- **`workgroup:releasesre/admins`** — yaml in
  [`mozilla/global-platform-admin/workgroups/releasesre.yaml`](https://github.com/mozilla-services/global-platform-admin/blob/main/workgroups/releasesre.yaml)
- **`finops/viewers` → `roles/viewer` on `moz-fx-data-billing-prod-9147`** —
  Terraform in
  [`mozilla/global-platform-admin/billingetl/tf/main.tf`](https://github.com/mozilla-services/global-platform-admin/blob/main/billingetl/tf/main.tf)
- **MZCLD-2783** is the umbrella ticket for the billing project access path

## When this auth split goes away

The split exists because billing IAM has not been granted to the bigquery-etl
CI dry-run service account or to the Airflow service account that runs
`bqetl_fxci`. Once that Terraform PR lands, the production version
(`fxci_derived.task_run_costs_v1` extended with Azure VMs, plus a new
`worker_costs_azure_v1`) will run end-to-end as a service account, and most
users won't need either of these accounts directly — they'll just query
`task_run_costs_v1` like they do today.

Tracking ticket: [RELOPS-2330](https://mozilla-hub.atlassian.net/browse/RELOPS-2330).

## Naming nit

The workgroup file is `releasesre.yaml`, not `relsre.yaml`. SREIN-1173 and
some older tickets use `relsre/` — the actual yaml is `releasesre/`. Cosmetic
but it makes repo searches confusing.
