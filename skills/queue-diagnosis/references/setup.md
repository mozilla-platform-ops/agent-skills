# Queue Diagnosis Setup

Read this when authentication fails or when you set up a new machine.

## Authentication

The script calls two external services. Both must be authenticated before
the skill can run.

### Taskcluster

The `taskcluster` CLI must be configured with credentials that have read
access to the worker-manager and queue APIs. Authentication is set via
environment variables:

- `TASKCLUSTER_ROOT_URL` — must be `https://firefox-ci-tc.services.mozilla.com`
- `TASKCLUSTER_CLIENT_ID` — your Taskcluster client ID
- `TASKCLUSTER_ACCESS_TOKEN` — your Taskcluster access token

These are typically configured in your shell profile or via
`taskcluster signin`. Verify with:

```bash
taskcluster api workerManager workerPool gecko-t/win11-64-25h2
```

### Redash (BigQuery)

The Redash queries require an API key for `sql.telemetry.mozilla.org`:

- `REDASH_API_KEY` — your personal Redash API key

To get a key: log in to [sql.telemetry.mozilla.org](https://sql.telemetry.mozilla.org),
go to your profile (top-right menu), and copy the API key. Verify with:

```bash
uv run ~/.claude/skills/redash/scripts/query_redash.py --sql "SELECT 1 AS test"
```

### Runtime dependencies

- `taskcluster` CLI (install via `pip install taskcluster` or download binary)
- `uv` (install via `curl -LsSf https://astral.sh/uv/install.sh | sh`)
- Redash skill installed at `~/.claude/skills/redash`
