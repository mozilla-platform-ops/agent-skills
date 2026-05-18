---
name: azure-support-ticket
description: |
  Use when filing or updating an Azure support ticket. Wraps the `az
  support in-subscription tickets` CLI and encodes the per-quota-type
  payload format, service GUIDs, and ASCII-only description rule.
  Triggers on "file a quota increase", "bump LowPriorityCores",
  "request cores in a region", "open an Azure support ticket", "raise
  sev on ticket", or FXCI quota work.
---

# azure-support-ticket

File and manage Azure support tickets via the CLI without rediscovering
the service IDs, payload formats, and description quirks every time.

Use this skill for filing requests and updating ticket state. To read
current quota numbers, use `az vm list-usage` directly.

## Subcommands

```bash
uv run scripts/file_ticket.py quota   ...   # file a quota-increase ticket
uv run scripts/file_ticket.py bump    ...   # change severity on an existing ticket
uv run scripts/file_ticket.py list    ...   # list recent tickets
uv run scripts/file_ticket.py show    ...   # show one ticket
```

All subcommands accept `--subscription`; default is Trusted FXCI
(`a30e97ab-734a-4f3b-a0e4-c51c0bff0701`). Other FXCI subscriptions and
the full service-ID table are in
[references/quota-recipes.md](references/quota-recipes.md).

## Examples

File a Sev B LowPriorityCores bump in southcentralus:

```bash
uv run scripts/file_ticket.py quota \
  --region southcentralus \
  --quota-type LowPriorityCores \
  --new-limit 4000 \
  --severity moderate \
  --reason "eastus2 has 20%+ Spot eviction on Standard_D32ads_v5 ..."
```

Use `--dry-run` to inspect the exact `az` command before filing.

Bump an existing ticket to Sev A (accepts the resource name or the
display supportTicketId):

```bash
uv run scripts/file_ticket.py bump \
  --ticket-name 2605180040009652 \
  --severity critical
```

Per-SKU-family Spot quota (requires `--vm-family`):

```bash
uv run scripts/file_ticket.py quota \
  --region westus2 --quota-type VMFamilyLowPriority \
  --vm-family standardDADSv5Family --new-limit 200 \
  --severity moderate --reason "..."
```

## Severities

`minimal` (Sev C) works on every plan. `moderate` (Sev B) needs Standard
support or higher. `critical` (Sev A) needs ProDirect or higher. The
script does not validate the plan before submitting; if the plan
disallows the severity, the API returns a clear error.

## Troubleshooting

`JsonDeserializationError: Description contains invalid characters` -
the API rejects high-codepoint characters silently. The script
normalizes em-dashes, en-dashes, curly quotes, ellipsis, and
non-breaking spaces to ASCII, and drops anything else with a notice.
If you see this, your `--reason` body contains a codepoint the
sanitizer missed; re-encode and retry.

`ResourceNotFound` on `bump` - the previous ticket name doesn't exist
under the given subscription. Likely you passed the numeric display
`supportTicketId` from the create response. The script's `bump`
subcommand resolves the numeric form via `list` automatically, but if
the ticket was filed under a different subscription you must pass
`--subscription` explicitly.

`The selected subscription has an Azure support plan that doesn't
allow this severity` - downgrade with `--severity minimal`, or upgrade
the plan. See the severity table above.

`InvalidParameterValue` on `quotaChangeRequests` - the payload format
is per-quota-type. Re-check the recipe in
[references/quota-recipes.md](references/quota-recipes.md); the
common mistake is omitting `VMFamily` (use the literal `lowPriority`
or `cores` for the regional totals, real family names like
`standardDADSv5Family` for per-family).

## See also

[references/quota-recipes.md](references/quota-recipes.md) - service
IDs, problem-classification GUIDs, payload formats per quota type, VM
family names, FXCI subscription map, and the description sanitization
rules.
