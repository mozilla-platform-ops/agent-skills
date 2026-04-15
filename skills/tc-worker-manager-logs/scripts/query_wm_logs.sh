#!/usr/bin/env bash
# Query GCP Cloud Logging for Taskcluster worker-manager logs.
#
# Requires: gcloud CLI authenticated, jq
#
# Usage:
#   query_wm_logs.sh [options]
#   query_wm_logs.sh --errors
#   query_wm_logs.sh --pool gecko-t/win11-64-24h2
#   query_wm_logs.sh --container workerscanner-azure --freshness 2h
#   query_wm_logs.sh --provisioning --pool gecko-t/win11-64-24h2

set -euo pipefail

PROJECT="moz-fx-webservices-high-prod"
NAMESPACE="taskcluster-prod"
LIMIT=100
FRESHNESS="1h"
CONTAINER=""
POOL=""
WORKER_ID=""
ERRORS=false
PROVISIONING=false
API=false
EXTRA_FILTER=""
OUTPUT=""
VERBOSE=false
SUMMARY=false
RAW_JSON=false

usage() {
  cat <<'EOF'
Query Taskcluster worker-manager logs from GCP Cloud Logging.

FILTERS:
  --container, -c   Container: web, workerscanner-azure, provisioner,
                    workerscanner, all (default: all)
  --pool, -p        Filter by worker pool ID (e.g., gecko-t/win11-64-24h2)
  --worker-id, -w   Filter by worker ID
  --errors, -e      Only show WARNING severity and above
  --provisioning    Show provisioning-related entries
  --api             Show API method calls only
  --filter, -f      Additional Cloud Logging filter expression

QUERY OPTIONS:
  --limit, -n       Max entries to return (default: 100)
  --freshness       How far back to search (default: 1h)
  --project         GCP project (default: moz-fx-webservices-high-prod)

OUTPUT:
  --verbose, -v     Show full JSON fields per entry
  --summary, -s     Print counts by container, severity, and log type
  --json            Output raw JSON
  --output, -o      Save raw JSON to file

EXAMPLES:
  query_wm_logs.sh --errors
  query_wm_logs.sh --pool gecko-t/win11-64-24h2
  query_wm_logs.sh --provisioning --pool gecko-t/win11-64-24h2
  query_wm_logs.sh --api --limit 50
  query_wm_logs.sh --container workerscanner-azure --freshness 30m
  query_wm_logs.sh --worker-id 3810952543839873557
  query_wm_logs.sh --errors --output ~/moz_artifacts/wm-errors.json
EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --container|-c) CONTAINER="$2"; shift 2 ;;
    --pool|-p)      POOL="$2"; shift 2 ;;
    --worker-id|-w) WORKER_ID="$2"; shift 2 ;;
    --errors|-e)    ERRORS=true; shift ;;
    --provisioning) PROVISIONING=true; shift ;;
    --api)          API=true; shift ;;
    --filter|-f)    EXTRA_FILTER="$2"; shift 2 ;;
    --limit|-n)     LIMIT="$2"; shift 2 ;;
    --freshness)    FRESHNESS="$2"; shift 2 ;;
    --project)      PROJECT="$2"; shift 2 ;;
    --verbose|-v)   VERBOSE=true; shift ;;
    --summary|-s)   SUMMARY=true; shift ;;
    --json)         RAW_JSON=true; shift ;;
    --output|-o)    OUTPUT="$2"; shift 2 ;;
    --help|-h)      usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

# Build the Cloud Logging filter
FILTER='resource.type="k8s_container"'
FILTER+=" AND resource.labels.namespace_name=\"${NAMESPACE}\""

case "${CONTAINER}" in
  web)                  FILTER+=' AND resource.labels.container_name="worker-manager-web"' ;;
  workerscanner-azure)  FILTER+=' AND resource.labels.container_name="worker-manager-workerscanner-azure"' ;;
  provisioner)          FILTER+=' AND resource.labels.container_name="worker-manager-provisioner"' ;;
  workerscanner)        FILTER+=' AND resource.labels.container_name="worker-manager-workerscanner"' ;;
  all|"")               FILTER+=' AND resource.labels.container_name=~"worker-manager"' ;;
  *)                    FILTER+=" AND resource.labels.container_name=\"${CONTAINER}\"" ;;
esac

if $ERRORS; then
  FILTER+=' AND severity>=WARNING'
fi

if [[ -n "$POOL" ]]; then
  FILTER+=" AND (jsonPayload.Fields.workerPoolId=\"${POOL}\""
  FILTER+=" OR jsonPayload.Fields.workerPool=\"${POOL}\""
  FILTER+=" OR textPayload=~\"${POOL}\")"
fi

if $PROVISIONING; then
  FILTER+=' AND (jsonPayload.Type="simple-estimate"'
  FILTER+=' OR jsonPayload.Type="worker-pool-provisioned"'
  FILTER+=' OR jsonPayload.Type="worker-requested"'
  FILTER+=' OR jsonPayload.Type="worker-running"'
  FILTER+=' OR jsonPayload.Fields.name="registerWorker"'
  FILTER+=' OR jsonPayload.Fields.name="createWorker")'
fi

if [[ -n "$WORKER_ID" ]]; then
  FILTER+=" AND (jsonPayload.Fields.workerId=\"${WORKER_ID}\""
  FILTER+=" OR textPayload=~\"${WORKER_ID}\")"
fi

if $API; then
  FILTER+=' AND jsonPayload.Type="monitor.apiMethod"'
fi

if [[ -n "$EXTRA_FILTER" ]]; then
  FILTER+=" AND ${EXTRA_FILTER}"
fi

echo "Filter: ${FILTER}" >&2
echo "Querying ${PROJECT} (limit=${LIMIT}, freshness=${FRESHNESS})..." >&2

# Run the query
RESULT=$(gcloud logging read "${FILTER}" \
  --project="${PROJECT}" \
  --limit="${LIMIT}" \
  --format=json \
  "--freshness=${FRESHNESS}")

COUNT=$(echo "${RESULT}" | jq 'length')

if [[ "$COUNT" -eq 0 ]]; then
  echo "No log entries found." >&2
  exit 0
fi

echo "Found ${COUNT} entries." >&2

# Save raw JSON if requested
if [[ -n "$OUTPUT" ]]; then
  mkdir -p "$(dirname "${OUTPUT}")"
  echo "${RESULT}" > "${OUTPUT}"
  echo "Saved to ${OUTPUT}" >&2
fi

# Output
if $RAW_JSON; then
  echo "${RESULT}" | jq .
elif $VERBOSE; then
  # Reverse for chronological order, show full fields
  echo "${RESULT}" | jq -r '
    reverse[] |
    .timestamp[:23] as $ts |
    .severity as $sev |
    (.resource.labels.container_name // "?" |
      gsub("worker-manager-"; "wm-")) as $ctr |
    .jsonPayload as $jp |
    if $jp then
      ($jp.Logger // "") as $logger |
      ($jp.Type // "") as $type |
      ($jp.Fields // {}) as $fields |
      "\($ts)  \($sev)\t\($ctr)\t\($logger)\n  Type: \($type)\n  Fields: \($fields | tojson)\n"
    else
      "\($ts)  \($sev)\t\($ctr)\t\(.textPayload // "(no payload)" | .[:150])\n"
    end'
else
  # Reverse for chronological order, compact format
  echo "${RESULT}" | jq -r '
    reverse[] |
    .timestamp[:23] as $ts |
    .severity as $sev |
    (.resource.labels.container_name // "?" |
      gsub("worker-manager-"; "wm-")) as $ctr |
    .jsonPayload as $jp |
    if $jp then
      ($jp.Type // "") as $type |
      ($jp.Fields // {}) as $f |
      [
        $type,
        ($f.name // empty),
        (if $f.workerPoolId then "pool=\($f.workerPoolId)" else empty end),
        (if $f.workerId then "worker=\($f.workerId)" else empty end),
        (if $f.statusCode then "status=\($f.statusCode)" else empty end),
        (if $f.duration then "\($f.duration)ms" else empty end),
        (if $f.error then ($f.error | tostring)[:120] else empty end),
        (if $f.message then ($f.message | tostring)[:120] else empty end)
      ] | join(" | ") | . as $summary |
      "\($ts)  \($sev | . + " " * (8 - length))  \($ctr | . + " " * ([25 - length, 0] | max))  \($summary)"
    else
      "\($ts)  \($sev | . + " " * (8 - length))  \($ctr | . + " " * ([25 - length, 0] | max))  \(.textPayload // "(no payload)" | .[:150])"
    end'
fi

# Summary
if $SUMMARY; then
  echo "" >&2
  echo "--- Summary (${COUNT} entries) ---" >&2

  echo "" >&2
  echo "By container:" >&2
  echo "${RESULT}" | jq -r '
    group_by(.resource.labels.container_name) |
    map({key: .[0].resource.labels.container_name, value: length}) |
    sort_by(-.value)[] |
    "  \(.key)\t\(.value)"' >&2

  echo "" >&2
  echo "By severity:" >&2
  echo "${RESULT}" | jq -r '
    group_by(.severity) |
    map({key: .[0].severity, value: length}) |
    sort_by(-.value)[] |
    "  \(.key)\t\(.value)"' >&2

  echo "" >&2
  echo "By log type:" >&2
  echo "${RESULT}" | jq -r '
    group_by(.jsonPayload.Type // "unknown") |
    map({key: .[0].jsonPayload.Type // "unknown", value: length}) |
    sort_by(-.value)[:15][] |
    "  \(.key)\t\(.value)"' >&2
fi
