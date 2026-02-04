# Mozilla Platform Operations Skills

Claude Code skills for the Mozilla RelOps team.

## Installation

Install all skills:

```bash
npx skills add mozilla-platform-ops/skills
```

Install specific skills:

```bash
npx skills add mozilla-platform-ops/skills/skill-creator
```

## Available skills

### skill-creator

Creates new skills using Anthropic's template and validation scripts.

Invoke with `/skill-creator`

Includes:
- Workflow templates
- Pattern guidelines
- Validation scripts (Python)
- Packaging utilities

## Adding new skills

1. Run `/skill-creator` to design your skill
2. Create `skills/<skill-name>/` directory
3. Add `SKILL.md` file (required - this is how npx discovers skills)
4. Include LICENSE if different from MPL-2.0
5. Update this README
6. Test with `npx skills add`

## License

MPL-2.0 except where noted.

Individual skills may use different licenses - check the LICENSE file in each skill directory.

## Links

- [Claude Code docs](https://docs.anthropic.com/claude/docs/claude-code)
- [Skills framework](https://github.com/vercel-labs/skills)
- [Mozilla Platform Operations](https://github.com/mozilla-platform-ops)
