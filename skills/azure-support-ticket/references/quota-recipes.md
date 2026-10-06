# Quota change recipes

Per-service service IDs, problem classifications, and payload formats that
the `az support in-subscription tickets create` REST surface expects. The
script in `scripts/file_ticket.py` is the source of truth for the
mappings; this file is the reference when you need to extend it.

## Service IDs

All quota tickets file against the "Service and subscription limits
(quotas)" service:

```
06bfd9d3-516b-d5c6-5802-169c800dec89
```

Path form used by the API:
`/providers/Microsoft.Support/services/06bfd9d3-516b-d5c6-5802-169c800dec89`

## Problem classifications under the quota service

| GUID | Display name |
|---|---|
| `e12e3d1d-7fa0-af33-c6d0-3c50df9658a3` | Compute-VM (cores-vCPUs) subscription limit increases |
| `1637f197-715c-6d9e-6496-80ca05787bad` | Azure VMware Solution |

For new services, run:

```bash
az support services problem-classifications list \
  --service-name 06bfd9d3-516b-d5c6-5802-169c800dec89 \
  --query "[].{name:name, display:displayName}" -o table
```

Then verify the right service-id for a non-quota service with:

```bash
az support services list \
  --query "[?contains(displayName, '<keyword>')].{name:name, display:displayName}" \
  -o table
```

## Compute-VM payload formats (problem classification e12e3d1d-...)

`quotaChangeRequests` is a JSON array. The `payload` field is itself a
JSON document (escaped) describing the change. The required fields
depend on the change type.

### Regional total Low-priority (Spot) cores

Bumps the "Total Regional Low-priority vCPUs" cap shown by `az vm
list-usage` as `lowPriorityCores`. Use `VMFamily:lowPriority` even
though it isn't a real family name — the API expects that literal.

```
--quota-change-subtype "Service"
--quota-change-requests "[{region:'southcentralus',payload:'{VMFamily:lowPriority,NewLimit:4000,Type:LowPriority}'}]"
```

### Regional total dedicated cores

```
--quota-change-subtype "Service"
--quota-change-requests "[{region:'westus2',payload:'{VMFamily:cores,NewLimit:200,Type:Dedicated}'}]"
```

### Per-SKU-family dedicated cores

```
--quota-change-subtype "Service"
--quota-change-requests "[{region:'westus2',payload:'{VMFamily:standardDADSv5Family,NewLimit:200,Type:Dedicated}'}]"
```

### Per-SKU-family Spot cores

```
--quota-change-subtype "Service"
--quota-change-requests "[{region:'westus2',payload:'{VMFamily:standardDADSv5Family,NewLimit:200,Type:LowPriority}'}]"
```

### VM family names

Look these up with:

```bash
az vm list-usage --location <region> \
  --query "[?contains(name.value, 'Family')].{name:name.value, current:currentValue, limit:limit}" \
  -o table
```

Examples that show up in FXCI pools:

- `standardDADSv5Family` (D32ads_v5, D64s_v4 builders use related families)
- `standardFSv2Family` (F8s_v2 test pools)
- `standardNVADSA10v5Family` (NV12ads A10 v5 GPU)
- `standardDPDSv5Family` (ARM64 D8pds_v5, D16pds_v5)

## FXCI subscriptions

| Display | Subscription | Trust | Default for |
|---|---|---|---|
| FXCI Azure DevTest | `108d46d5-fe9b-4850-9a7d-8c914aa6c1f0` | Level 1 | test pools, level-1 builds |
| Trusted FXCI Azure DevTest | `a30e97ab-734a-4f3b-a0e4-c51c0bff0701` | Level 3 | release/beta/ESR/autoland builds |
| Taskcluster Engineering DevTest | `8a205152-b25a-417f-a676-80465535a6c9` | Engineering | TC infra, not CI pools |

## Other services (for non-quota tickets, not yet wired into the script)

These exist for completeness if you need to file non-quota tickets via
the same CLI surface. Look up the right service-id at filing time:

```bash
az support services list -o table | grep -iE 'compute|storage|network|batch'
```

Common service GUIDs you may see in the wild:

| GUID | Service |
|---|---|
| `06bfd9d3-516b-d5c6-5802-169c800dec89` | Service and subscription limits (quotas) |
| `f4a247da-c6c1-c1ee-87f4-9a8b15a05d39` | Virtual Machine running Linux |
| `dc1a25c5-44e6-d3f4-2ea3-7d9aae6a0fb6` | Virtual Machine running Windows |

## Severity / support plan matrix

| --severity | Display | Min plan |
|---|---|---|
| `minimal` | Sev C | Any |
| `moderate` | Sev B | Standard |
| `critical` | Sev A | ProDirect |
| `highestcriticalimpact` | Sev 0 | Premier |

A subscription with no paid plan can still file quota tickets, but only
at `minimal`.

## Description quirks

The API rejects the description body if it contains characters outside
ASCII. Failure mode is a vague `JsonDeserializationError: Description
contains invalid characters` with no offset. The script normalizes:

- em-dash, en-dash to `-`
- curly single/double quotes to straight `'` / `"`
- ellipsis to `...`
- non-breaking space to space
- any remaining non-ASCII codepoint is dropped with a warning

If you copy a reason out of a doc or chat, expect a re-encode notice.

## Update vs communication

`tickets update` accepts:

- `--severity` (re-file as Sev A/B/C/0)
- `--status` (Open / Closed)
- the contact-detail-update sub-fields

It does NOT accept a new description. To add detail after filing, use:

```bash
az support in-subscription communication create \
  --subscription <sub> \
  --ticket-name <name> \
  --communication-name "followup-$(date +%Y%m%d-%H%M%S)" \
  --communication-subject "Additional context" \
  --communication-body "Plain ASCII body..."
```

## CLI examples

File a Sev B LowPriorityCores bump in southcentralus:

```bash
uv run ~/.claude/skills/azure-support-ticket/scripts/file_ticket.py quota \
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
uv run ~/.claude/skills/azure-support-ticket/scripts/file_ticket.py bump \
  --ticket-name 2605180040009652 \
  --severity critical
```

Per-SKU-family Spot quota (requires `--vm-family`):

```bash
uv run ~/.claude/skills/azure-support-ticket/scripts/file_ticket.py quota \
  --region westus2 --quota-type VMFamilyLowPriority \
  --vm-family standardDADSv5Family --new-limit 200 \
  --severity moderate --reason "..."
```

## Severity behavior in the script

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
the plan. See the severity sections in this file.

`InvalidParameterValue` on `quotaChangeRequests` - the payload format
is per-quota-type. Re-check the recipe in
this file; the
common mistake is omitting `VMFamily` (use the literal `lowPriority`
or `cores` for the regional totals, real family names like
`standardDADSv5Family` for per-family).
