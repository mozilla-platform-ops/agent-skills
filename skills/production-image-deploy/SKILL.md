---
name: production-image-deploy
description: |
  Deploy Firefox CI production worker images by coordinating worker-images
  GitHub Actions builds, fxci-config worker-images.yml bumps, Taskcluster
  validation, Slack changelogs, post-merge health checks, and Bugzilla
  deployment records. Use for production rollouts of ronin_puppet,
  generic-worker, cloud-worker, Windows Azure SIG, or Linux GCP changes.
  DO NOT USE FOR build-only requests; use worker-image-build.
---

# Production image deploy

End-to-end skill for promoting a new worker image into Firefox CI: trigger
the build in `mozilla-platform-ops/worker-images`, verify the published
artifact, bump `worker-images.yml` in `mozilla-releng/fxci-config`, open the
rollout PR, announce it, confirm the pools roll over, and record the completed
Windows deployment in Bugzilla.

| Repo | Role |
|---|---|
| `mozilla-platform-ops/ronin_puppet` | Source of truth for what's provisioned inside the image. A `master` commit hash is baked in as the image's `deploymentId`. |
| `mozilla-platform-ops/worker-images` | Packer + Action workflows that build images. Per-config YAML (`config/<name>.yaml`) carries the target version + `deploymentId`. SBOMs land in `sboms/`. |
| `mozilla-releng/fxci-config` | Worker-pool definitions. `worker-images.yml` is the "what gets booted in CI" map; bumping it is what puts a new image into rotation. |

Treat the phases below as a checklist. Skip phase 1 if the user already
triggered the build — verify what's published before editing fxci-config.
Phase 5 (post-merge health) always happens. Phase 6 applies to Windows
production rollouts.

## Validation surfaces

Integration tests run at three surfaces; which apply depends on the cloud
and configs rebuilt.

| Surface | What it is | Coverage |
|---|---|---|
| 1 — in-build | Azure non-trusted workflows auto-chain `os-integration.yml` after `packer`; results show as `OS Integration Tests - <config>` jobs in the same run. | Skips all `win2022*`, all trusted builds, all Linux, and (alpha-parallel only) `win11-a64-*-builder`. |
| 2 — fxci-config PR | Comment `/taskcluster integration` on the bump PR; runs every `integration`-tagged task against the pool+image binding in the PR's diff. Reports via `checks-v1`. | Carries the load for whatever surface 1 skips. Wired up in phase 3. |
| 3 — mach try | Fallback via the `os-integrations` skill when 1 and 2 don't cover what you need (perf/talos/browsertime, broader candidate iteration, reproducing a specific failure). | On demand. Watch in Treeherder; new Tier-1 reds → fix in ronin_puppet and rebuild. |

## Phase 0 — Open the RELOPS tracking Story

Every production Windows rollout gets a RELOPS tracking **Story** before work
starts. Run its description through `/humanizer`. Mechanics and field values:
`references/tracking.md`.

In short:

- **JIRA Story** (`jira` skill): use a summary that matches the planned scope,
  file it under the current `[YYYY HX] Win 10/11 Support and Deployments`
  epic, and link each underlying ronin_puppet RELOPS ticket from the commit
  range. Drive `Backlog → In Progress` when work starts. Mark it Done only
  after phases 5 and 6 finish.

Reference the Story (`RELOPS-####`) in the worker-images and fxci-config PRs.

## Phase 1 — Trigger the build

Pick the workflow by cloud + image kind. Files live in
`worker-images/.github/workflows/`; all require membership in
`.github/relsre.json`.

### Windows (Azure SIG)

| Workflow name | Use when |
|---|---|
| `FXCI - Azure` | Single untrusted config (`win10-*`, `win11-*`, `win2022-*`, alphas). Most common. |
| `FXCI - Azure - Trusted` | Trusted gallery only: `trusted-win11-a64-25h2-builder`, `trusted-win2022-64-2009`. |
| `FXCI - Azure Prod Parallel Images` | Every production Windows config in one matrix (6 untrusted + 2 auto-discovered Azure `trusted-*`). For ronin_puppet bumps affecting all families. |
| `FXCI - Azure Alpha Parallel Images` | Same, alpha pools only. |

### Linux (GCP)

| Workflow name | Use when |
|---|---|
| `FXCI - GCP` | Single alpha Ubuntu 24.04 config (untrusted, level-1). |
| `FXCI - GCP Production` | Single production Ubuntu 24.04 config. |
| `FXCI - GCP Prod Parallel Images` | Every production Linux config (L1 + L3) in one matrix. |
| `FXCI - GCP Alpha Parallel Images` | Same, alpha. |

### Before dispatching (Windows)

- **Set the ronin_puppet pin.** Windows builds deploy the `deploymentId` in
  `config/windows_production_defaults.yaml` (commit must be on `master`). If
  it doesn't match the desired hash, land a small worker-images PR bumping it
  (and each config's `image_version`) first. Latest master:
  `gh api repos/mozilla-platform-ops/ronin_puppet/commits/master --jq '.sha[0:7]'`.
  Version semantics + bump steps: `references/windows.md`.
- **Check the Marketplace base image** for a regressing republish, and use
  `azure.build_location` to retry in another region if a CDN issue is
  suspected — both in `references/windows.md`.
- Linux builds are date-stamped (no `deploymentId`), so these don't apply.

### Alpha-first sequence (Windows)

The expected order for a ronin_puppet bump is **alpha then production**, gated
on the alpha builds' surface-1 os-integration passing. Dispatch
`FXCI - Azure Alpha Parallel Images`, confirm its `OS Integration Tests`
jobs are green, then dispatch the prod parallel workflow.

Caveat: alpha configs don't auto-track master — several pin `sourceBranch` to
a relops feature branch with `deploymentId: NA`. To validate a *master*
commit on alpha, set the prod-defaults `deploymentId` **and** switch each
alpha config to `sourceBranch: master` + `deploymentId: default`. That
overwrites whatever feature branch the alpha was testing — **confirm with the
user first.** Note the surface-1 gaps (`win11-a64-25h2-builder-alpha` is
commented out of `images.alpha`; a64 builders and `win2022*` aren't
auto-chained) and lean on surface 2/3 for those.

A config that fails 5+ reruns can be removed from `images.production` so
parallel prod runs stay clean while you fix it; add it back after.

### Dispatching

```bash
# Windows single config
gh workflow run "FXCI - Azure" --repo mozilla-platform-ops/worker-images -f config=win11-64-24h2
# Windows trusted single config
gh workflow run "FXCI - Azure - Trusted" --repo mozilla-platform-ops/worker-images -f config=trusted-win11-a64-25h2-builder
# Full prod rollout (no inputs — builds the matrix)
gh workflow run "FXCI - Azure Prod Parallel Images" --repo mozilla-platform-ops/worker-images
# Linux production single / full
gh workflow run "FXCI - GCP Production" --repo mozilla-platform-ops/worker-images -f config=gw-fxci-gcp-l1-2404-headless-alpha
gh workflow run "FXCI - GCP Prod Parallel Images" --repo mozilla-platform-ops/worker-images
```

Surface the run URL and hand off — builds take a while; don't poll tightly:

```bash
gh run list --repo mozilla-platform-ops/worker-images --workflow "<name>" --limit 1 \
  --json databaseId,url,status,createdAt
```

`gh run watch` follows only one run; for parallel dispatches poll `gh run
list` or rely on the per-run GHA email.

## Phase 2 — Verify what was published

Job badges lie in both directions: a "failure" job can still have published
to SIG, and a "success" job can publish the wrong version if `image_version`
wasn't bumped. **The gallery and SBOM are authoritative, not the badge.**

For each rebuilt config:

1. Inspect job conclusions (`gh run view <RUN_ID> --json jobs`), including any
   `OS Integration Tests - <config>` job (surface 1).
2. **(Windows) Confirm the version exists in the SIG** — the authoritative
   check that worker-manager can reach it:
   ```bash
   az sig image-version list --resource-group rg-packer-worker-images \
     --gallery-name <gallery_name> --gallery-image-definition <image_name> \
     --query "[].{name:name, state:provisioningState}" -o table
   ```
   `provisioningState` should be `Succeeded`. If absent, the build didn't
   publish.
3. Cross-check the baked-in `deploymentId` via the gallery version tags or
   the SBOM (`sboms/<config>-<version>.md`, UTF-16LE).
4. **(Linux)** Capture the published GCE image name (with date suffix) from
   the deploy step's log — that's what goes into fxci-config. Confirm the
   matching production SBOM landed in `worker-images/sboms/`, and save its
   `blob/main` URL for the fxci-config PR and Slack changelog.

Detailed verify recipes, SBOM parsing, and missing-SBOM recovery:
`references/windows.md` and `references/linux.md`.

## Phase 3 — Bump fxci-config and open the PR

`references/fxci-config-mapping.md` has the canonical mapping from
worker-images config names to `worker-images.yml` keys — the most common
source of mistakes.

- **Branch** off `main`, named after the bump (`bump-windows-images-1.3.5-1.0.5`).
- **Edit `worker-images.yml`:** for Windows change `version` + `deployment_id`
  together; for Linux replace the full image string on the `fxci-level1-gcp`
  (and `fxci-level3-gcp`) lines. Leave alpha pools and retired configs alone.
- Run `uvx pre-commit run --files worker-images.yml`; stage by name; commit
  `chore(azure): ...` (Windows) or `feat(gcp): ...` (Linux), ≤72 chars.
- **PR body** stays tight — Summary, Build provenance (run URL + SHA), a
  Windows-relevant ronin_puppet commit table with `[Full compare]` link, and
  Related links. Skip per-image bump tables and test-plan sections. Titles,
  body skeletons, and worked examples: `references/pr-templates.md`. Open with
  `gh pr create --body-file` (never a HEREDOC — it mangles backticks).
- **Ubuntu PRs:** include at least one direct `worker-images/blob/main/sboms/`
  link in Build provenance. Use an SBOM from the images in the rollout; for a
  full Ubuntu 24.04 rollout, use the Wayland AMD64 SBOM as the primary link.
- **Partial rollout** (N of M published): drop the deferred entries via a new
  commit (don't amend), retitle, and open a follow-up once they publish.
- **Staging:** skip `tc-admin diff` for a pure version bump; stage first if
  the PR also touches `worker-pools.yml` or scopes.
- **Trigger integration** (surface 2) immediately after opening:
  ```bash
  gh pr comment <PR_NUMBER> --repo mozilla-releng/fxci-config --body '/taskcluster integration'
  ```
  Author must be a collaborator; only `/taskcluster integration` fires for
  image-bump PRs. Treat new reds as a stop sign; intermittents are noted.
- **Merge:** request the reviewers from recent bump PRs (#955/#968/#982);
  squash auto-merge is the default once green — but don't enable it before the
  integration checks start reporting.

## Phase 4 — Announce in Slack

After the fxci-config PR **merges** (SBOM URLs 404 until then), post a
compact changelog: a one-line "we've updated …" header, 2–4 bullets of
what changed (from the ronin_puppet range + gw/OS versions seen in phase 2),
and the merged PR link plus one SBOM release-notes URL per rebuilt config.
Match the header and update label to the actual rollout scope; don't say "all
Windows images" for a single-image rollout. Trim the URL list to only what
moved. Ubuntu changelogs must include at least one direct SBOM URL. When you
send through the Slack connector, use a named Markdown link for every URL,
then read the sent message back and verify each link label and target.
Bare URLs can absorb the next line during connector conversion. Templates,
verification steps, and the manual clipboard recipe:
`references/slack-changelog.md`.

## Phase 5 — Post-merge worker-pool health check

After merge, fxci-config's deploy CI propagates `worker-images.yml` to
worker-manager and new workers should boot from the new image. Wait 15–30 min,
then per bumped pool:

1. **Confirm the new `deploymentId` (Windows) / dated image name (Linux)** on
   freshly-provisioned workers via `tc-logview` `worker-running` events. The
   `deploymentId` is **not** a typed field — a `--filter '"<id>"'` returns 0
   even when it's live; read the raw payload instead.
2. **Scope to the merge timestamp**, not a rolling `--since` window, and
   account for idle pools: a pool with 0 pending provisions nothing post-merge,
   so its image is configured but not yet observed booting. Don't mark the
   Story Done until every pool you care about has had a post-merge worker reach
   `running` with no `worker-error`.
3. **Watch `worker-error`** by typed `workerPoolId`; a spike right after merge
   usually means a bad image — be ready to roll back.
4. If pending climbs, hand off to `queue-diagnosis` rather than triaging here.

Queries, escalation thresholds, idle-pool handling, and the rollback recipe:
`references/post-merge-health.md`.

## Phase 6 — File the Bugzilla deployment record (Windows)

After the merged deployment passes phase 5, use the `bugzilla` skill to file a
Bugzilla **task** that records exactly what reached production. Scope its title
and description to the images and pools that changed. Include the image
version, ronin_puppet `deploymentId`, worker-images build and PR, merged
fxci-config PR, validation links, and RELOPS Story.

Use `Infrastructure & Operations` / `RelOps: Windows OS`, version `other`, and
cross-link it with the RELOPS Story. Resolve the deployment task as FIXED once
the links are complete. If a later regression came from the rollout, put this
deployment bug in the regression bug's **Regressed by** field; Bugzilla then
lists that issue under the deployment bug's **Regressions** field. Field values,
commands, scope examples, and Bug 2050308: `references/tracking.md`.

## What this skill does NOT do

- Does not push commits to ronin_puppet or worker-images — image content
  changes go through their own review.
- Delegates mach try / tier evaluation to `os-integrations` + `treeherder`
  (surface 3), and queue-backlog triage to `queue-diagnosis` (phase 5).
- Does not bump community-tc-config — ask the user before extending there.

## References

- `references/windows.md` — Azure SIG mechanics, semver, SBOM layout, Packer
  log parsing, Marketplace pre-flight, NetFx3/DXSDK and live-VM build debugging.
- `references/linux.md` — GCP image naming, finding the dated image name, L1
  vs L3 trusted GCP projects.
- `references/fxci-config-mapping.md` — config name → `worker-images.yml` key
  mapping, including legacy `ronin_*` Windows naming.
- `references/pr-templates.md` — PR titles, branch names, body skeletons.
- `references/tracking.md` — initial JIRA Story and final Bugzilla deployment
  record, including field values and cross-linking.
- `references/slack-changelog.md` — changelog template + friendly-name mapping
  + clipboard recipe.
- `references/post-merge-health.md` — phase-5 `tc-logview`/Taskcluster queries,
  escalation thresholds, rollback recipe.
