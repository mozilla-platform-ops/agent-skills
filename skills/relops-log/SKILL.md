---
name: relops-log
description: >
  Use when asked for a RelOps log sweep, daily health check, or what broke in
  the last 24 hours. Searches Taskcluster service logs (tc-logview), worker
  guest logs (paperctl), and ronin_puppet Kitchen CI status checks (gh), then
  groups findings by impact severity. DO NOT USE FOR one worker, task, or
  pool; use the specific skill.
---

# RelOps Log Sweep

Use `tc-logview`, `paperctl`, and `gh` directly. The installed tools are the
source of truth for flags and fields. Run `<tool> --help` before you build a query.
Default window: last 24h. Search every location below unless the user limits scope.

## Locations

**Taskcluster services** (`tc-logview`). Environments: `fx-ci` (namespace
`taskcluster-prod`), `community-tc` (namespace `taskcluster-communitytc`).

```bash
tc-logview query -e fx-ci --from <start> --to <end> --raw --limit 5000 \
  --filter 'resource.labels.namespace_name="taskcluster-prod" AND jsonPayload.Severity<=3'
tc-logview query -e fx-ci --since 24h --type worker-error --json --limit 20000
```

**Worker guest logs** (`paperctl`). Add `--system <host>` to search one location.

```bash
paperctl search "severity:ERROR OR severity:CRITICAL OR severity:ALERT" \
  --since <start> --until <end> --limit 2000 --output json
paperctl search 'severity:EMERGENCY AND (error OR fail OR fatal OR panic OR denied OR timeout)' \
  --since <start> --until <end> --limit 1000 --output json
```

**CI status checks** (`gh`) for `mozilla-platform-ops/ronin_puppet`. Use
`gh workflow list` to find workflows. Default: `Kitchen Windows`.

```bash
gh run list -R mozilla-platform-ops/ronin_puppet --workflow "Kitchen Windows" \
  --created ">=<start>" --json databaseId,conclusion,event,headBranch,url,displayTitle
gh run view <run-id> -R mozilla-platform-ops/ronin_puppet --json jobs
gh run view -R mozilla-platform-ops/ronin_puppet --job <job-id> --log-failed
```

In failed job logs, the cause is on `>>>>>>` and `##[error]` lines.

## Triage

Group entries by source, service or program, and message. Remove IDs, hosts,
and numbers before you group. Then assign impact severity, not log level:

| Severity | Criteria |
|----------|----------|
| **Critical** | Blocks CI or a whole pool: workers cannot start, Kitchen fails on `master`, auth or cert failure. |
| **High** | One pool or hardware class degraded, crash or reboot loops, Kitchen fails for a non-transient reason. |
| **Medium** | Defect with low impact: misconfiguration on some hosts, errors that are not retried, logging defects. |
| **Noise** | Expected or harmless. One line each. |

For each item, give: title, source, count, scope (hosts or pools), first and
last seen, one sample line, an evidence link or exact command, and the next
action. End with a **Gaps** list (failed queries, skipped windows, sampling).

## Gotchas

- Query tc-logview and paperctl in 1h `--from/--to` or `--since/--until`
  windows. One 24h tc-logview query takes minutes and stops at `--limit`.
- tc-logview `--json` drops the message for `--filter` queries. Use `--raw`
  and read `jsonPayload.Fields.message`, `msg`, or `error`.
- GCP `severity>=ERROR` is useless: GKE marks all stderr as Error. Use
  `jsonPayload.Severity<=3` (mozlog levels).
- Papertrail error volume is approximately 100k+/hour, so results are samples.
  Confirm a signature with a targeted `paperctl search "<text>"`.
- `paperctl --output json` prints `Total events:` before the JSON. Use
  `-F <file>` to get clean JSON.
- `generic-worker`, `run-start-worker`, `run-puppet.sh`, and `sudo` log most
  lines as EMERGENCY. Filter EMERGENCY by text.
- Kitchen: a `pull_request` failure can be the PR's fault. A failure on
  `master` is a fleet problem. An Azure or WinRM error that is not in the
  workflow transient-error regex is not retried; that is a workflow bug.
- `worker-error` `STOCKOUT` is GCP capacity. Use **queue-diagnosis** to check
  for a backlog before you flag it.

## Related Skills

**taskcluster-worker-lifecycle-logs**, **queue-diagnosis**, **production-image-deploy**.
