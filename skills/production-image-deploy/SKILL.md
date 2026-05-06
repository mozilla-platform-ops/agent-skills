---
name: production-image-deploy
description: |
  Deploy a Firefox CI worker image end-to-end: trigger the worker-images
  GitHub Actions build, verify what was published, then bump
  `worker-images.yml` in fxci-config and open the rollout PR. Covers Windows
  (Azure SIG, semver-versioned) and Linux (GCP, date-stamped image names).

  Use this whenever the user wants to roll out a new ronin_puppet commit to
  worker images, ship a new generic-worker / Taskcluster cloud worker bump,
  promote alpha images to prod, or "do another version bump like PR
  mozilla-releng/fxci-config#955 / #968". Trigger phrases include "deploy
  production image", "roll out a new image version", "bump windows
  images", "promote ubuntu 2404 image", "update worker-images.yml in
  fxci-config", "ship new ronin_puppet commit", and "follow up on PR
  #<n>" when the referenced PR is an image-version bump.

  Reach for this skill before doing the work by hand — it captures the
  release-engineering conventions (PR title format, body skeleton, branch
  naming, what NOT to include) the team has converged on.
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

Treat the three phases below as a checklist. Skip phase 1 if the user has
already triggered the build — verify what's published before editing
fxci-config.

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

Don't poll inside a tight loop — Windows builds take 45–90 minutes per
config, Linux around 20–40 minutes.

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

### Reviewers and merge

- Default reviewer pool: whoever last reviewed an image-version bump in
  fxci-config (commonly `rcurranmoz`). Ask if unsure.
- Auto-merge (squash) is the team default for these PRs once green.

## What this skill does NOT do

- It does not push commits to ronin_puppet or worker-images. Image content
  changes go through their own review.
- It does not run image-validation try-pushes. That's the
  `os-integrations` skill — invoke it separately if the user wants
  pre-flight test coverage before the bump lands.
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
