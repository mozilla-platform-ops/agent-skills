# Tracking issues: JIRA Story + Bugzilla bug

Every production Windows image rollout gets two tracking issues, filed before
the build starts. Run both descriptions through `/humanizer`.

## RELOPS tracking Story (JIRA)

Use the `jira` skill (`scripts/extract_jira.py`).

- **Type:** `Story` (`--issue-type-create Story`). Self-report/assign.
- **Summary:** `Update Windows worker images to <untrusted_ver> / <25h2_ver>`
  (e.g. `Update Windows worker images to 1.3.5 / 1.0.5`). Prior examples:
  RELOPS-2329, RELOPS-2453.
- **Epic:** file under the current period's `[YYYY HX] Win 10/11 Support and
  Deployments: Cloud and Hardware` epic (`--set-epic`), where prior rollout
  Stories live — RELOPS-2047 for 2026 H1. A new epic is cut each half/quarter;
  pick the open one (don't leave the Story epic-less).
- **Description:** "Build and deploy new versions of all production Windows
  worker images", then the version bumps (which images inherit the
  prod-defaults bump vs the explicit 25h2/ARM64 overrides), the ronin_puppet
  commit range, and a Work checklist mirroring phases 1–5.
- **Link the underlying RELOPS stories.** The ronin_puppet PRs merged into the
  target `deploymentId` carry their own RELOPS tickets; find them from the
  commit range and link each (`--link-issue`). Example for `82415f4`:
  `gh api repos/mozilla-platform-ops/ronin_puppet/compare/<prev>...<new> --jq '.commits[].commit.message'`
  surfaced RELOPS-2437 (VBCABLE) and RELOPS-2449 (NetFx3/DXSDK skip). Skip
  commits with no RELOPS ref or that aren't Windows-relevant.
- **Drive the status:** `Backlog → In Progress` when you start the build,
  `→ Done` after the fxci-config PR merges and phase-5 health check passes.

This Story is the umbrella; reference it (`RELOPS-####`) in the worker-images
and fxci-config PRs.

## Companion Bugzilla bug

RELOPS tracks the rollout in JIRA, but each deployment also gets a Bugzilla bug
so it shows up in the BMO RelOps queue. File it alongside the Story with the
`bugzilla` skill (`scripts/bz.py create`):

- **Product / Component:** `Infrastructure & Operations` / `RelOps: Windows OS`
  (not the `create-image-regression` default of `Infrastructure & Release
  Engineering` / `General` — that template is for regressions, not rollouts).
- **Type:** `task` (`-t task`). BMO rejects a create with no type; the `create`
  subcommand defaults to `task` for exactly this case.
- **Version:** `other` (this product carries no per-release versions).
- **Summary:** mirror the Story — `Update Windows worker images to <ver> /
  <ver> (ronin_puppet <short-sha>)`.
- **Description:** reuse the Story body (version bumps, ronin_puppet commit
  range, PR list). Put the Story URL at the top. **Write every reference as a
  full URL** — BMO comments are plain text and only auto-link bare URLs and
  `Bug ####`; shorthand like `worker-images#817`, `fxci-config#1058`, or
  `RELOPS-2449` stays unlinked. Use `https://github.com/<org>/<repo>/pull/<n>`
  and `https://mozilla-hub.atlassian.net/browse/RELOPS-####` instead. Get this
  right on the first post: BMO's REST API can't edit comment 0 afterward
  (`PUT /bug/comment/{id}` returns 404), so a follow-up comment is the only fix
  for a description with dead shorthand.
- **Cross-link both ways:** `--see-also <RELOPS Story URL>` on the bug, then
  `extract_jira.py --modify <STORY> --add-comment` with the bug URL — the
  `see_also` link is one-directional, so the JIRA backlink is manual. Write the
  JIRA comment in Markdown link syntax
  (`[Bug 2050308](https://bugzilla.mozilla.org/show_bug.cgi?id=2050308)`) so
  the skill's Markdown→ADF conversion renders a clickable link, not a bare URL.

Example for the 82415f4 rollout:
[Bug 2050308](https://bugzilla.mozilla.org/show_bug.cgi?id=2050308) ↔
[RELOPS-2453](https://mozilla-hub.atlassian.net/browse/RELOPS-2453).
