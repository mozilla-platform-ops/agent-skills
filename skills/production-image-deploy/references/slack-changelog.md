# Slack changelog

After the fxci-config PR merges, post a changelog in the team channel so
people running CI know which images flipped. The post needs to be
copy-pasteable and link directly to the published artifacts — readers
should not have to hunt through the merge commit to figure out what
shipped.

Don't post until the fxci-config PR is **merged**. SBOM URLs below point
to `worker-images/main` (after the SBOM-upload job committed); a draft
changelog posted before merge will link to URLs that may still 404.

## Windows

### Template

```
We've updated all windows cloud images. See changelog below:


Latest windows updates
<bullet — top-line driver, e.g. "Taskcluster <gw_version> generic worker">
<bullet — secondary change, e.g. "Azure VM Agent update">
<add or remove bullets as needed; 2–4 is the right ballpark>


Link to fxci-config PR https://github.com/mozilla-releng/fxci-config/pull/<PR_NUMBER>

Release Notes:

Win10 22H2: https://github.com/mozilla-platform-ops/worker-images/blob/main/sboms/win10-64-2009-<V>.md
Win11 24H2 x64: https://github.com/mozilla-platform-ops/worker-images/blob/main/sboms/win11-64-24h2-<V>.md
Win11 25H2 x64: https://github.com/mozilla-platform-ops/worker-images/blob/main/sboms/win11-64-25h2-<V>.md
Win11 24H2 aarch64: https://github.com/mozilla-platform-ops/worker-images/blob/main/sboms/win11-a64-24h2-tester-<V>.md
Win11 25H2 aarch64: https://github.com/mozilla-platform-ops/worker-images/blob/main/sboms/win11-a64-25h2-tester-<V>.md
Win11 24H2 aarch64 L1 Builder: https://github.com/mozilla-platform-ops/worker-images/blob/main/sboms/win11-a64-24h2-builder-<V>.md
Win11 25H2 aarch64 L1 Builder: https://github.com/mozilla-platform-ops/worker-images/blob/main/sboms/win11-a64-25h2-builder-<V>.md
Win11 24H2 aarch64 L3 Builder: https://github.com/mozilla-platform-ops/worker-images/blob/main/sboms/trusted-win11-a64-24h2-builder-<V>.md
Win11 25H2 aarch64 L3 Builder: https://github.com/mozilla-platform-ops/worker-images/blob/main/sboms/trusted-win11-a64-25h2-builder-<V>.md
Win2022 L1 Builder: https://github.com/mozilla-platform-ops/worker-images/blob/main/sboms/win2022-64-2009-<V>.md
Win2022 L3 Builder: https://github.com/mozilla-platform-ops/worker-images/blob/main/sboms/trusted-win2022-64-2009-<V>.md
```

### Friendly-name mapping

The Slack post uses release-engineering-friendly OS names. Substitute
the SBOM URL using the worker-images config name + the actual published
version:

| Slack label | worker-images config | Notes |
|---|---|---|
| Win10 22H2 | `win10-64-2009` | |
| Win11 22H2 | `win11-64-2009` | Drop this line if `win11-64-2009` was retired from `windows_production_defaults.yaml`. |
| Win11 24H2 x64 | `win11-64-24h2` | |
| Win11 25H2 x64 | `win11-64-25h2` | |
| Win11 24H2 aarch64 | `win11-a64-24h2-tester` | |
| Win11 25H2 aarch64 | `win11-a64-25h2-tester` | |
| Win11 24H2 aarch64 L1 Builder | `win11-a64-24h2-builder` | |
| Win11 25H2 aarch64 L1 Builder | `win11-a64-25h2-builder` | |
| Win11 24H2 aarch64 L3 Builder | `trusted-win11-a64-24h2-builder` | |
| Win11 25H2 aarch64 L3 Builder | `trusted-win11-a64-25h2-builder` | |
| Win2022 L1 Builder | `win2022-64-2009` | |
| Win2022 L3 Builder | `trusted-win2022-64-2009` | |

### Rules for trimming the list

- **Only include configs that were actually rebuilt in this rollout.**
  If a hotfix only touched two configs, the changelog should list only
  those two.
- **Verify each URL resolves before posting.** The most common cause of
  a 404 is the `Upload release notes` job racing with another commit
  and skipping a SBOM (PR
  [#982](https://github.com/mozilla-releng/fxci-config/pull/982) hit
  this for `trusted-win11-a64-25h2-builder`). If a SBOM didn't land,
  either rerun the SBOM-upload step or note in Slack that the image
  shipped without a SBOM (`(SBOM pending — image is live in SIG at
  vX.Y.Z)`).
- **Pull `<V>` from the actual published version**, not from a previous
  rollout's number. Phase-2 verification should already have these
  values in hand.
- **The "Latest windows updates" bullets describe what changed**, not
  the bump itself. Source them from the ronin_puppet commit range and
  the gw/livelog versions in the SBOM (e.g. "Taskcluster 99.2.0 generic
  worker", "Azure VM Agent update", "Mozilla Build 4.1"). Skip generic
  filler like "various improvements".

### Producing the post

Resolve every `<V>` and `<PR_NUMBER>` placeholder before sending. The
changelog is meant to be plain text in Slack — no Markdown rendering —
so leave the URLs bare. Don't use Slack's "code block" formatting; the
team posts these as regular messages.

## Linux

Linux currently has no SBOMs in `worker-images/sboms/`, so the
changelog can't link per-image release notes. Use a shorter variant
that points at the fxci-config PR plus the worker-images run:

```
We've updated the Ubuntu 24.04 GCP worker images. See changelog below:


Latest linux updates
<bullet — top-line driver, e.g. "May 2026 patch level + 99.2.1 generic worker">
<bullet — any second item, e.g. "Headless + ARM64 + Wayland flavors">


Link to fxci-config PR https://github.com/mozilla-releng/fxci-config/pull/<PR_NUMBER>
worker-images run: https://github.com/mozilla-platform-ops/worker-images/actions/runs/<RUN_ID>
Updated images: <YYYY-MM-DD> builds for <list of fxci-config aliases>
```

If/when Linux gets SBOM emission, fall back to the Windows-style
per-image link list.
