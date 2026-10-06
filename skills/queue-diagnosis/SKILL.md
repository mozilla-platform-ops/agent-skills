---
name: queue-diagnosis
description: >
  Use when a Taskcluster worker pool queue is backed up: high pending counts,
  long queue times, or deadline expirations. Combines pool health from the
  Taskcluster CLI with BigQuery demand data to separate supply-side from
  demand-side causes.
---

# Queue Diagnosis

## Prerequisites

`taskcluster` CLI (FXCI root URL), `REDASH_API_KEY` with the redash skill,
and `uv`. Optional: `az` on FXCI subscription
`108d46d5-fe9b-4850-9a7d-8c914aa6c1f0` for the Azure ghost check. Read
[references/setup.md](references/setup.md) when authentication fails.

## Usage

Pass `provisioner/worker-type`. Cloud and `releng-hardware` pools both work.

```bash
uv run ~/.claude/skills/queue-diagnosis/scripts/diagnose.py gecko-t/win11-64-25h2
```

Start with `diagnosis.verdict`: `supply-side`, `demand-side`, `mixed`,
`recently-impacted`, `no-active-backlog`, `inconclusive-active-backlog`, or
`auth-blocked`. It is a heuristic; verify it against the raw sections.

Read [references/report-fields.md](references/report-fields.md) to interpret
signals and before you write the summary. Read
[references/queries.md](references/queries.md) when the script fails or you
need manual SQL.

## Troubleshooting / Gotchas

- `pool_status.auth_failure: true`: tell the user to run `taskcluster signin`
  and stop. Make no supply-side claims.
- Hardware pools set `managed: false` (no worker-manager data). That is not an
  auth failure.
- Link every claim in the summary.
- High `ghost_count` usually means a Spot-eviction storm, not a reaper bug.
  Check `azure_ghost_check.vm_lifetime` first.

## Related Skills

**taskcluster-worker-lifecycle-logs** for worker-manager traces, **redash**
for ad hoc SQL, **treeherder** for push follow-up.
