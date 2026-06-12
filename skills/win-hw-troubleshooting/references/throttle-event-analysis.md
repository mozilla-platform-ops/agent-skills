# Kernel-Processor-Power throttle events — semantics, mining, and pitfalls

`Microsoft-Windows-Kernel-Processor-Power` is the Windows provider that
exposes platform / firmware / RAPL throttling decisions to the System event
log. On the NUC13 fleet this provider is the primary OS-visible signal for
chronic PSU degradation. This file is the reference for what each event ID
means, how to mine them via System log or Papertrail, and the channel /
retention pitfalls that have repeatedly led to misattribution.

## Event IDs you'll see

| Event ID | Meaning | Logged where |
|----------|---------|--------------|
| **37** | "The speed of processor N in group 0 is being limited by system firmware. The processor has been in this reduced performance state for 71 seconds since the last report." Firmware (BIOS / EC / ME / RAPL PL1) is actively capping CPU frequency below the OS's commanded P-state. Re-logged periodically while the condition holds. | System log (always); also visible in ETW via `Microsoft-Windows-Kernel-Processor-Power` provider. |
| **48** | C-state constraint imposed (OS sees a deeper C-state than it requested). | ETW only — not in System log. `logman` capture required. |
| **51** | OS performance constraint (frequency cap reported by RAPL or similar). | ETW only. |
| **55** | Per-processor performance state record. Logged when the firmware adjusts the floor — captures the `% of Maximum Frequency` floor applied. Used to derive "worst non-zero min performance %" per node. | System log + ETW. |
| **58** | Core parking changes. | ETW only. |

Events 37 and 55 are mineable from the System log directly via
`Get-WinEvent -LogName System -ProviderName Microsoft-Windows-Kernel-Processor-Power`.
Events 48 / 51 / 58 require an ETW session against the provider
(`logman create trace … -p Microsoft-Windows-Kernel-Processor-Power 0xFFFFFFFFFFFFFFFF 0xFF`)
to capture, or an `xperf` kernel trace with `POWER` enabled.

## The 71-second cadence

A single firmware throttle condition produces *one record per re-evaluation
interval* — typically every 71 seconds while the condition holds. So a 10-min
sustained throttle window emits ~8 records per affected processor, not one
per millisecond and not one per task. This matters for two reasons:

1. **Event counts are coarse.** A node with 200 Event 37 records on P11 over
   7 days has been throttled for roughly 200 × 71s = ~14,200 logged-seconds
   (~3.9 hrs) of cumulative cap. The count is a proxy for cumulative time
   throttled, not for severity per event.
2. **Counts are not comparable across machines with different uptime or
   workload patterns.** Normalize to per-day before comparing, and exclude
   reboot churn (or normalize to logged-uptime explicitly).

## P11 / P15 symmetry

Every Event 37 record on this NUC13 hardware names a specific processor
index. **Throttling is symmetric on processors 11 and 15** — they fire
together, with equal counts, to within 1 (NUC13-109 is the only documented
asymmetric exception, at 175/176). See `nuc13_cpu_audit_20260422_analysis.md`
"Key Findings #4". These two processor IDs are the highest-indexed P-cores
in the i5-1340P's `Win32_Processor` ordering and represent the platform's
"primary throttle target" for floor enforcement.

Operational implication: classifying a node by **P11+P15 sum** is the right
unit; per-processor counts on other indices are sparse and uneven, and
mixing them produces misleading totals. `cpu_audit.ps1` uses P11+P15 sum as
the primary classifier input. Mirror that for any new throttle-based
classifier or alert.

If you ever see asymmetric P11/P15 counts > 1, that itself is a signal —
log it as anomalous and investigate. The platform's throttle policy targets
both together.

## Floor depth (Event 55)

Event 55 records contain the `% of Maximum Frequency` floor applied during
a performance state change. From `cpu_audit.ps1` and the analysis MD:

- Healthy nodes: worst non-zero min floor ≥ ~83% (NUC13-049 historical: 83-84%).
- Borderline-degraded: worst min floor 70–80%.
- Severe (PSU-degraded): worst min floor ≤ 50% (NUC13-072 hit 47%, multiple
  nodes hit 50%).
- The historical NUC13-066 (pre-PSU-swap) floor was 63% on processor 15.

A node can have moderate Event 37 counts but a very low Event 55 floor (the
firmware doesn't fire often but caps hard when it does). The opposite —
high Event 37 counts and a high floor — is more common on chronic
degradation: many short shallow caps. Both indicate a problem; the floor is
the per-event severity, the count is the cumulative time.

## Mining from the System log

This is what `cpu_audit.ps1` does over SSH per node, and what
`scripts/check-throttle-events.ps1` (this skill) does for a quick count.

```powershell
$boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
Get-WinEvent -FilterHashtable @{
    LogName      = 'System'
    ProviderName = 'Microsoft-Windows-Kernel-Processor-Power'
    Id           = 37
    StartTime    = $boot
}
```

Notes:

- **`StartTime = $boot`** is the right window for "is this node throttling
  in the current session". Past-boot counts can be useful for a 7-day audit
  but you must explicitly *not* gate on `LastBootUpTime` for that.
- For a longer lookback, use `StartTime = (Get-Date).AddDays(-7)`. The
  System log retention on these nodes is typically days to weeks but is
  not guaranteed — verify before quoting.
- The provider name must be exact:
  `Microsoft-Windows-Kernel-Processor-Power`. There is a separate provider
  `Microsoft-Windows-Kernel-Power` (no "Processor") for ACPI / battery
  events — do NOT confuse them.
- Each event's `Properties` array has the processor index in `[0]` (as
  `[uint32]`). Use `($_.Properties[0].Value)` to bucket by processor.
- Counting Event 37 with `-FilterHashtable Id=37` is fast (uses the index);
  enumerating then filtering by Id in PS is orders of magnitude slower —
  always filter in the hashtable.
- See `scripts/check-throttle-events.ps1` for a self-contained, SSH-runnable
  version that emits P11+P15 + total counts.

## Papertrail mining (the easy way to get fleet-wide counts) and its pitfalls

The Papertrail / SolarWinds Observability search

```
"being limited by system firmware"
```

returns matching log lines across the whole `wintest2` fleet (NSClient++
syslog forwarding sends a subset of Windows events to Papertrail). This is
how `nar-win11-24h2-hw-firmware-throttle-investigation-2026-06-11.md` and
`win11-64-24h2-hw-cpu-throttle-regression-2026-06.md` produced their
"≥500/day" counts. **There are four severe pitfalls.** All four have been
made in real investigations.

### Pitfall 1: result cap = "≥500" is not "exactly 500"

Papertrail / SWO impose a per-query sample cap (`--limit 500` is the
typical knob). If your daily count hits ≥500 you've **saturated the query**
and the true count could be 500 or 50,000. The ratio between two saturated
days is meaningless. Use a tighter time window (e.g. 1-hour buckets, 5-min
buckets) until you drop below the cap, OR query directly against the
Windows System log on a representative subset of nodes (this skill's
`check-throttle-events.ps1`).

### Pitfall 2: "0 before date X" is a retention artifact, not an onset

Papertrail retains a finite window (typically ~14 days indexed, longer in
archive). If your query window extends past retention, the result is `0`,
not "no data" — there's no signal distinguishing them. Multiple
investigations have reached "throttling started on June 4" by reading 0 →
≥500 in the Papertrail view, then been disproved by going back to the
actual nuc-script archives where `kernel-processor-power-audit-20260417-*`
records the *same* Event 37 / P11+P15 pattern on NUC13-066 over
2026-03-30 → 04-09 (RELOPS-2396 §3l).

**Always cross-check a "throttling onset" date against:**
- The `nuc scripts/CLUADE-NUC/logs/` archive (historical audits).
- Local `Get-WinEvent` on a representative live node.
- The PSU-replacement timeline (NOTES.md "PSU Replacement History" and
  `NUC13_power_supply_replacements.md`).

The throttle is chronic, not new. A new visible *spike* in Papertrail
generally reflects (a) workload changes (a new heavy test landing), (b)
ambient temperature changes (datacenter / season / cooling), or (c) more
nodes degrading — not a fleet-wide flip on a specific date.

### Pitfall 3: "≥500/day" is a *fleet sum* across ~60 nodes

The Papertrail count is fleet-wide. ≥500/day across the fleet is on the
order of ~8/day/node — well below per-node thresholds for "BAD" (the
historical bad baseline NUC13-066 was at 255/7d ≈ ~36/day for the P11+P15
pair). A saturated daily fleet count tells you SOMETHING is throttling
SOMEWHERE; it does not tell you the per-node severity. For that, run
`scripts/check-throttle-events.ps1` or `cpu_audit.ps1` per host.

### Pitfall 4: shippable vs nightlyasrelease (NaR) channel mixing

A common SP3 query (Treeherder/Perfherder, `os=windows`,
`repository=autoland`, range=week) **combines** two platforms:
`windows11-64-24h2-shippable` and `windows11-64-24h2-nightlyasrelease`.
The NaR channel runs ~22.5 fleet-wide as a baseline — this is a build/
config characteristic of NaR, not a per-node fault. A "29% of runs <23"
figure on the combined view collapses to "shippable 29%, NaR 84%" once
split (RELOPS-2396 §1.3).

**Genuine per-worker throttle classification must use the shippable
channel only.** NaR's bimodality has a different mechanism (graphics
fast-path vs slow-path; see playbook §"Regression A"). When someone
quotes "% of runs below 23" or "regression of N points" from a fleet
dashboard, the first question is: shippable or NaR or mixed?

## Mining the System log offline (per-node audit)

`cpu_audit.ps1` is the canonical offline auditor. Salient design:

- Lookback `-days_back` (default 7), per-node SSH, base64-encoded PS
  payload, JSON back. Two-pass with retry. Run-tagged output supported.
- Classification midpoint frozen from two baselines: NUC13-049 historical
  good = 54 Ev37 P11+P15 / 10.69 days = ~35.35/7d; NUC13-066 historical
  bad (pre-PSU-swap) = 390 Ev37 P11+P15 / 10.69 days = ~255.34/7d.
  Threshold = midpoint = **≥ 145.35 Ev37 P11+P15 per 7 days → BAD**.
- The good baseline node (049) has since itself degraded and would now
  classify BAD against its own former baseline (390 events in 7 days,
  ~7.3× its historical rate). **The baselines are frozen on purpose**;
  do not "update" the good baseline against a current measurement
  because every measurement on a degrading fleet ratchets the threshold.

If you need a fresh classifier, build it against fleetbench (which is
hardware-state, not workload-history) — see
`references/psu-fleetbench-detection.md`. Keep `cpu_audit.ps1` for
historical / passive corroboration.

## ETW capture (when you need 48 / 51 / 58)

Event 37 alone undercounts the real throttle picture because Events 48
(C-state constraint), 51 (RAPL / OS perf constraint), and 58 (core
parking) only appear in ETW, not the System log. `StressXperf.ps1`
combines:

1. xperf kernel POWER trace (`PROC_THREAD+LOADER+POWER`) — captures CPU
   frequency series for the run window, derivable into a histogram via
   `xperf -a cpufreq`.
2. `logman` ETW session against `Microsoft-Windows-Kernel-Processor-Power`
   with `0xFFFFFFFFFFFFFFFF 0xFF` keywords/level — captures Events 37 /
   48 / 51 / 55 / 58 at full fidelity.

The ETL files are then parsed offline with `Get-WinEvent -Path
<file>.etl`.

**Note (RELOPS-2396 §1.7 / NOTES.md "StressXperf"):** the SSH transport
for the large StressXperf payload (~200 lines PS) has unresolved buffering
issues with Windows OpenSSH stdin — the script connects and runs the full
duration but returns empty output. See
`references/remote-diagnostics-ssh.md` §"Stdin loader pattern" for the
known-unreliable workaround. For ETW capture, prefer a held-interactive
SSH session and pull the .etl files back manually.

## Interpreting the throttle (what's the root cause)

"Limited by system firmware" is the **observable**, not the cause. The
firmware (BIOS / EC / ME / RAPL controller) saw a power-limit, thermal-
limit, or PROCHOT-style condition and clamped frequency. The candidate
underlying causes, in approximate descending order of evidence on this
fleet:

1. **PSU degradation** (the dominant cause on NUC13 — see
   `references/psu-fleetbench-detection.md`). Validated by the
   three-for-three swap on 066/108/131.
2. **Ambient / thermal** — daytime CI heat in IT46/IT47. Yardstick
   thermals do track up with throttle counts. Exhaust fans (IO-3684) and
   perforated tiles (IO-3685) were tried 2026-03 / 04 and produced no
   material change. Thermal is contributory, not sufficient.
3. **BIOS / EC power-limit (PL1/PL2/RAPL) policy** — possible in
   principle (a firmware push could change PL1), but ruled out for the
   2026-06-04 "cliff" by the t-nuc12 control (same DC, didn't throttle).
4. **PDU / rack-level power cap** — also ruled out by the t-nuc12 control.

Conclusion: on the current NUC13 fleet, "Event 37 firing" → PSU is the
modal suspect. Always corroborate with fleetbench before recommending a
brick swap; do not swap on Event 37 alone (the swap stock is finite — see
IO-3697).

## "When this is NOT the problem"

- Fleet-wide synchronous SP3 score drop with all 50/50 active nodes
  scoring sub-23 → not throttle. PSU-throttle is per-node and uneven (the
  cluster sizes vary by hardware unit). A 100% uniform tight-band drop is
  code or environment, full stop. See playbook §"Worked example".
- Throttle is **constant** across hi/lo runs on the same node (e.g. the
  nuc13-059 GeckoProfiler hi/lo pair: 4 Event 37 firings in both, Event 55
  perf% identical) → throttle is real on that node but is not the
  *variance source* for the run-to-run difference. The variance has another
  driver (e.g. WdFilter flip, GC nondeterminism, environment).
- The provider is `Microsoft-Windows-Kernel-Power` (no "Processor") →
  that's the ACPI / battery / system-power-state provider, not the CPU
  throttle one. Wrong provider. Switch to
  `Microsoft-Windows-Kernel-Processor-Power`.
- The events fired but the node ran clean under fleetbench → could be
  daytime-only thermal throttling that fleetbench's 900s isn't long
  enough to reproduce, or chronic firmware floor that has resolved.
  Re-run both back-to-back.

## Citations

- Event 37/55 semantics + 71s cadence + P11/P15 symmetry: NOTES.md
  "cpu_audit.ps1" + "throttling jra comment.txt";
  `nuc13_cpu_audit_20260422_analysis.md` §"Key Findings #4".
- Baselines + midpoint thresholds: `cpu_audit.ps1` classifier;
  `nuc13_fleet_findings_20260422.md` Section A; RELOPS-2323.
- Papertrail saturation / retention / onset pitfalls: RELOPS-2396 §3l;
  `nar-win11-24h2-hw-firmware-throttle-investigation-2026-06-11.md`;
  `win11-64-24h2-hw-cpu-throttle-regression-2026-06.md`.
- Shippable vs NaR channel split: RELOPS-2396 §1.3.
- Event 48 / 51 / 58 ETW capture: NOTES.md "StressXperf.ps1";
  `StressXperf.ps1` columns table.
- Cause attribution (PSU vs thermal vs BIOS vs PDU): RELOPS-2396 §3k;
  `win11-64-24h2-hw-cpu-throttle-regression-2026-06.md` §"Analysis".

## Volatile / dated facts

- **As of 2026-06-12:** 49 / 53 distinct nuc13 hosts firing Event 37 daily
  in Papertrail. Per-node distribution and identity changes hourly; do not
  cite specific hostnames.
- Papertrail saturation cap was `--limit 500` in the cited investigations.
  The cap is a query parameter; if you re-run with higher limits you'll get
  larger numbers, not different conclusions.

## Structural / durable facts

- Event 37 / 55 are System-log; 48 / 51 / 58 are ETW-only. This is a
  Windows-platform fact, not a configuration choice.
- P11 + P15 symmetry is a fact of the i5-1340P throttle policy (the two
  highest-index P-cores). Other i5-13xxP variants behave similarly; new
  hardware classes need their own characterization.
- The "limited by system firmware" message text is fixed by the provider;
  string-matching against it is stable across Windows versions on this
  fleet (Win11 24H2, build 26100).
- The 71-second re-log cadence is a property of the provider's
  re-evaluation interval. It can vary by SKU / driver / firmware but has
  been stable on i5-1340P throughout the documented investigation.
