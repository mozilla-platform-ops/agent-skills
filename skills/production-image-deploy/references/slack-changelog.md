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

Resolve every `<V>` and `<PR_NUMBER>` placeholder before sending.
Leave URLs bare; don't use Slack's "code block" formatting.

### Getting bullets to render

Slack's auto-detection of `•` and `- ` is inconsistent across paste
contexts. A plain-text changelog will sometimes render bullets as
literal characters. `textutil ... | pbcopy -Prefer rtf` puts RTF on
the clipboard but no plain-text fallback, and Slack's editor
sometimes drops to plain-text mode in which case the RTF is
discarded.

The reliable pattern is to put **both** HTML and plain text on the
clipboard simultaneously via PyObjC. Slack picks the format it can
render; the plain-text fallback covers the case where it can't.

Fill in `bullets`, `links`, and `PR`, save as `/tmp/slack-clip.py`, and run
`uv run --script /tmp/slack-clip.py`. It builds the whole post (header,
bullets, PR link, release-notes URLs) for both clipboard formats from one
source, so they stay in sync:

```python
# /// script
# requires-python = ">=3.10"
# dependencies = ["pyobjc-framework-Cocoa"]
# ///
from AppKit import NSPasteboard, NSPasteboardTypeHTML, NSPasteboardTypeString

BASE = "https://github.com/mozilla-platform-ops/worker-images/blob/main/sboms"
PR = "https://github.com/mozilla-releng/fxci-config/pull/<PR_NUMBER>"

# One bullet per Windows-relevant change in the ronin_puppet commit range.
# Don't drop one: a single rollout often ships several (e.g. for 82415f4 it
# was VBCABLE pack 45, NetFx3/DXSDK removal on ARM64, AND the cache-workaround
# removal). Source them from the commit range, not just the headline ticket.
bullets = [
    "VB-CABLE (pack 45) replaces Virtual Audio Cable on Azure Windows workers",
    "NetFx3 and the DirectX SDK removed from ARM64 builders",
    "Removed legacy Windows cache workarounds (cache paths now read from the worker environment)",
]

# (Slack friendly label, sbom filename without .md) -- only the rebuilt configs.
links = [
    ("Win10 22H2", "win10-64-2009-1.3.5"),
    ("Win11 24H2 x64", "win11-64-24h2-1.3.5"),
    ("Win11 25H2 x64", "win11-64-25h2-1.0.5"),
    ("Win11 25H2 aarch64", "win11-a64-25h2-tester-1.0.5"),
    ("Win11 25H2 aarch64 L1 Builder", "win11-a64-25h2-builder-1.0.5"),
    ("Win11 25H2 aarch64 L3 Builder", "trusted-win11-a64-25h2-builder-1.0.5"),
    ("Win2022 L1 Builder", "win2022-64-2009-1.3.5"),
    ("Win2022 L3 Builder", "trusted-win2022-64-2009-1.3.5"),
]

# "Latest windows updates" is a plain line directly above the bullets -- do NOT
# bold it; it reads as part of the bullet block.
plain_lines = ["We've updated all windows cloud images. See changelog below:", "", "", "Latest windows updates"]
plain_lines += [f"- {b}" for b in bullets]
plain_lines += ["", "", f"Link to fxci-config PR {PR}", "", "Release Notes:", ""]
plain_lines += [f"{label}: {BASE}/{fn}.md" for label, fn in links]
plain = "\n".join(plain_lines) + "\n"

html_parts = ["We've updated all windows cloud images. See changelog below:<br><br>", "Latest windows updates", "<ul>"]
html_parts += [f"<li>{b}</li>" for b in bullets]
html_parts += ["</ul>", f"Link to fxci-config PR {PR}<br><br>", "Release Notes:<br><br>"]
html_parts += [f"{label}: {BASE}/{fn}.md<br>" for label, fn in links]
html = "".join(html_parts)

pb = NSPasteboard.generalPasteboard()
pb.clearContents()
pb.setString_forType_(html, NSPasteboardTypeHTML)
pb.setString_forType_(plain, NSPasteboardTypeString)
print("copied to clipboard (HTML + plain)")
```

The URL list at the bottom stays plain text in both formats; Slack
auto-links bare URLs in either mode.

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
