# agent-skills

Claude Code skills for the Mozilla RelOps team — custom workflows, tools, and integrations for querying telemetry, managing CI, and automating infrastructure tasks.

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
| [bigquery](skills/bigquery/) | Query Mozilla telemetry data via the `bq` CLI — DAU/MAU, OS version distribution, Glean metrics |

## Adding New Skills

1. Create `skills/<skill-name>/` directory
2. Add `SKILL.md` with YAML frontmatter (`name` and `description`)
3. Add optional `references/`, `scripts/`, or `assets/` subdirectories
4. Update this README's Available Skills table
5. Test with `npx skills add`

## License

MPL-2.0 except where noted. Individual skills may use different licenses — check the LICENSE file in each skill directory.

## Links

- [Claude Code docs](https://docs.anthropic.com/en/docs/claude-code)
- [Mozilla Platform Operations](https://github.com/mozilla-platform-ops)
