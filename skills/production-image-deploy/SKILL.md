---
name: production-image-deploy
description: >
  Use when rolling a new Firefox CI worker image to production: worker-images
  build, fxci-config worker-images.yml bump, integration checks, Slack
  changelog, post-merge pool health, and Bugzilla record. DO NOT USE FOR
  build-only requests; use worker-image-build.
---

# Production image deploy

## Prerequisites

`gh` (member of worker-images `.github/relsre.json`), `az`, `tc-logview`, and
the `jira`, `bugzilla`, and `humanizer` skills.

## Usage

Work the phases in order. Skip phase 1 if the build already ran. Phase 5
always runs. Phases 0 and 6 apply to Windows production rollouts. Read the
listed reference before each phase.

0. Open the RELOPS tracking Story — references/tracking.md.
1. Dispatch builds, alpha before production — references/build-and-verify.md,
   references/windows.md, references/linux.md.
2. Verify the SIG version or GCE image and SBOM — references/build-and-verify.md.
3. Bump `worker-images.yml`, open the PR, comment `/taskcluster integration` —
   references/fxci-config-mapping.md, references/pr-templates.md.
4. After merge, post the changelog to `#relops` and `#firefox-ci-proj` —
   references/slack-changelog.md.
5. Confirm new workers boot the new image — references/post-merge-health.md.
6. File and resolve the Bugzilla deployment task — references/tracking.md.

## Gotchas

- Job badges lie both ways. The SIG version and SBOM are authoritative.
- Switching alpha configs to `sourceBranch: master` overwrites the feature
  branch under test. Confirm with the user first.
- Do not push to ronin_puppet or worker-images, or bump community-tc-config
  without asking.

## Related Skills

**worker-image-build** for builds alone, **os-integrations** and
**treeherder** for mach try validation, **queue-diagnosis** if pending climbs
after merge.
