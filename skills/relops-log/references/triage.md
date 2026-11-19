# Triage and Report

## Severity

Assign impact severity. Do not copy the log level.

| Severity | Criteria |
|----------|----------|
| **Critical** | Blocks CI or a whole pool now: workers cannot start, `master` Kitchen is red, auth or cert failure for a service, error rate rising across many hosts. |
| **High** | Degrades capacity or reliability: one pool or hardware class fails, reboot or crash loops, provisioning errors that cause a backlog, Kitchen fails for a reason that is not transient. |
| **Medium** | Real defect with low impact or a workaround: misconfiguration on some hosts, transient errors with no retry, log or monitoring defects. |
| **Low / Noise** | Expected or harmless. One line each, so the next sweep can filter them. |

## Steps for each signature

1. Scope: `host_count`, `top`, `first_seen`, `last_seen`. One host is usually
   lower than all hosts in a pool.
2. Active or burst: is `last_seen` near now?
3. Merge signatures that have the same cause (for example, a `worker_errors`
   signature that matches a Kitchen failure).
4. Kitchen: separate `pull_request` failures (the PR can be at fault) from
   `push` on `master` (fleet config is at fault). If an Azure or WinRM error
   is not in the workflow transient-error regex, the workflow does not retry
   it. That is a workflow bug.
5. Drill down when the cause is not clear:
   - `paperctl search "<text>" --since -24h`
   - `tc-logview query -e fx-ci --type <type> --where field=value`
   - `gh run view --job <id> --log-failed -R mozilla-platform-ops/ronin_puppet`

## Known signals

- `worker_errors` with `STOCKOUT` or `does not have enough resources`: GCP
  capacity. High only if the pool has a backlog; use **queue-diagnosis**.
- `websocktunnel` `could not find requested tunnel`: usually expected (the
  worker stopped before the client connected). Flag only if the trend rises.
- `github-worker` 404 on `.taskcluster.yml` or `collaborators`: usually repo
  configuration, not RelOps.
- Mislabeled EMERGENCY logs on Linux hardware and generic-worker: Medium
  (logging defect). It hides real alerts.

## Report format

One section per severity, highest first. For each item:

- **Title**: one line, what is broken.
- Source, count, scope (hosts or pools), first and last seen.
- One sample log or error line.
- Evidence: GitHub run or job URL, or the exact `paperctl` or `tc-logview` command.
- Next action and owner area (ronin_puppet, worker-images, fxci-config,
  Taskcluster, Azure, GCP).

End with a **Noise** list and a **Gaps** list (window errors, skipped
sources, sampling limits).
