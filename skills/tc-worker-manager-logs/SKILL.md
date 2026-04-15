---
name: tc-worker-manager-logs
description: >
  Query Taskcluster worker-manager logs from GCP Cloud Logging. Use when
  investigating worker provisioning failures, registration errors, API errors,
  worker scanner issues, or debugging worker lifecycle problems. Covers all
  worker-manager containers (web API, provisioner, Azure scanner, worker
  scanner). Triggers on "worker-manager logs", "worker-manager errors",
  "provisioning logs", "worker registration", "worker scanner", "GCP logs
  taskcluster", "why aren't workers starting", "worker-manager API errors".
---

# Taskcluster Worker-Manager Logs

Query Taskcluster worker-manager service logs from GCP Cloud Logging in the
`moz-fx-webservices-high-prod` project.

## Knowledge References
@references/README.md
@references/log-schema.md

## Prerequisites

- `gcloud` CLI authenticated with access to `moz-fx-webservices-high-prod`
- `jq` for JSON processing

## Quick Start

```bash
# Recent errors across all worker-manager containers
scripts/query_wm_logs.sh --errors

# Logs for a specific worker pool
scripts/query_wm_logs.sh --pool gecko-t/win11-64-24h2

# Provisioning activity for a pool
scripts/query_wm_logs.sh --provisioning --pool gecko-t/win11-64-24h2

# Azure worker scanner activity
scripts/query_wm_logs.sh --container workerscanner-azure --freshness 30m

# API calls with verbose output
scripts/query_wm_logs.sh --api --verbose --limit 50

# Save raw JSON for further analysis
scripts/query_wm_logs.sh --errors --freshness 6h --output ~/moz_artifacts/wm-errors.json
```

## Usage

### query_wm_logs.sh

Queries GCP Cloud Logging for worker-manager container logs in the
`taskcluster-prod` namespace.

#### Filters

| Flag | Description |
|------|-------------|
| `--container`, `-c` | Container: `web`, `provisioner`, `workerscanner`, `workerscanner-azure`, `all` (default: `all`) |
| `--pool`, `-p` | Filter by worker pool ID (e.g., `gecko-t/win11-64-24h2`) |
| `--worker-id`, `-w` | Filter by worker ID |
| `--errors`, `-e` | Only show WARNING severity and above |
| `--provisioning` | Show provisioning-related entries |
| `--api` | Show API method calls only |
| `--filter`, `-f` | Additional Cloud Logging filter expression |

#### Query Options

| Flag | Description |
|------|-------------|
| `--limit`, `-n` | Max entries to return (default: 100) |
| `--freshness` | How far back to search (default: `1h`) |
| `--project` | Override GCP project (default: `moz-fx-webservices-high-prod`) |

#### Output Options

| Flag | Description |
|------|-------------|
| `--verbose`, `-v` | Show full field details per entry |
| `--summary`, `-s` | Print counts by container, severity, and log type |
| `--json` | Output raw JSON |
| `--output`, `-o` | Save raw JSON to file |

## Example Prompts

| Prompt | Action |
|--------|--------|
| "Are there worker-manager errors?" | `--errors --freshness 1h` |
| "Why aren't workers starting for win11-64-24h2?" | `--provisioning --pool gecko-t/win11-64-24h2 --freshness 2h` |
| "Show me worker registration failures" | `--api --filter 'jsonPayload.Fields.name="registerWorker" AND jsonPayload.Fields.statusCode>=400'` |
| "What's the Azure scanner doing?" | `--container workerscanner-azure --freshness 30m --summary` |
| "Show API traffic to worker-manager" | `--api --summary --limit 200` |
| "Track worker 3810952543839873557" | `--worker-id 3810952543839873557 --freshness 6h` |
| "Are there slow worker-manager API calls?" | `--api --filter 'jsonPayload.Fields.duration>1000' --verbose` |
| "Show me what's happening with worker-manager right now" | (no filters, defaults to last hour, 100 entries) |
| "Get verbose provisioning logs for the last 4 hours" | `--provisioning --freshness 4h --verbose` |
| "Save today's worker-manager errors for analysis" | `--errors --freshness 24h --output ~/moz_artifacts/wm-errors.json` |

## Workflow: Debugging Worker Pool Issues

1. **Check for errors** -- `--errors --pool <pool> --freshness 2h`
2. **Check provisioning** -- `--provisioning --pool <pool>` to see if workers are being requested
3. **Check registrations** -- `--api --pool <pool>` to see if workers are registering
4. **Check scanner** -- `--container workerscanner-azure --pool <pool>` to see if workers are being scanned/removed
5. **Get summary** -- add `--summary` to any query for aggregate counts
6. **Save for analysis** -- `--output ~/moz_artifacts/<pool>-logs.json` for deeper investigation

## Log Schema Reference
@references/log-schema.md
