---
name: azure-support-ticket
description: |
  File and manage Azure support tickets via `az support in-subscription tickets`,
  with a focus on quota-increase requests for FXCI subscriptions. Handles the
  service/problem-classification IDs, the per-quota-type payload format, and
  the ASCII-only description rule that the underlying API silently enforces.
  Use whenever someone says "file a quota increase", "bump LowPriorityCores",
  "request more cores in <region>", "open an Azure support ticket", "raise sev
  on ticket", or needs to update / list / show an existing ticket. Defaults to
  the Trusted FXCI subscription but accepts any subscription via --subscription.
---

# Azure Support Ticket

Wraps `az support in-subscription tickets` so you can file an Azure quota
increase (or general support ticket) without rediscovering the service IDs,
payload formats, and quirks every time.

## When to use

- Spot/regular core quota is pegged in a region and you need to bump it
  before a launchConfig change ships
- Open a generic Azure support ticket against the current subscription
- Bump an existing ticket's severity, add a communication, or look up status

If you only need to see *current* quota, use `az vm list-usage --location
<region>` directly. This skill is for filing requests, not reading numbers.

## Prerequisites

- `az` CLI authenticated (`az login`) against the target tenant
- `support` extension installed (the script will add it if missing)
- The subscription must have a paid Azure Support plan for severity
  `moderate` (Sev B) or above. Sev C (`minimal`) works on every plan.

## Quick start: quota increase

The most common use:

```bash
uv run scripts/file_ticket.py quota \
  --subscription a30e97ab-734a-4f3b-a0e4-c51c0bff0701 \
  --region southcentralus \
  --new-limit 4000 \
  --quota-type LowPriorityCores \
  --severity moderate \
  --reason "eastus2 has 20%+ Spot eviction on Standard_D32ads_v5 ..."
```

The script:

1. Looks up the right service ID and problem classification for the quota type
2. Sanitizes the description to ASCII (the API rejects em-dashes and other
   high-codepoint characters with a vague `JsonDeserializationError`)
3. Constructs the `quotaChangeRequests` payload in the per-quota-type format
4. Pulls contact info from `az ad signed-in-user show` so you don't have
   to re-type it
5. Prints the ticket ID, status, and SLA window on success

Pass `--dry-run` to see the exact `az` command without filing.

## Quick start: bump severity on an existing ticket

```bash
uv run scripts/file_ticket.py bump \
  --subscription a30e97ab-734a-4f3b-a0e4-c51c0bff0701 \
  --ticket-name <ticket-resource-name> \
  --severity critical
```

`<ticket-resource-name>` is the resource name (`quota-southcentralus-...`),
not the display ticket ID (`2605180040009652`). Get it back from the create
response, or `uv run scripts/file_ticket.py list`.

## Quick start: list / show

```bash
uv run scripts/file_ticket.py list --subscription <sub>
uv run scripts/file_ticket.py show --subscription <sub> --ticket-name <name>
```

## Quota types supported

`--quota-type` accepts:

| Value | What it changes | Subtype | Example payload |
|---|---|---|---|
| `LowPriorityCores` | Regional total Low-priority (Spot) vCPUs | `Service` | `{VMFamily:lowPriority,NewLimit:4000,Type:LowPriority}` |
| `RegularCores` | Regional total dedicated vCPUs | `Service` | `{VMFamily:cores,NewLimit:200,Type:Dedicated}` |
| `VMFamilyCores` | Per-SKU-family dedicated cores (requires `--vm-family`) | `Service` | `{VMFamily:standardDADSv5Family,NewLimit:200,Type:Dedicated}` |
| `VMFamilyLowPriority` | Per-SKU-family Spot cores (requires `--vm-family`) | `Service` | `{VMFamily:standardDADSv5Family,NewLimit:200,Type:LowPriority}` |

See `references/quota-recipes.md` for additional service IDs (Batch,
ML, SQL, Cosmos, Synapse) and how to extend the script.

## Severities

| Flag | Display | Support plan required |
|---|---|---|
| `minimal` | Sev C | Any (Free / Developer / Standard / ProDirect / Premier) |
| `moderate` | Sev B | Standard or higher |
| `critical` | Sev A | ProDirect or higher |
| `highestcriticalimpact` | Sev 0 | Premier only |

## Conventions

- Default subscription: Trusted FXCI (`a30e97ab-...`). All FXCI subs are
  listed in `references/quota-recipes.md`.
- Default contact method: email, language en-us, country USA, timezone
  Pacific Standard Time. Override per call if needed.
- Ticket-name uses the pattern `<purpose>-<region>-<quota-type>-<new-limit>-<timestamp>`
  to keep ticket names self-describing and unique without manual input.

## Common pitfalls

- **`JsonDeserializationError: Description contains invalid characters`** —
  the API rejects high-codepoint characters silently. The script
  normalizes to ASCII (em-dash, en-dash, curly quotes, ellipsis) before
  submission. If you pass `--reason` from a copy-paste that contains
  other Unicode, expect a re-encode warning.
- **`The selected subscription has an Azure support plan that doesn't
  allow this severity`** — fall back to `--severity minimal` or upgrade
  the support plan.
- **`InvalidParameterValue` on `quotaChangeRequests`** — the payload is
  service-specific. For Compute-VM, `VMFamily` is required even when
  you mean the regional total (use `lowPriority` for the Spot total,
  `cores` for the dedicated total). See `references/quota-recipes.md`.
- **`update --severity` doesn't change every field** — the underlying
  `Update` REST call accepts severity, status, and the communication
  body, but not the description. To change the description, add a
  communication instead (`az support in-subscription communication
  create`).
