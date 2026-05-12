# Taskcluster Worker-Manager Logs

Use `tc-logview` to query Taskcluster's worker-manager service logs. The tool
wraps GCP Cloud Logging with Taskcluster environment config, typed log
definitions, field shorthands, JSONL output, and cached result paging.

## Install And Setup

```bash
go install github.com/taskcluster/tc-logview@latest
tc-logview config init
# Put the GCP service-account key at the key_path in the generated config.
tc-logview sync -e fx-ci
```

The working local config used in prior investigations was:

```yaml
environments:
  fx-ci:
    project_id: "moz-fx-webservices-high-prod"
    cluster: "webservices-high-prod"
    root_url: "https://firefox-ci-tc.services.mozilla.com"
    cloudsql_instance: "taskcluster-prod-20260409-1"
    key_path: "~/.config/gcloud/application_default_credentials.json"
  community-tc:
    project_id: "moz-fx-webservices-high-prod"
    cluster: "webservices-high-prod"
    root_url: "https://community-tc.services.mozilla.com"
    cloudsql_instance: "taskcluster-community-20260317-1"
    key_path: "~/.config/gcloud/application_default_credentials.json"
```

Pass `-e fx-ci` explicitly in examples. Relying on
`TASKCLUSTER_ROOT_URL` auto-detection has failed when the URL contained a
trailing slash.

## Architecture

Taskcluster runs as a Helm deployment in GKE:

| Property | Value |
|----------|-------|
| GCP project in tc-logview config | `moz-fx-webservices-high-prod` |
| GKE cluster | `webservices-high-prod` |
| Region | `us-west1` |
| Firefox CI namespace | `taskcluster-prod` |
| Community TC namespace | `taskcluster-communitytc` |
| Deployment prefix | `taskcluster-v1-deploy-worker-manager-*` |

The secrets and database live in Taskcluster-specific projects, but the service
logs are queried through the webservices GKE environment configured above.

## Source Code

Log types and fields are defined in the Taskcluster monorepo:

| File | What it defines |
|------|-----------------|
| `services/worker-manager/src/monitor.js` | Worker-manager-specific log types and fields |
| `services/worker-manager/src/provisioner.js` | Provisioning loop (`simple-estimate`, `worker-pool-provisioned`) |
| `services/worker-manager/src/worker-scanner.js` | Scanner loop (`scan-seen`, `worker-running`, `worker-stopped`, etc.) |
| `libraries/monitor/src/logger.js` | Mozlog envelope structure and built-in monitor types |
| `libraries/api/src/middleware/logging.js` | `monitor.apiMethod` type shared across services |

Repo: https://github.com/taskcluster/taskcluster

## Worker-Manager Containers

The worker-manager deployment runs several containers, each handling a
different aspect of worker lifecycle management:

| Container | Role |
|-----------|------|
| `worker-manager-web` | API server handling worker registration, should-terminate, list workers |
| `worker-manager-provisioner` | Background loop that provisions new workers from pending task demand |
| `worker-manager-workerscanner` | Scans registered workers and marks stale workers for removal |
| `worker-manager-workerscanner-azure` | Azure-specific scanner using Azure APIs to check VM state |

Use service and type filters instead of container-name filters whenever
possible:

```bash
tc-logview list --service worker-manager
tc-logview query -e fx-ci --type scan-seen --since 30m --json
tc-logview query -e fx-ci --type monitor.apiMethod --service worker-manager --since 1h --json
```

## Log Routing Context

Historical direct Cloud Logging investigations had to account for GKE log
routing and sink buckets. This skill should not expose that as the normal query
path. Let `tc-logview` handle the environment and log filters.

Useful routing facts when checking config or permissions:

| Component | Location |
|-----------|----------|
| GKE cluster | `moz-fx-webservices-high-prod` |
| Firefox CI namespace | `taskcluster-prod` |
| Community TC namespace | `taskcluster-communitytc` |
| Older app-log sink destination | `moz-fx-taskcluster-prod`, bucket `gke-taskcluster-prod-log-bucket` |
| Sink name | `gke-taskcluster-prod-sink` |
| Sink filter | `resource.labels.namespace_name="taskcluster-prod"` |

If `tc-logview` cannot return logs, first check `~/.config/tc-logview/config.yaml`,
the `key_path`, and whether `tc-logview sync -e fx-ci` has populated the
worker-manager references.

## Environments

| Environment | Root URL | Namespace |
|-------------|----------|-----------|
| `fx-ci` | `https://firefox-ci-tc.services.mozilla.com` | `taskcluster-prod` |
| `community-tc` | `https://community-tc.services.mozilla.com` | `taskcluster-communitytc` |

Use `-e community-tc` only when explicitly investigating Community
Taskcluster. Firefox CI worker image and worker pool work should use `-e fx-ci`.
