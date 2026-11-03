# Post-merge worker-pool health check

After the fxci-config PR merges, its deploy CI applies the new
`worker-images.yml` to worker-manager. Newly provisioned workers in the
affected pools should boot the new image. Existing VMs run until they
terminate, so the rollout is gradual. Wait 15–30 minutes after merge.

Query worker-manager logs with the **taskcluster-worker-lifecycle-logs**
skill. Check flags and typed fields with `tc-logview query --help` and
`tc-logview list --service worker-manager` before you query.

## Pools to check

Phase 3's fxci-config diff lists the aliases that moved. Find the pool IDs
(`<provisioner>/<workerType>`) that use each alias in `worker-pools.yml`.

## Signals

For each pool, use only workers that reached `running` after the merge:

1. Get the merge time:
   `gh pr view <PR> --repo mozilla-releng/fxci-config --json mergedAt`.
2. Query `worker-running` and `worker-error` with `--from <merge-time>`.
   Do not use `--since`; a rolling window counts old-image workers.
3. Confirm the new image on a `worker-running` event. On Windows this is the
   ronin_puppet `deploymentId` VM tag. On Linux it is the dated GCE image
   name. Neither is a typed field, so a `--filter '"<id>"'` can return 0
   while the image is live. Read one `--raw` event, find the value, then
   aggregate on that path.
4. Compare `worker-error` titles against the pool's last-week baseline. New
   categories are suspect. Use the **papertrail** skill for in-VM error text.
5. Check pending with `taskcluster api queue --help` to find the current
   subcommand, or open
   `https://firefox-ci-tc.services.mozilla.com/provisioners/<provisioner>/worker-types/<workerType>`.

## Idle pools

A pool with 0 pending provisions nothing after merge. Its launch config is
correct, but nobody has seen it boot yet. Wait for demand or push a
`mach try` job to that worker type. Do not move the tracking Story to Done
until each pool you care about has a post-merge worker in `running` with no
`worker-error`.

## Escalation criteria

| Symptom | What it usually means | First move |
|---|---|---|
| New image does not appear after 30 min | fxci-config deploy CI did not apply | Check the latest `apply` task in the `firefox-ci-tc` admin namespace; rerun if it failed. |
| Old image persists for one pool only | Per-pool override that was not bumped | Re-grep `worker-pools.yml` and `worker-images.yml` for the pool. |
| `worker-error` rate ≥ 2× baseline within 2 h | Image regression | Roll back the ronin_puppet `deploymentId`, rebuild at the next `image_version`, ship a fxci-config revert PR. |
| Pending grows, no new errors | Demand spike or capacity limit | Hand off to **queue-diagnosis**. |
| Pending grows and new errors | Image issue plus queued demand | Roll back first, then triage the queue. |

## Cleanup notes

- This phase only observes. Do not terminate workers or change capacity
  unless something is clearly broken.
- Save unexpected findings in `~/moz_artifacts/` for future rollouts.
