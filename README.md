# agent-skills

Claude Code skills for the Mozilla RelOps team. Each skill gives agents the context and tooling to work with Mozilla's telemetry, CI, and infrastructure systems.

## Installation

Install all skills:

```bash
npx skills add mozilla-platform-ops/agent-skills
```

Install a specific skill:

```bash
npx skills add mozilla-platform-ops/agent-skills/<skill-name>
```

## Available Skills

| Skill | Description |
|-------|-------------|
| [production-image-deploy](skills/production-image-deploy/) | Deploy a Firefox CI worker image end-to-end: trigger the worker-images Action build, verify the published artifact, then bump `worker-images.yml` in fxci-config and open the rollout PR. Covers Windows (Azure SIG, semver-versioned) and Linux (GCP, date-stamped images). |
| [queue-diagnosis](skills/queue-diagnosis/) | Diagnose large Taskcluster worker-pool queues by combining live Taskcluster pool state with Redash/BigQuery demand analysis. Produces a supply-side, demand-side, mixed, or inconclusive verdict with supporting evidence. |
| [redash](skills/redash/) | Query Mozilla's Redash (sql.telemetry.mozilla.org) for Firefox telemetry and FXCI task data. Covers OS version distribution, DAU/MAU, architecture breakdown, worker-pool queue time, and task-level CI analysis. Requires only a Redash API key. |
| [win-hw-troubleshooting](skills/win-hw-troubleshooting/) | Triage Firefox CI Windows hardware fleet issues (NUC13 / MDC1 / `releng-hardware/win11-64-24h2-hw*`). Covers PSU degradation detection via fleetbench, Kernel-Processor-Power event analysis, WdFilter / Defender Tamper-Protection mechanics, the perf-debug / alpha / main pool topology, and the hardware-vs-code-vs-environment disambiguation playbook for Speedometer 3 regressions. |

## Adding New Skills

1. Create `skills/<skill-name>/` directory
2. Add `SKILL.md` with YAML frontmatter (`name` and `description`)
3. Add optional `references/`, `scripts/`, or `assets/` subdirectories
4. Update this README's Available Skills table
5. Test with `npx skills add`

## License

MPL-2.0 except where noted. Individual skills may use different licenses; check the LICENSE file in each skill directory.

## Links

- [Claude Code docs](https://docs.anthropic.com/en/docs/claude-code)
- [Mozilla Platform Operations](https://github.com/mozilla-platform-ops)
