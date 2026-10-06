---
name: azure-cost-analysis
description: >
  Use when diagnosing FXCI Azure CI cost changes through the live Cost
  Management API: by worker pool, SKU, region, or subscription, volume versus
  rate, spot pricing, and evictions. DO NOT USE FOR the local DuckDB cost lake
  or GCP costs; use costctl.
---

# Azure Cost Analysis

## Prerequisites

`az` with read access to FXCI Azure DevTest (default), Trusted FXCI
(`a30e97ab-734a-4f3b-a0e4-c51c0bff0701`), and TC Engineering DevTest
(`8a205152-b25a-417f-a676-80465535a6c9`); Python 3.10+, `uv`, `curl` for
the Taskcluster API, and Redash access for
`taskclusteretl.derived_task_summary`.

## Usage

```bash
QC=~/.claude/skills/azure-cost-analysis/scripts/query_costs.py
uv run "$QC" --start 2026-01-01 --end 2026-03-31 --granularity monthly --compare-months
```

For a cost increase:

1. Read [references/user-inputs.md](references/user-inputs.md) and
   [references/methodology.md](references/methodology.md) to pick daily cost
   or cost per task as the signal.
2. Run `query_costs.py` per subscription, monthly and daily.
3. Use TC Engineering as the control. If it is flat, the change is
   CI-specific.
4. Correlate with task volume, then rule out config, service, spot price, and
   eviction changes.

Read [references/workflows.md](references/workflows.md) for flags and full
workflows, and [references/README.md](references/README.md) to pick a topic
reference. Standalone SQL lives in `queries/`.

## Gotchas

- Only FXCI DevTest has a cost export. Use the REST API for the other two.
- Bugs in worker-manager or worker-scanner can drive cost that fxci-config
  cannot explain.

## Related Skills

**costctl** for the local cost lake, **redash** for task counts.
