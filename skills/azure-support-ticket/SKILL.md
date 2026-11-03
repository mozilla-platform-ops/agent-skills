---
name: azure-support-ticket
description: >
  Use when filing, bumping, or listing Azure support tickets, such as FXCI
  quota increases for Spot or dedicated cores, with the `az support
  in-subscription tickets` CLI. DO NOT USE FOR reading current quota; use
  `az vm list-usage`.
---

# azure-support-ticket

## Prerequisites

`uv` and `az`, logged in with access to the target subscription. The default
is Trusted FXCI (`a30e97ab-734a-4f3b-a0e4-c51c0bff0701`); pass
`--subscription` for others.

## Usage

Subcommands: `quota` (file a quota increase), `bump` (change severity),
`list`, and `show`.

```bash
uv run ~/.claude/skills/azure-support-ticket/scripts/file_ticket.py quota \
  --region southcentralus --quota-type LowPriorityCores \
  --new-limit 4000 --severity moderate \
  --reason "eastus2 has 20%+ Spot eviction on Standard_D32ads_v5 ..."
```

Add `--dry-run` to print the exact `az` command first. Severities:
`minimal` (Sev C, any plan), `moderate` (Sev B, Standard+), `critical`
(Sev A, ProDirect+).

Read [references/quota-recipes.md](references/quota-recipes.md) for
`bump` and per-family examples, service and problem-classification IDs,
payload formats, VM family names, the FXCI subscription map, and
troubleshooting.

## Gotchas

- Descriptions must be ASCII. The script normalizes common punctuation;
  `Description contains invalid characters` means a codepoint slipped past.
- `VMFamilyLowPriority` needs `--vm-family` with a real family name such as
  `standardDADSv5Family`.
- `bump` resolves the numeric `supportTicketId`, but only within the given
  `--subscription`.
- The script does not check the support plan before it submits.
