# PR templates

These are skeletons. Fill placeholders with values resolved during phase
2 — never hardcode versions, hashes, or run IDs from a previous rollout.

Per team convention, **omit per-image bump tables and test-plan
sections**. Reviewers want a tight summary plus enough provenance to
audit; the diff itself is the source of truth for which entries moved.

## Windows rollout

**Branch name:** `bump-windows-images-<new-24h2-version>-<new-25h2-version>`
(e.g. when only one family is in scope, drop the second segment).

**Commit subject:** `chore(azure): bump windows <new-24h2-version> and win11 25h2 <new-25h2-version> image versions`

**PR body:**

```markdown
## Summary
- Bumps the **Windows 24H2 family** (plus Win10 22H2 and Windows Server 2022) to image version `<NEW_24H2>` and the **Win11 25H2 family** (testers and builders, including `trusted_win11_a64_25h2_builder`) to image version `<NEW_25H2>`. Both families now deploy from `ronin_puppet` `master` at commit [`<NEW_DEPLOYMENT_ID>`](https://github.com/mozilla-platform-ops/ronin_puppet/commit/<NEW_DEPLOYMENT_ID>) (`<NEW_RONIN_COMMIT_TITLE>`).
- **Taskcluster generic-worker** on Windows is at **`<GW_VERSION>`** across `GenericWorker`, `LiveLog`, `StartWorker`, and `Proxy`. <OPTIONAL_ROLLBACK_NOTE>
- Built by [worker-images run #<RUN_ID>](https://github.com/mozilla-platform-ops/worker-images/actions/runs/<RUN_ID>) against `worker-images@<WORKER_IMAGES_SHA>`.
- Follow-up to #<PRIOR_PR>.

## ronin_puppet commits

### Range (`<PREV_DEPLOYMENT_ID>...<NEW_DEPLOYMENT_ID>`) — Windows-relevant
| Commit | Description |
|---|---|
| [`<SHA>`](https://github.com/mozilla-platform-ops/ronin_puppet/commit/<SHA>) | <commit title> |
| ... | ... |

[Full compare](https://github.com/mozilla-platform-ops/ronin_puppet/compare/<PREV_DEPLOYMENT_ID>...<NEW_DEPLOYMENT_ID>)
```

If the 24H2 and 25H2 families came from the same prior `deploymentId`,
collapse to one Range table. If they differ, emit one table per range.

### Picking placeholder values

| Placeholder | How to find it |
|---|---|
| `<NEW_24H2>` / `<NEW_25H2>` | The `image_version` published by Packer (phase 2 grep on `SIG image version`). |
| `<NEW_DEPLOYMENT_ID>` | `vm.tags.deploymentId` in `worker-images/config/windows_production_defaults.yaml` at the build SHA. |
| `<NEW_RONIN_COMMIT_TITLE>` | `git -C ~/github_moz/ronin_puppet log -1 --pretty=%s <NEW_DEPLOYMENT_ID>`. |
| `<GW_VERSION>` | `version:` under the `taskcluster:` block in `ronin_puppet@<NEW_DEPLOYMENT_ID>:data/os/Windows.yaml`. |
| `<RUN_ID>` | The `databaseId` from `gh run list --workflow "FXCI - Azure Prod Parallel Images" --limit 1 --json databaseId`. |
| `<WORKER_IMAGES_SHA>` | `headSha` from the same `gh run list` query (or the SHA the run was triggered against). |
| `<PRIOR_PR>` | The fxci-config PR number for the previous rollout — usually visible from `git log -- worker-images.yml` in fxci-config. |

`<OPTIONAL_ROLLBACK_NOTE>`: include only if a generic-worker (or other
toolchain) version was reverted then restored inside the range. Phrase
it as a note for reviewers, e.g. "It was temporarily rolled back to
`<OLD>` in `<SHA>` for `<TICKET>` troubleshooting; this re-pins it."
Skip the sentence entirely if no rollback occurred.

## Linux rollout

**Branch name:** `bump-ubuntu-2404-<YYYY-MM-DD>` (or
`feat-update-ubuntu-2404-<topic>` for hotfixes with a story).

**Commit subject:** `feat(gcp): Update Ubuntu 24.04 images to <YYYY-MM-DD> builds`
(or `feat(gcp): Update Ubuntu 24.04 images with <topic>` if the bump is
named for a fix rather than a date).

**PR body:**

```markdown
## Summary

- Updates the Ubuntu 24.04 GCP worker image references to the `<YYYY-MM-DD>` builds for <list of touched fxci-config aliases>.
- <Optional 1-line driver: CVE, RELOPS ticket, "follow-up to #<n>", etc.>

## Build provenance

- worker-images run: https://github.com/mozilla-platform-ops/worker-images/actions/runs/<RUN_ID>
- worker-images SHA: `<SHA>`
- [Ubuntu 24.04 <flavor> SBOM](https://github.com/mozilla-platform-ops/worker-images/blob/main/sboms/<SBOM_FILENAME>.md)

## Related

- [<TICKET>](https://mozilla-hub.atlassian.net/browse/<TICKET>)
```

Linux PRs don't carry a ronin_puppet commit table because Linux images
don't bake a ronin_puppet `deploymentId`. They do carry at least one direct
SBOM link. For a full Ubuntu 24.04 rollout, use the Wayland AMD64 SBOM as the
primary link.

## House style reminders

- Plain factual language. Avoid "critical", "crucial", "robust",
  "comprehensive". A bug fix is a bug fix.
- Imperative mood, ≤72-char commit subject.
- Don't co-author with Claude.
- Run the user's `/humanizer` skill on multi-line commit messages and PR
  bodies if available.
