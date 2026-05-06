# Post-merge worker-pool health check

After the fxci-config PR merges, the fxci-config deploy CI applies the
new `worker-images.yml` to worker-manager. From that point forward,
newly provisioned workers in the affected pools should be backed by the
new image. This reference describes how to verify that — and what to
escalate when it doesn't happen.

Wait at least 15–30 minutes after merge before checking. Worker-manager
re-evaluates pool config on its own cadence and existing VMs continue
running until they terminate normally; the rollout is gradual, not
instantaneous.

## Confirming the new deploymentId is in use (Windows)

`tc-logview` is the fastest way to see which `deploymentId` recently-
provisioned workers carry. Replace the workerPoolId for whichever pool
you care about:

```bash
tc-logview query -e fx-ci --type worker-running \
  --where 'workerPoolId="gecko-t/win11-64-24h2"' \
  --since 30m --json --limit 200 \
  | jq -r '.providerMetadata.tags.deploymentId' \
  | sort | uniq -c
```

You want to see the new `deploymentId` appearing in the count and old
IDs decreasing over time. If only old IDs show up after 30+ minutes,
something is wrong with the rollout (see "Escalation" below).

For a broader sweep across all the bumped pools, loop the query:

```bash
for pool in gecko-t/win11-64-24h2 gecko-t/win11-64-25h2 \
            gecko-t/win11-a64-24h2-tester gecko-t/win11-a64-25h2-tester \
            gecko-1-b-win2022 gecko-3-b-win2022 \
            gecko-1-b-win11-a64-24h2 gecko-3-b-win11-a64-24h2; do
  echo "== $pool =="
  tc-logview query -e fx-ci --type worker-running \
    --where "workerPoolId=\"$pool\"" --since 30m --json --limit 100 \
    | jq -r '.providerMetadata.tags.deploymentId' | sort | uniq -c
done
```

(Adjust the pool list to match what was actually bumped — phase 3's
fxci-config diff is the source of truth.)

## Confirming the new image name (Linux)

Linux pools don't use ronin_puppet `deploymentId`; the equivalent signal
is the GCE image name. Check `worker-running` events for
`providerMetadata.image` (or the equivalent field in the GCE provider's
metadata):

```bash
tc-logview query -e fx-ci --type worker-running \
  --where 'workerPoolId="gecko-t/t-linux-2404-wayland"' \
  --since 30m --json --limit 100 \
  | jq -r '.providerMetadata.image // .providerMetadata.sourceImage // empty' \
  | sort | uniq -c
```

The dated image name (e.g. `gw-fxci-gcp-l1-2404-amd64-headless-googlecompute-2026-05-04`)
should appear; older dates should fade.

## Pending counts and pool capacity

Pending should not grow unboundedly post-merge. A short-lived spike is
normal as old workers drain and new ones boot, but a sustained climb
means demand is outpacing supply or new workers are failing to start.

```bash
# pool config + current capacity
taskcluster api workerManager workerPool gecko-t/win11-64-24h2

# pending and claimed task counts
taskcluster api queue pendingTasks gecko-t win11-64-24h2
taskcluster api queue claimedTasks gecko-t win11-64-24h2
```

Quick visual via the Taskcluster UI:
`https://firefox-ci-tc.services.mozilla.com/provisioners/gecko-t/worker-types/<pool>`.

## Watching for new failure modes

A bad image often shows up first as a spike in `worker-error` events
with new sysprep / provisioning / TaskCluster-startup failures:

```bash
tc-logview query -e fx-ci --type worker-error \
  --where 'workerPoolId="gecko-t/win11-64-24h2"' \
  --since 2h --json --limit 200 \
  | jq -r '.message // .reason // .errorMessage // empty' \
  | sort | uniq -c | sort -rn | head -20
```

Compare against the same pool's last-week baseline. Categories that
weren't there before are the suspicious ones.

For Windows specifically, in-VM logs (NXLog / generic-worker startup)
are forwarded to SolarWinds Observability — pull them with the
`papertrail` skill if a `worker-error` count is climbing and you need
the actual error text.

## Escalation criteria

| Symptom | What it usually means | First move |
|---|---|---|
| New deploymentId/image name doesn't appear after 30 min | fxci-config deploy CI didn't apply, or the worker-images.yml diff didn't reach worker-manager | Check the most recent `apply` task in the `firefox-ci-tc` Taskcluster admin namespace; rerun if it failed. |
| Old deploymentId/image name persists for a specific pool only | The pool has a per-pool override in fxci-config that wasn't bumped | Re-grep the `worker-pools.yml` and `worker-images.yml` keys for the pool. |
| `worker-error` rate ≥ 2× baseline within 2 h of merge | Image regression — probably bad ronin_puppet content | Roll back ronin_puppet `deploymentId` to the prior value, rebuild the affected image at the next `image_version`, ship a fxci-config revert PR. |
| Pending grows steadily, no new errors | Demand-side spike or capacity limit | Hand off to the `queue-diagnosis` skill — it does a fuller supply/demand split. |
| Pending grows AND new errors | Both: image issue plus accumulated demand | Roll back first, then triage the queue once provisioning is healthy again. |

## Don't reinvent queue-diagnosis

If the post-merge check uncovers a queue that's actually backed up
rather than just slow to roll over, switch to the `queue-diagnosis`
skill — it gathers Taskcluster pool state and Redash demand data and
produces a structured diagnosis. Don't duplicate that work inline here.

## Cleanup notes

- This phase is observational. Avoid issuing terminations or capacity
  changes during the rollover unless something is clearly broken — the
  pool drains itself within an hour or so under normal conditions.
- Capture any unexpected findings in `~/moz_artifacts/` so future
  rollouts can spot the same pattern earlier.
