# Worker-Manager Log Schema

Worker-manager logs use structured JSON payloads following the mozlog format,
emitted by `taskcluster-lib-monitor` (`libraries/monitor/` in the Taskcluster
monorepo: https://github.com/taskcluster/taskcluster). Query them with
`tc-logview`, which maps these payload fields into typed JSONL records.

## Raw Cloud Logging Entry Structure

Use `tc-logview query ... --raw` when you need the full GCP log entry. Raw
entries have this shape:

```json
{
  "timestamp": "2026-04-15T18:13:47.191Z",
  "severity": "NOTICE",
  "resource": {
    "type": "k8s_container",
    "labels": {
      "cluster_name": "webservices-high-prod",
      "container_name": "worker-manager-web",
      "namespace_name": "taskcluster-prod",
      "pod_name": "taskcluster-v1-deploy-worker-manager-web-768cdbffb-df597"
    }
  },
  "jsonPayload": {
    "Logger": "taskcluster.worker-manager.api",
    "Type": "monitor.apiMethod",
    "Severity": 5,
    "Hostname": "taskcluster-v1-deploy-worker-manager-web-768cdbffb-df597",
    "Pid": 1,
    "EnvVersion": "2.0",
    "serviceContext": {
      "service": "worker-manager",
      "version": "99.0.3"
    },
    "requestId": "d5742f6c-4bc4-4274-bcb4-86f993129380",
    "traceId": "ac06a425127dbaac8563a5d0e6c1e769",
    "Fields": {
      "name": "shouldWorkerTerminate",
      "apiVersion": "v1",
      "method": "GET",
      "statusCode": 200,
      "duration": 5.48,
      "clientId": "worker/fxci-level1-gcp/gecko-t/t-linux-docker-amd/...",
      "resource": "/workers/gecko-t%2Ft-linux-docker-amd/.../should-terminate",
      "sourceIp": "34.59.157.49",
      "authenticated": true,
      "public": false,
      "satisfyingScopes": ["worker-manager:should-worker-terminate:..."]
    }
  }
}
```

## tc-logview Output Modes

`tc-logview` has three output modes that matter in investigations:

| Mode | Use |
|------|-----|
| default text | Quick inspection in the terminal |
| `--json` | Flattened JSONL records for `jq`, `awk`, or scripts |
| `--raw` | Full GCP Cloud Logging entries with `jsonPayload.Fields` |

Example `--json` output is flattened by log type:

```json
{"Service":"worker-manager","description":"The zone ... does not have enough resources available","errorId":"r8rNrm6JQC-4Wm0hmIc8MQ","kind":"operation-error","title":"Operation Error","ts":"2026-05-12T17:44:00Z","workerPoolId":"mozillavpn-1/b-linux-large"}
```

Use the flattened field names in `jq` pipelines:

```bash
tc-logview query -e fx-ci --type worker-removed \
  --where 'workerPoolId=gecko-t/win11-64-25h2' \
  --from 2026-04-20T00:00:00Z --to 2026-04-22T00:00:00Z \
  --limit 5000 --json \
  | jq -r '[.ts, .workerPoolId, .workerId, .reason, .workerAge] | @tsv'
```

## Key jsonPayload Fields

| Field | Description |
|-------|-------------|
| `Logger` | Dot-separated logger name (see Logger Values below) |
| `Type` | Log event type (see Log Types below) |
| `Severity` | Mozlog severity: 0=emergency ... 7=debug |
| `EnvVersion` | Mozlog envelope version (`"2.0"`) |
| `Hostname` | Pod hostname |
| `Pid` | Process ID |
| `serviceContext` | `{ service, version }` for Stackdriver |
| `Fields` | Event-specific payload (varies by Type) |
| `requestId` | Unique request ID for API calls |
| `traceId` | Distributed trace ID |

## Logger Values

Constructed as `taskcluster.<service>.<child>` in `libraries/monitor/src/monitor.js`.

| Logger | Source |
|--------|--------|
| `taskcluster.worker-manager` | Root monitor |
| `taskcluster.worker-manager.api` | API request handler |
| `taskcluster.worker-manager.provisioner` | Provisioner loop |
| `taskcluster.worker-manager.worker-scanner` | Worker scanner |
| `taskcluster.worker-manager.estimator` | Capacity estimator |
| `taskcluster.worker-manager.db` | Database layer |
| `taskcluster.worker-manager.pulse-client` | Pulse message consumer |

## Log Types

### API Types

#### `monitor.apiMethod` (web container)

Registered in `libraries/api/src/middleware/logging.js`. Emitted after each API
response.

| Field | Type | Description |
|-------|------|-------------|
| `name` | string | API method name (e.g., `shouldWorkerTerminate`) |
| `apiVersion` | string | API version (e.g., `v1`) |
| `method` | string | HTTP verb |
| `resource` | string | Request path |
| `statusCode` | number | HTTP response status |
| `duration` | number | Execution time in **milliseconds** |
| `clientId` | string | TC client ID (empty if unauthenticated) |
| `expires` | string | Credential expiry |
| `sourceIp` | string | Caller IP |
| `authenticated` | boolean | Whether request was authenticated |
| `public` | boolean | Whether endpoint is public |
| `query` | object | Query parameters |
| `satisfyingScopes` | array | Scopes that authorized the request |

### Provisioner Types

Defined in `services/worker-manager/src/monitor.js`, emitted by
`services/worker-manager/src/provisioner.js`.

#### `simple-estimate`

Capacity estimation decision for a worker pool.

| Field | Type | Description |
|-------|------|-------------|
| `workerPoolId` | string | Worker pool ID |
| `pendingTasks` | number | Pending tasks driving demand |
| `minCapacity` | number | Pool minimum capacity |
| `maxCapacity` | number | Pool maximum capacity |
| `scalingRatio` | number | Scaling ratio applied |
| `existingCapacity` | number | Current active capacity |
| `desiredCapacity` | number | Calculated desired capacity |
| `requestedCapacity` | number | Capacity actually requested |
| `stoppingCapacity` | number | Capacity currently stopping |

#### `worker-pool-provisioned`

Emitted after provisioning completes for a pool.

| Field | Type | Description |
|-------|------|-------------|
| `workerPoolId` | string | Worker pool ID |
| `providerId` | string | Cloud provider (e.g., `azure2`, `google2`) |
| `duration` | number | Duration in **nanoseconds** |

#### `worker-requested`

Emitted when a new worker VM is requested.

| Field | Type | Description |
|-------|------|-------------|
| `workerPoolId` | string | Worker pool ID |
| `providerId` | string | Cloud provider |
| `workerGroup` | string | Worker group |
| `workerId` | string | Worker ID |
| `terminateAfter` | string | Scheduled termination time |

### Worker Scanner Types

Defined in `services/worker-manager/src/monitor.js`, emitted by
`services/worker-manager/src/worker-scanner.js`.

#### `scan-seen`

Summary after scanning a provider's workers.

| Field | Type | Description |
|-------|------|-------------|
| `providerId` | string | Cloud provider |
| `seen` | number | Workers seen this scan |
| `total` | number | Total workers for provider |

#### `worker-running`

Worker transitioned to running state.

| Field | Type | Description |
|-------|------|-------------|
| `workerPoolId` | string | Worker pool ID |
| `providerId` | string | Cloud provider |
| `workerId` | string | Worker ID |
| `registrationDuration` | number | Time from request to running |

#### `worker-stopped`

Worker stopped.

| Field | Type | Description |
|-------|------|-------------|
| `workerPoolId` | string | Worker pool ID |
| `providerId` | string | Cloud provider |
| `workerId` | string | Worker ID |
| `workerAge` | number | Total worker lifetime |
| `runningDuration` | number | Time spent running |

#### `worker-removed`

Worker removed from the pool.

| Field | Type | Description |
|-------|------|-------------|
| `workerPoolId` | string | Worker pool ID |
| `providerId` | string | Cloud provider |
| `workerId` | string | Worker ID |
| `reason` | string | Removal reason |
| `workerAge` | number | Total worker lifetime |
| `runningDuration` | number | Time spent running |

#### `worker-error`

Error associated with a worker.

| Field | Type | Description |
|-------|------|-------------|
| `workerPoolId` | string | Worker pool ID |
| `errorId` | string | Error identifier |
| `kind` | string | Error kind |
| `title` | string | Error title |
| `description` | string | Error description |

### Azure-Specific Types

| Type | Description |
|------|-------------|
| `cloud-api-paused` | Azure API calls paused (rate limiting) |
| `cloud-api-resumed` | Azure API calls resumed |
| `cloud-api-metrics` | Azure API call metrics |
| `azure-resource-group-ensure` | Resource group creation/verification |
| `azure-instance-view-repeated-404` | Repeated 404s checking Azure VM state |

### Other Types

| Type | Description |
|------|-------------|
| `registration-error-warning` | Worker registration error |
| `registration-new-intermediate-certificate` | New intermediate cert detected |
| `launch-config-selector-debug` | Launch config selection debug info |

### Built-in Monitor Types

These are from `taskcluster-lib-monitor` and appear across all services:

| Type | Description |
|------|-------------|
| `monitor.generic` | Default when no specific type is registered |
| `monitor.error` | From `reportError()`; includes `name`, `message`, `stack` |
| `monitor.periodic` | Timed loop iteration |
| `monitor.timer` | Timed operation (includes DB call timing) |

## Common API Method Names

| Method | Description |
|--------|-------------|
| `shouldWorkerTerminate` | Worker polls to check if it should shut down |
| `registerWorker` | Worker registers itself after VM boot |
| `createWorker` | Provisioner creates a new worker record |
| `listWorkers` | List workers in a pool |
| `getWorker` | Get a single worker's details |
| `removeWorker` | Mark a worker for removal |
| `workerPool` | Get worker pool configuration |
| `listWorkerPools` | List all worker pools |

## Severity Levels

| Mozlog | Cloud Logging | Meaning |
|--------|---------------|---------|
| 0 | EMERGENCY | System unusable |
| 1 | ALERT | Immediate action needed |
| 2 | CRITICAL | Critical failure |
| 3 | ERROR | Error condition |
| 4 | WARNING | Warning condition |
| 5 | NOTICE | Normal but significant (API calls) |
| 6 | INFO | Informational (DB calls) |
| 7 | DEBUG | Debug details |

## Useful tc-logview Patterns

```bash
# Discover current worker-manager types and typed fields
tc-logview list --service worker-manager

# Pool lifecycle over a cacheable fixed window
tc-logview query -e fx-ci --type worker-removed \
  --where 'workerPoolId=gecko-t/win11-64-25h2' \
  --from 2026-04-20T00:00:00Z --to 2026-04-22T00:00:00Z \
  --limit 5000 --json > /tmp/worker-removed.jsonl

# Provisioning estimates for a pool
tc-logview query -e fx-ci --type simple-estimate \
  --where 'workerPoolId=gecko-t/win11-64-25h2' --since 6h --json

# Requested/running/stopped lifecycle correlation
for type in worker-requested worker-running worker-stopped worker-removed; do
  tc-logview query -e fx-ci --type "$type" \
    --where 'workerPoolId=gecko-t/win11-64-25h2' --since 6h --json
done

# Registration failures
tc-logview query -e fx-ci --type registration-error-warning --since 6h --json

# API errors (non-2xx responses)
tc-logview query -e fx-ci --type monitor.apiMethod \
  --service worker-manager --since 2h --limit 1000 --json \
  | jq 'select(.statusCode >= 400)'

# Slow API calls (>1 second)
tc-logview query -e fx-ci --type monitor.apiMethod \
  --service worker-manager --since 2h --limit 1000 --json \
  | jq 'select(.duration > 1000)'

# Azure scanner/provider health
tc-logview query -e fx-ci --type scan-seen --since 30m --json --limit 500 \
  | jq 'select(.providerId | test("azure"; "i"))'

# Azure rate limiting and API pressure
tc-logview query -e fx-ci --type azure-throttled --since 2h --json
tc-logview query -e fx-ci --type cloud-api-paused --since 2h --json
tc-logview query -e fx-ci --type cloud-api-metrics --since 2h --json

# OperationPreempted/capacity errors by payload text
tc-logview query -e fx-ci --service worker-manager --since 2h \
  --filter '"win11-64-25h2-gpu" AND "OperationPreempted"' --json

# Trace one VM end-to-end across worker-manager logs
tc-logview query -e fx-ci --service worker-manager --since 12h \
  --filter '"vm-xpqdntos6kvslwuihwwhwa4ohyj87t6wjrr"' --raw
```
