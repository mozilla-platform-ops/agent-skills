# Tracking: JIRA Story and Bugzilla deployment record

Every production Windows image rollout gets two records at different points:

1. File the RELOPS Story before the build starts. It defines the planned work.
2. File the Bugzilla deployment task after the merged rollout passes the
   post-merge health check. It records what reached production and gives later
   regressions a stable cause to reference.

Run both descriptions through `/humanizer`.

## RELOPS tracking Story (JIRA)

Use the `jira` skill (`scripts/extract_jira.py`).

- **Type:** `Story` (`--issue-type-create Story`). Self-report/assign.
- **Summary:** match the planned scope. Use `Update Windows worker images to
  <untrusted_ver> / <25h2_ver>` for a fleet rollout, or name the one image or
  pool family for a partial rollout. Prior fleet examples: RELOPS-2329 and
  RELOPS-2453.
- **Epic:** file under the current period's `[YYYY HX] Win 10/11 Support and
  Deployments: Cloud and Hardware` epic (`--set-epic`), where prior rollout
  Stories live — RELOPS-2047 for 2026 H1. A new epic is cut each half/quarter;
  pick the open one (don't leave the Story epic-less).
- **Description:** state the exact production scope, then list the version
  bumps, ronin_puppet commit range, and a Work checklist mirroring phases 1–6.
- **Link the underlying RELOPS stories.** The ronin_puppet PRs merged into the
  target `deploymentId` carry their own RELOPS tickets; find them from the
  commit range and link each (`--link-issue`). Example for `82415f4`:
  `gh api repos/mozilla-platform-ops/ronin_puppet/compare/<prev>...<new> --jq '.commits[].commit.message'`
  surfaced RELOPS-2437 (VBCABLE) and RELOPS-2449 (NetFx3/DXSDK skip). Skip
  commits with no RELOPS ref or that aren't Windows-relevant.
- **Drive the status:** `Backlog → In Progress` when you start the build. Move
  it to `Done` after the phase-5 health check passes and the phase-6 Bugzilla
  deployment record is cross-linked.

This Story is the umbrella; reference it (`RELOPS-####`) in the worker-images
and fxci-config PRs.

## Final Bugzilla deployment record

RELOPS tracks the work plan in JIRA. After deployment, file a Bugzilla task so
the result appears in the BMO RelOps queue and later regressions can identify
the deployment that caused them. Use the `bugzilla` skill
(`scripts/bz.py create`) only after the merged rollout passes phase 5.

- **Product / Component:** `Infrastructure & Operations` / `RelOps: Windows OS`
  (not the `create-image-regression` default of `Infrastructure & Release
  Engineering` / `General` — that template is for regressions, not rollouts).
- **Type:** `task` (`-t task`). BMO rejects a create with no type; the `create`
  subcommand defaults to `task` for exactly this case.
- **Version:** `other` (this product carries no per-release versions).
- **Summary:** match what reached production. For example:
  - Fleet rollout: `Update Windows worker images to 1.3.5 / 1.0.5
    (ronin_puppet 82415f4)`.
  - Partial rollout: `Update Windows 11 25H2 production workers to image
    1.0.6 and Standard_F8alds_v7`.
- **Description:** put the Story URL at the top, then record the exact image
  and pool scope, version and ronin_puppet `deploymentId`, worker-images build
  and PR, merged fxci-config PR, and validation results. Include only images
  that reached production. **Write every reference as a full URL** — BMO
  comments are plain text and only auto-link bare URLs and `Bug ####`;
  shorthand like `worker-images#817`, `fxci-config#1058`, or `RELOPS-2449`
  stays unlinked. Get this right on the first post: BMO's REST API can't edit
  comment 0 afterward (`PUT /bug/comment/{id}` returns 404), so a follow-up
  comment is the only fix for a description with dead shorthand.
- **Cross-link both ways:** `--see-also <RELOPS Story URL>` on the bug, then
  `extract_jira.py --modify <STORY> --add-comment` with the bug URL — the
  `see_also` link is one-directional, so the JIRA backlink is manual. Write the
  JIRA comment in Markdown link syntax
  (`[Bug 2050308](https://bugzilla.mozilla.org/show_bug.cgi?id=2050308)`) so
  the skill's Markdown→ADF conversion renders a clickable link, not a bare URL.
- **Close the deployment task:** assign it to yourself and resolve it as
  `FIXED` after the cross-links are present. The task records a completed
  deployment; it does not stay open as an umbrella.
- **Link later regressions:** on each issue caused by the rollout, set this
  deployment task in **Regressed by**. Bugzilla will show those issues in the
  deployment task's **Regressions** field. Do not link known failures that
  also occurred on the previous production image.

Create with a description file so shell quoting cannot damage URLs or
backticks:

```bash
BZ=~/.claude/skills/bugzilla/scripts/bz.py
uv run "$BZ" create \
  --product "Infrastructure & Operations" \
  --component "RelOps: Windows OS" \
  --type task \
  --version other \
  --summary "<scope-specific deployment summary>" \
  --description-file /tmp/windows-image-deployment.txt \
  --severity S3 \
  --priority P3 \
  --assignee "<your Bugzilla email>" \
  --see-also "https://mozilla-hub.atlassian.net/browse/RELOPS-####"
```

After the JIRA backlink is present:

```bash
uv run "$BZ" update <BUG_ID> --status RESOLVED --resolution FIXED
```

Example for the completed 82415f4 rollout:
[Bug 2050308](https://bugzilla.mozilla.org/show_bug.cgi?id=2050308) ↔
[RELOPS-2453](https://mozilla-hub.atlassian.net/browse/RELOPS-2453).
