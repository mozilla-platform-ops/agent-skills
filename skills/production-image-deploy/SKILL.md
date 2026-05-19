---
name: production-image-deploy
description: |
  Deploy a Firefox CI worker image end-to-end: trigger the production
  worker-images build, verify what was published, bump
  `worker-images.yml` in fxci-config, gate the rollout on Taskcluster
  integration tests (via the `/taskcluster integration` PR comment or
  optionally an alpha-pool try push), post the Slack changelog, and run
  a post-merge worker-pool health check. Covers Windows (Azure SIG,
  semver-versioned) and Linux (GCP, date-stamped image names).

  Use this whenever the user wants to roll out a new ronin_puppet commit
  to worker images, ship a new generic-worker / Taskcluster cloud
  worker bump, promote alpha images to prod, or "do another version bump
  like PR mozilla-releng/fxci-config#955 / #968". Trigger phrases
  include "deploy production image", "roll out a new image version",
  "bump windows images", "promote ubuntu 2404 image", "update
  worker-images.yml in fxci-config", "ship new ronin_puppet commit",
  "trigger integration tests on the fxci-config PR", "validate a new
  image", "check that the new image is rolling out", and "follow up on
  PR #<n>" when the referenced PR is an image-version bump.

  Reach for this skill before doing the work by hand — it captures the
  release-engineering conventions (validation gate, PR title format,
  body skeleton, branch naming, `/taskcluster integration` comment
  trigger, Slack changelog format, post-merge health checks, what NOT
  to include) the team has converged on.
---

# Production image deploy

End-to-end skill for promoting a new worker image into Firefox CI: trigger
the build in `mozilla-platform-ops/worker-images`, verify the published
artifact, then bump `worker-images.yml` in `mozilla-releng/fxci-config` and
open the rollout PR.

The three repos involved:

| Repo | Role |
|---|---|
| `mozilla-platform-ops/ronin_puppet` | Source of truth for what is provisioned inside the image. A commit hash from `master` is baked into the image as its `deploymentId`. |
| `mozilla-platform-ops/worker-images` | Packer + Action workflows that build images. Per-config YAML files (`config/<name>.yaml`) carry the target version + `deploymentId`. SBOMs land in `sboms/`. |
| `mozilla-releng/fxci-config` | Worker-pool definitions. `worker-images.yml` is the "what gets booted in CI" map; bumping it is what actually puts a new image into rotation. |

Treat the phases below as a checklist. Validation runs at three
different surfaces (described next), and which ones apply depends on
the cloud and the configs being rebuilt. Phase 5 (post-merge health)
should always happen. Skip phase 1 if the user has already triggered
the production build — verify what's published before editing
fxci-config.

## Validation surfaces

Three places where integration tests can run against a candidate
image. They overlap intentionally: each catches things the others
miss.

### Surface 1 — In-build OS integration tests (automatic, only some workflows)

The Azure non-trusted build workflows automatically chain
`.github/workflows/os-integration.yml` after the `packer` job. The
chained job resolves the just-published shared image from the
config's `sharedimage.image_name`, then submits Taskcluster
os-integration tasks against that image (via a hook, using
`TASKCLUSTER_OS_INT_CLIENT_ID`). Results show up as `OS Integration
Tests - <config>` jobs inside the same Action run.

Workflows that auto-trigger this:

- `FXCI - Azure` (`sig-nontrusted.yml`)
- `FXCI - Azure Prod Parallel Images` (`sig-FXCI-parallel-build.yml`)
- `FXCI - Azure Alpha Parallel Images` (`sig-FXCI-nontrusted-parallel-build-alpha.yml`)

Configs the auto-chain skips (so they get **no** integration coverage
from surface 1):

- All `win2022*` configs (`if: !startsWith(config, 'win2022')` in
  `sig-nontrusted.yml`; same filter pattern in the parallel
  workflows).
- Alpha-parallel only: `win11-a64-*-builder` configs (filtered out of
  `os_integration_matrix`).
- All `FXCI - Azure - Trusted` builds (`sig-trusted.yml` does not
  invoke `os-integration.yml`).
- All Linux GCP workflows (`gcp-*.yml` do not invoke it).

For configs the workflow skips, surface 2 carries the load.

### Surface 2 — `/taskcluster integration` on the fxci-config PR

Once the bump PR is open (phase 3), post the literal comment
`/taskcluster integration` on it. fxci-config's `.taskcluster.yml`
listens for `github-issue-comment` events whose body starts with
`/taskcluster ` and dispatches a decision task with the rest of the
comment as the `target_tasks_method` (so `integration` runs every
task in the PR's task graph tagged with the `integration` attribute,
defined by `taskcluster/fxci_config_taskgraph/target_tasks.py`).

The decision task schedules os-integration tasks against **the pool
and image binding defined by the PR's diff** — exercising the new
image as it would land in production, including any worker-pool
config interactions surface 1 can't see. Results report back to the
PR via `checks-v1`.

The hookup is in phase 3 below — see "Trigger integration tests on
the PR".

### Surface 3 — `os-integrations` mach try push (fallback)

Use this when surfaces 1 and 2 don't cover what you need:

- You need test coverage the integration suite doesn't carry — perf
  jobs, browsertime, talos, anything the suite filters out.
- You're iterating on a ronin_puppet candidate and want broader
  coverage than the integration hook gives you.
- You're trying to reproduce an end-user failure on a specific test
  platform combo against a candidate image.

Hand off to the `os-integrations` skill — it carries the canonical
mach try flag bundles for win10, win11-24h2, win11-25h2, ARM64,
ubuntu 2404, etc., and knows to use the autoland decision-task
baseline (per `~/.claude/CLAUDE.md`). Watch results in Treeherder via
the `treeherder` skill. New Tier-1 reds → fix in ronin_puppet and
rebuild before continuing; non-blocking follow-ups → file a RELOPS
ticket and reference it in the phase-3 PR's `## Related` section.

## Phase 1 — Trigger the build

Pick the workflow based on cloud + image kind. Files live in
`mozilla-platform-ops/worker-images/.github/workflows/`. All require
membership in `.github/relsre.json`.

### Windows (Azure SIG)

| Workflow name | Use when |
|---|---|
| `FXCI - Azure` | Build a single Windows config (untrusted gallery: `win10-*`, `win11-*`, `win2022-*`, alphas). Most common. |
| `FXCI - Azure - Trusted` | Trusted gallery only: `trusted-win11-a64-24h2-builder`, `trusted-win11-a64-25h2-builder`, `trusted-win2022-64-2009`. |
| `FXCI - Azure Prod Parallel Images` | Build every production Windows config in one matrix run. Used when ronin_puppet bumps affect all families (e.g. PR #955, #982). |
| `FXCI - Azure Alpha Parallel Images` | Same, alpha pools only. |

### Linux (GCP)

| Workflow name | Use when |
|---|---|
| `FXCI - GCP` | Single alpha Ubuntu 24.04 config (untrusted, level-1). |
| `FXCI - GCP Production` | Single production Ubuntu 24.04 config — promotes the image into the production GCP project. |
| `FXCI - GCP Prod Parallel Images` | Build every production Linux config (level-1 + level-3 trusted) in one matrix run. Used for PR #968-style rollouts. |
| `FXCI - GCP Alpha Parallel Images` | Same, alpha. |

### Setting the ronin_puppet commit before the build (Windows only)

Windows builds use the `deploymentId` field in
`config/windows_production_defaults.yaml` (and per-config overrides) as the
ronin_puppet commit to deploy. **The commit must be on `master`** — Packer
clones `mozilla-platform-ops/ronin_puppet` at that hash during provisioning.

Before triggering: confirm the desired ronin_puppet hash is on master and
that `windows_production_defaults.yaml`'s `deploymentId` reflects it. If it
doesn't, land a small worker-images PR that bumps the default (and bumps
each config's `image_version` to the next semver) **before** dispatching
the build. See `references/windows.md` for the version semantics.

Linux builds are date-stamped (no ronin_puppet `deploymentId` — Linux is
provisioned in-line with packer scripts under `scripts/linux/`), so this
step doesn't apply.

### Dispatching

Use `gh workflow run` with the exact workflow name (the parallel ones take
no inputs):

```bash
# Windows single config
gh workflow run "FXCI - Azure" \
  --repo mozilla-platform-ops/worker-images \
  -f config=win11-64-24h2

# Windows trusted single config
gh workflow run "FXCI - Azure - Trusted" \
  --repo mozilla-platform-ops/worker-images \
  -f config=trusted-win11-a64-25h2-builder

# Windows full prod rollout (no inputs — builds the matrix)
gh workflow run "FXCI - Azure Prod Parallel Images" \
  --repo mozilla-platform-ops/worker-images

# Linux production single
gh workflow run "FXCI - GCP Production" \
  --repo mozilla-platform-ops/worker-images \
  -f config=gw-fxci-gcp-l1-2404-headless-alpha

# Linux full prod rollout
gh workflow run "FXCI - GCP Prod Parallel Images" \
  --repo mozilla-platform-ops/worker-images
```

After dispatch, surface the run URL so the user can monitor it:

```bash
gh run list --repo mozilla-platform-ops/worker-images \
  --workflow "<workflow-name>" --limit 1 \
  --json databaseId,url,status,createdAt
```

Builds take a while (look at recent runs of the same workflow to set
expectations rather than guessing) — don't poll in a tight loop; just
hand off the run URL and come back when it finishes.

## Phase 2 — Verify what was published

Don't trust workflow titles alone. Builds can succeed yet publish a
different version than expected (e.g. when the per-config `image_version`
wasn't bumped). The `Upload release notes` job can also fail silently
without affecting the published artifact.

For each rebuilt config:

1. Open the run and inspect job conclusions:
   ```bash
   gh run view <RUN_ID> --repo mozilla-platform-ops/worker-images \
     --json jobs --jq '.jobs[] | "\(.conclusion) \(.name)"'
   ```
   For workflows that chain os-integration (see surface 1 above), an
   `OS Integration Tests - <config>` job will also appear here. Treat
   its conclusion as the in-build validation signal; if it failed,
   investigate before continuing to phase 3.
2. For Windows, search the per-config build log for the published version
   and gallery URL — Packer prints them at the end of the `Run Packer`
   step:
   ```bash
   gh run view --job <JOB_ID> --repo mozilla-platform-ops/worker-images \
     --log 2>&1 | grep -E "(SIG image version|Shared Gallery Image Version ID|deploymentId)"
   ```
3. Cross-check against the SBOMs in `worker-images/sboms/` (UTF-16 — pipe
   through `iconv -f UTF-16LE -t UTF-8`). The SBOM filename is
   `<config>-<version>.md` and contains the resolved `DeploymentId`,
   `OS Version`, and Taskcluster package versions.
4. For Linux, the published image's full GCE name (with date suffix)
   appears in the deploy step's log; capture it verbatim — that's what
   goes into fxci-config.

Detailed verify recipes: `references/windows.md` and `references/linux.md`.

## Phase 3 — Bump fxci-config and open the PR

Read `references/fxci-config-mapping.md` for the canonical mapping between
worker-images config names and `worker-images.yml` keys — that is the most
common source of mistakes.

### Branch and commit hygiene

- Cut a feature branch off `main`. Name it after the bump itself, e.g.
  `bump-windows-images-1.3.3-1.0.3`, `bump-ubuntu-2404-2026-05-04`.
- Edit `worker-images.yml`. For Windows entries, change `version` and
  `deployment_id` together — they are a single conceptual unit. For Linux,
  replace the full `projects/.../images/<name>` string on the
  `fxci-level1-gcp` (and `fxci-level3-gcp` if present) lines.
- Leave alpha pools alone unless the user explicitly asks. Alpha entries
  have `version: 1.0.0` and `deployment_id: alpha` and aren't part of a
  prod rollout.
- Don't touch images that have been retired from the production list in
  `worker-images/config/windows_production_defaults.yaml` (e.g.
  `ronin_t_windows11_64_2009` was dropped in worker-images@`9bbca89`).
- Run `uvx pre-commit run --files worker-images.yml` before committing.
  Don't skip hooks.
- Stage `worker-images.yml` by name (`git add worker-images.yml`); never
  `git add -A` in this repo.
- Commit subject ≤72 chars, imperative mood. The convention is
  `chore(azure): ...` for Windows and `feat(gcp): ...` or `chore(gcp):
  ...` for Linux.

### PR title format

Match prior rollouts so the team can grep for them. Substitute the actual
version numbers / dates from phase 2 — never guess them:

- Windows: `chore(azure): bump windows <new_version> and win11 25h2 <new_version> image versions`
  (drop the second clause if only one family was rebuilt)
- Linux: `feat(gcp): Update Ubuntu 24.04 images to <YYYY-MM-DD> builds`

### PR body skeleton

The team has converged on a tight body. **Skip per-image bump tables and
skip the test-plan section** — neither survives review and they rot
quickly. Keep the body to:

1. **Summary** — 1–2 bullets stating which families went to which version
   and (Windows only) the ronin_puppet commit they deploy from.
2. **Build provenance** — the worker-images run URL and SHA the build was
   cut from.
3. **ronin_puppet commits** (Windows only) — a small table of
   Windows-relevant commits in the range from the prior `deploymentId` to
   the new one. Use `git log --oneline <prev>..<new>` and filter out
   macOS-only / scriptworker-only / unrelated commits. Always include the
   `[Full compare]` GitHub link.
4. **Related** — Jira/GitHub issue link if the bump is driven by one
   (`RELOPS-####`, "follow-up to #<n>").

For Windows, if a temporary rollback-then-restore happened inside the
range (e.g. a generic-worker version was reverted in one commit and
re-pinned in a later one), call it out in Summary so reviewers don't
read the diff as a new regression.

Reference templates and worked examples: `references/pr-templates.md`.

### Trigger integration tests on the PR

Immediately after opening the PR, post the comment `/taskcluster
integration` (no extra text). That dispatches a Taskcluster decision
task that schedules every `integration`-tagged task against the pool
and image config defined by the PR's diff. Results land back on the
PR as `checks-v1` entries.

```bash
gh pr comment <PR_NUMBER> --repo mozilla-releng/fxci-config \
  --body '/taskcluster integration'
```

The comment author must be a collaborator (`policy.allowComments:
collaborators` in `.taskcluster.yml`). If the comment doesn't trigger
anything within a minute or two, double-check spelling — the decision
task only fires for `/taskcluster <method>` exact-prefix matches, and
the only valid method for image-bump PRs is `integration`.

Treat the resulting checks the same way you'd treat alpha-pool Tier-1:
new reds are a stop sign, intermittents get noted but not blocked on.

### Reviewers and merge

- Default reviewer pool: check who reviewed the last few image-version
  bump PRs in fxci-config (e.g. PRs #955, #968, #982) and request the
  same set. Don't hardcode names — the rotation changes.
- Auto-merge (squash) is the team default for these PRs once green —
  but don't enable auto-merge before the integration checks have
  actually started reporting; otherwise the PR can squash-merge on the
  reviewer's approval before the integration suite even runs.

## Phase 4 — Announce in Slack

After the fxci-config PR **merges**, draft a Slack changelog so people
running CI know which images flipped. The team's convention is a
plain-text post with three sections:

1. A one-line "we've updated …" header.
2. 2–4 bullets describing what's new (sourced from the ronin_puppet
   commit range and the gw / OS-level package versions surfaced during
   phase 2).
3. A link to the merged fxci-config PR plus a list of
   release-notes URLs — one per rebuilt config — pointing at
   `worker-images/main`'s SBOM markdown files.

Don't post until the PR has merged; the SBOM URLs resolve to
`/blob/main/...` and 404 until the merge commit lands.

The full template (Windows + Linux variants) and the friendly-name
mapping the team uses live in `references/slack-changelog.md`. Trim the
URL list to only the configs that were actually rebuilt — a hotfix
should not include lines for configs that didn't move.

## Phase 5 — Post-merge worker-pool health check

Once the fxci-config PR merges, fxci-config's deploy CI propagates the
new `worker-images.yml` to worker-manager. Newly provisioned workers
in the affected pools should start booting from the new image. Confirm
that's actually happening — don't assume.

Wait 15–30 minutes after merge, then for each bumped pool:

1. **Confirm the new `deploymentId` (Windows) or dated image name
   (Linux) is showing up on freshly-provisioned workers**, using
   `tc-logview`'s `worker-running` events. Old IDs should fade as old
   workers terminate; new IDs should be visible within ~30 minutes.
2. **Sanity-check pending counts and pool capacity** via
   `taskcluster api`. A short-lived spike during the rollover is
   normal; a sustained climb is not.
3. **Watch `worker-error` for new failure modes.** A spike in sysprep
   or generic-worker-startup errors right after merge usually means a
   bad image — be ready to roll back.
4. If anything looks off, hand off to the `queue-diagnosis` skill for
   a structured supply/demand split before reacting.

Concrete `tc-logview` queries, escalation thresholds, and the rollback
recipe live in `references/post-merge-health.md`.

## What this skill does NOT do

- It does not push commits to ronin_puppet or worker-images. Image content
  changes go through their own review.
- It delegates mach try pushes and tier evaluation to the
  `os-integrations` and `treeherder` skills (validation surface 3). It
  tells you when to invoke them, not how to drive them.
- It delegates queue-backlog triage to the `queue-diagnosis` skill
  (phase 5). If post-merge pending grows, switch over rather than
  duplicating that analysis here.
- It does not bump community-tc-config. That repo has its own image
  conventions; ask the user before extending there.

## References

- `references/windows.md` — Azure SIG mechanics, semver convention, SBOM
  layout, Packer log parsing.
- `references/linux.md` — GCP image naming, finding the dated image name,
  level-1 vs level-3 trusted GCP projects.
- `references/fxci-config-mapping.md` — exhaustive mapping from
  worker-images config names to `worker-images.yml` keys, including the
  legacy `ronin_*` naming for Windows.
- `references/pr-templates.md` — copy-paste PR titles, branch names, and
  body skeletons for Windows and Linux rollouts.
- `references/slack-changelog.md` — post-rollout Slack changelog
  template plus the friendly-name → worker-images-config mapping used
  in the per-image SBOM link list.
- `references/post-merge-health.md` — phase-5 `tc-logview` and
  Taskcluster API queries, escalation thresholds, and rollback recipe
  for when the new image misbehaves.
