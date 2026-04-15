# Taskcluster Worker-Manager Logs

Query Taskcluster's worker-manager service logs from GCP Cloud Logging.

## Prerequisites

1. **gcloud CLI** authenticated (`gcloud auth login`)
2. **Access** to the `moz-fx-webservices-high-prod` GCP project (Logging Viewer role)
3. **jq** for JSON processing

## Architecture

Taskcluster runs as a Helm deployment in GKE:

| Property | Value |
|----------|-------|
| GCP project | `moz-fx-webservices-high-prod` |
| GKE cluster | `webservices-high-prod` |
| Region | `us-west1` |
| Namespace | `taskcluster-prod` |
| Deployment prefix | `taskcluster-v1-deploy-worker-manager-*` |

The secrets and database live in a separate project (`moz-fx-taskcluster-prod`),
but all application logs flow through the webservices GKE cluster.

## Source Code

Log types and fields are defined in the Taskcluster monorepo:

| File | What it defines |
|------|----------------|
| `services/worker-manager/src/monitor.js` | Worker-manager-specific log types and fields |
| `services/worker-manager/src/provisioner.js` | Provisioning loop (emits `simple-estimate`, `worker-pool-provisioned`) |
| `services/worker-manager/src/worker-scanner.js` | Scanner loop (emits `scan-seen`, `worker-running`, `worker-stopped`, etc.) |
| `libraries/monitor/src/logger.js` | Mozlog envelope structure and built-in types |
| `libraries/api/src/middleware/logging.js` | `monitor.apiMethod` type (shared across all services) |

Repo: https://github.com/taskcluster/taskcluster

## Worker-Manager Containers

The worker-manager deployment runs several containers, each handling a
different aspect of worker lifecycle management:

| Container | Role |
|-----------|------|
| `worker-manager-web` | API server handling worker registration, should-terminate, list workers |
| `worker-manager-provisioner` | Background loop that provisions new workers based on pending task demand |
| `worker-manager-workerscanner` | Scans registered workers and marks stale ones for removal |
| `worker-manager-workerscanner-azure` | Azure-specific worker scanner using Azure APIs to check VM state |

## Related GCP Projects

| Project ID | What lives there |
|------------|-----------------|
| `moz-fx-webservices-high-prod` | GKE cluster, application logs (this is where you query) |
| `moz-fx-taskcluster-prod` | CloudSQL database, Secret Manager secrets, audit logs |
| `moz-fx-taskcluster-prod-4b87` | Newer project for Taskcluster infrastructure (limited access) |

## Namespaces

There are two Taskcluster namespaces in the cluster:

| Namespace | Instance |
|-----------|----------|
| `taskcluster-prod` | Firefox CI (FXCI) production |
| `taskcluster-communitytc` | Community Taskcluster instance |

The skill defaults to `taskcluster-prod`. To query community TC, use a custom
`--filter` with the namespace override.
