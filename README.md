# agent-skills

Claude Code skills for the Mozilla RelOps team. Each skill gives agents the context and tooling to work with Mozilla's telemetry, CI, and infrastructure systems.

## Available Skills

| Skill | Description |
|-------|-------------|
| [azure-cost-analysis](skills/azure-cost-analysis/) | Analyze FXCI Azure CI costs across the 3 CI subscriptions (FXCI DevTest, Trusted FXCI, TC Engineering). Investigate cost changes by worker pool, SKU, region, or service. Distinguishes volume-driven changes from rate changes, correlates with Taskcluster task volume, and checks fxci-config for cost-relevant changes. |
| [firefox-ci-test-coverage-by-platform](skills/firefox-ci-test-coverage-by-platform/) | Query Firefox CI test health: tier classification, skip rates, coverage gaps, and platform comparisons. Use when analyzing which tests matter on which platforms, planning OS pool migrations, or investigating test coverage gaps. |
| [redash](skills/redash/) | Query Mozilla's Redash (sql.telemetry.mozilla.org) for Firefox telemetry and FXCI task data. Covers OS version distribution, DAU/MAU, architecture breakdown, worker-pool queue time, and task-level CI analysis. |

## Installation

Skills are installed with [`npx skills`](https://github.com/vercel-labs/skills), which clones the repo into `~/.agents/skills/` and symlinks each skill into the directory your agent reads from.

### Prerequisites

Both platforms need:

- **Node.js 18+** — provides `npx` for the skills installer
- **Git** — required by `npx skills` to clone source repos

Some skills have additional runtime dependencies (Python, the `bq` CLI, a Redash API key, etc.). Check the individual `SKILL.md` for requirements before using a skill.

### macOS

```bash
brew install node git
npx skills add mozilla-platform-ops/agent-skills -g --agent '*' -y
```

### Windows

In an elevated PowerShell (install [Chocolatey](https://chocolatey.org/install) first if needed):

```powershell
choco install -y nodejs-lts git
npx skills add mozilla-platform-ops/agent-skills -g --agent '*' -y
```

### Installing a single skill

```bash
npx skills add mozilla-platform-ops/agent-skills -g --skill <skill-name> --agent '*' -y
```

### Updating

```bash
npx skills check -g    # see what has updates available
npx skills update -g   # pull latest from source repos
```

### Removing

```bash
npx skills remove <skill-name> -g -y
```

## Adding a New Skill

1. Create the skill directory: `skills/<skill-name>/`
2. Add `SKILL.md` with YAML frontmatter — at minimum a `name` and `description`. The description controls when the agent invokes the skill, so be specific about triggers.
3. Add optional subdirectories:
   - `references/` — markdown knowledge the skill loads on demand
   - `scripts/` — executable helpers the skill can run
   - `assets/` — static files (templates, schemas, fixtures)
4. Update the **Available Skills** table in this README.
5. Commit and push to `main` — `npx skills` clones from GitHub, so unpushed skills are invisible to the installer.
6. Test the install end-to-end:

   ```bash
   npx skills add mozilla-platform-ops/agent-skills -g --skill <skill-name> --agent '*' -y
   ```

For deeper guidance on skill structure, frontmatter conventions, and the reference-file pattern, see the [`writing-skills`](https://github.com/jwmossmoz/agent-skills/tree/main/skills/writing-skills) and [`skill-creator`](https://github.com/anthropics/skills/tree/main/skill-creator) skills.

## License

MPL-2.0 except where noted. Individual skills may use different licenses; check the LICENSE file in each skill directory.

## Links

- [Claude Code docs](https://docs.anthropic.com/en/docs/claude-code)
- [`npx skills` (vercel-labs/skills)](https://github.com/vercel-labs/skills)
- [Mozilla Platform Operations](https://github.com/mozilla-platform-ops)
