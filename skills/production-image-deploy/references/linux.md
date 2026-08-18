# Linux image deploy reference

## Naming convention

Linux GCE images don't use SemVer — they're date-stamped. Names look like:

```
gw-fxci-gcp-l1-2404-amd64-headless-googlecompute-2026-05-04
gw-fxci-gcp-l3-2404-amd64-headless-googlecompute-2026-05-04
gw-fxci-gcp-l1-2404-arm64-headless-googlecompute-2026-05-04
```

Decoding the segments:

| Segment | Meaning |
|---|---|
| `gw-fxci-gcp` | Generic worker, Firefox CI on GCP |
| `l1` / `l3` | Trust level. `l1` = level-1/untrusted; `l3` = level-3/trusted (only emitted from `trusted-*` configs). |
| `2404` | Ubuntu 24.04 LTS |
| `amd64` / `arm64` | Architecture |
| `headless` / `gui` | Compositor flavor (headless for builds; gui/wayland for GUI tests) |
| `googlecompute` | Packer builder |
| `2026-05-04` | Build date — the part that changes per rollout |

Alpha builds use `-alpha` instead of a date suffix and are pinned to
fxci-config's alpha entries.

## GCP projects

| Project | Trust level | Used by |
|---|---|---|
| `taskcluster-imaging` | level-1 | `fxci-level1-gcp` references in `worker-images.yml` |
| `fxci-production-level3-workers` | level-3 | `fxci-level3-gcp` references |

A production rollout for headless typically updates **both** projects
because the level-3 trusted variant is built alongside the level-1 one.
Wayland/GUI images currently only ship at level-1.

## Triggering builds

The most efficient path for a full Linux rollout is the parallel
workflow, which discovers configs by glob (`^(trusted-)?gw-fxci-gcp-.*-alpha$`)
and builds all production images in one matrix run:

```bash
gh workflow run "FXCI - GCP Prod Parallel Images" \
  --repo mozilla-platform-ops/worker-images
```

For a single config rebuild (e.g. when only headless needs a hotfix):

```bash
gh workflow run "FXCI - GCP Production" \
  --repo mozilla-platform-ops/worker-images \
  -f config=gw-fxci-gcp-l1-2404-headless-alpha
```

Note: even though the config name carries `-alpha`, the `Production`
workflow promotes the resulting image into the production project with a
date-stamped name. This naming quirk is historical.

## Finding the published image name

After the build finishes, grep the deploy job log for the line where
Packer reports the published image. The exact pattern varies between
builders, but:

```bash
gh run view --job <JOB_ID> --repo mozilla-platform-ops/worker-images \
  --log 2>&1 | grep -E "(googlecompute|image_name|Image Name)"
```

A more reliable shortcut: the date is the date of the run. If the run
landed on 2026-05-04 UTC and the build job succeeded, the image will be
named with `googlecompute-2026-05-04`. Confirm by listing the project's
images with `gcloud compute images list` (requires the `taskcluster-
imaging` / `fxci-production-level3-workers` projects):

```bash
gcloud compute images list \
  --project=taskcluster-imaging \
  --filter="name~'gw-fxci-gcp-l1-2404-amd64-headless-googlecompute-2026-05-04'"
```

## Updating fxci-config

Linux entries in `worker-images.yml` are direct image-path references —
no `version`/`deployment_id` fields. Replace the trailing date segment:

```yaml
ubuntu-2404-headless:
  ## Headless Image for Ubuntu 24.04
  fxci-level1-gcp: projects/taskcluster-imaging/global/images/gw-fxci-gcp-l1-2404-amd64-headless-googlecompute-2026-05-04
  fxci-level3-gcp: projects/fxci-production-level3-workers/global/images/gw-fxci-gcp-l3-2404-amd64-headless-googlecompute-2026-05-04
```

Touch only the entries that map to images you actually rebuilt — leave
`*-alpha`, `relsre-*`, and `monopacker-*` references alone unless asked.

## PR body format

Linux PRs are shorter than Windows because there's no ronin_puppet
deploymentId table to provide. Stick to:

1. **Summary** — which Ubuntu families bumped to which date, plus any
   security/stability driver (CVE, RELOPS ticket).
2. **Build provenance** — link the worker-images run, build SHA, and at least
   one production SBOM from the rollout. For a full Ubuntu 24.04 rollout, use
   the Wayland AMD64 SBOM as the primary link.
3. **Related** — Jira/GitHub link.

PR #968 (`feat(gcp): Update Ubuntu 24.04 images with copy-fail patch`) is
a good template — short, security context up top, related ticket at the
bottom.

## Common pitfalls

- **Mismatched dates between level-1 and level-3.** If the parallel build
  partially failed, the trusted (`l3`) image may carry a different date
  than the untrusted (`l1`) image. Don't paper over it in fxci-config —
  retrigger the failing job until both projects have matching dates, or
  call out the divergence explicitly.
- **Wayland (gui) images.** `ubuntu-2404-wayland` only has a
  `fxci-level1-gcp` reference today; don't add a `fxci-level3-gcp` line
  unless someone has shipped a level-3 wayland image.
- **`relsre-*` and `monopacker-*` entries are alpha-equivalent.** They
  are pinned to `-alpha` image names by design so RelSRE can iterate on
  them. Leave them out of a prod rollout PR.
