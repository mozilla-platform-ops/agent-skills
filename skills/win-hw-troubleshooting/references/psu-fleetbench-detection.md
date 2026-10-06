# PSU degradation, fleetbench torture, and the GOOD/MARGINAL/BAD classifier

The dominant hardware failure mode on the `win11-64-24h2-hw*` fleet is
power-supply (external brick) degradation that produces silent CPU
suppression below the OS event threshold. This file documents (a) why
fleetbench is the right detector, (b) what its `frequency_series` actually
shows on healthy vs degraded NUC13 hardware, (c) the locked thresholds the
classifier uses, (d) PSU-swap validation, and (e) the known blind spots.

## Theory of the failure mode

NUC13 nodes were shipped with a mix of **120W 20V** and **90W 19V** external
bricks (NOTES.md "PSU mix (2026-04-16)"; RELOPS-2341 comment, Bug 2004395
#22). Under sustained CPU load — especially CPU+iGPU concurrent load like
Speedometer 3 — a degrading 90W brick cannot sustain the package power
demand. The platform responds in two ways:

1. **Firmware-enforced floor** — `Microsoft-Windows-Kernel-Processor-Power`
   Event 37 ("limited by system firmware"), paired on processors 11 and 15,
   logged with a "for N seconds since the last report" cadence. This is the
   *visible* OS-level signal. See `references/throttle-event-analysis.md`.
2. **RAPL / package-power cap** — invisible to the System log, manifests as
   sustained sub-base CPU frequency and high run-to-run variance. This is
   what fleetbench detects.

A failing 90W brick has been observed to:
- Fire hundreds of Event 37 records per day under daytime CI load while
  showing 0 events overnight (mechanism A is temperature- and
  workload-pattern-sensitive).
- Hold a sustained ~74–75% CPU floor under prime95 torture independent of
  time of day (mechanism B is hardware-persistent).
- Recover to ~100% CPU floor and clean Event 37 counts after a brick swap
  (validated three-for-three on NUC13-066 / -108 / -131, IO-3705).

The two mechanisms can coexist and a single node typically exhibits one or
both at varying severity. Mechanism B (RAPL) is the cleaner detector
because it doesn't depend on ambient temperature or workload mix.

## Why fleetbench, not prime95 or xperf

The historical investigation went prime95-torture → xperf kernel-power
tracing → cpu_audit (Event 37 mining) → fleetbench. The progression is
documented in `perf_ops_windows_hw_timeline.md` 2026-03 through 2026-04 and
RELOPS-2396 §3.x. Fleetbench was adopted because:

- It emits **raw per-iteration data per host** (a JSON envelope with
  `frequency_series` sampled at ~1 Hz over the duration). That is exactly
  the input shape a per-node degradation baseline (RELOPS-2402) needs — no
  need to re-derive from Treeherder or Perfherder.
- It cross-compiles to Linux/Windows/macOS/Android (Rust + clap + sysinfo).
  One detector applies across the FXCI fleet.
- The collector/runner split (collector = raw data only, runner = throttle
  + envelope) means the PSU-degradation **classifier belongs downstream**,
  not in the collector. The classifier described below is what the
  maintain-script applies in `Get-FleetbenchVerdict`.
- Released as immutable GitHub Release artifacts (one binary per platform +
  SHA256SUMS), so installs are reproducible and pinnable via hiera.

Repo: `mozilla-platform-ops/fleetbench`. Subcommand we use is `cpu`;
`adb` and `inspect` are out of scope here.

## Canonical invocation on NUC13

```
fleetbench cpu --mode quick --duration 900s --json
```

- `--mode quick` → ~4 ms-per-iteration MT sieve segments → ~220k iterations
  in 900s on healthy i5-1340P. High-resolution throughput-variance signal.
- `--duration 900s` (15 min) → long enough to **self-warm the box into the
  throttle regime**. 120s was the original setting and worked for gross
  failures (e.g. nuc13-138 in §3b) but a 120s cold-boot run can pass a
  degrading node that throttles only when warm. Verified: `nuc13-002`
  reported GOOD at cold boot under 120s, BAD under 900s warm
  (RELOPS-2396 §3h, §3i). **Do not shorten below 900s on hw fleet.**
- `--json` → single envelope to stdout. The maintain-script writes it
  atomically to `C:\fleetbench\results\<UTC-ts>_<COMPUTERNAME>_cpu.json`
  via `.partial` → rename. Envelope is `schema_version: 6` (collector
  v0.4.0 as of pin in `data/os/Windows.yaml`).
- The Windows-side frequency sampler uses PDH counter
  `\Processor Information(*)\% Processor Performance`, sampled at ~1 Hz in
  a background thread during the MT sieve loop. Each per-core entry in
  `frequency_series` is a percentage of `base_clock_mhz` (1900 on i5-1340P)
  — i.e., 100 = at base, >100 = boosting above base, <100 = below base.

## Metrics derived from the envelope

`Get-FleetbenchMetrics` in `maintainsystem-hw.ps1` extracts four scalars
per envelope:

| Metric | Definition | What it tells you |
|--------|------------|-------------------|
| `MinPct` | Min over `frequency_series`, expressed as % of base clock (lowest per-core sample × 100 / base). | **Primary discriminator.** A degrading PSU produces deep frequency dropouts (min ~20% base on bad nodes); healthy nodes hold ≥ 75–85% base under sustained load. |
| `MeanPct` | Mean over `frequency_series`, % of base. | Sanity check / corroboration. Healthy nodes sit ~108–112% (boosting above base most of the run); degraded sit ≤ 95% or near 88%. |
| `TputCV` | Coefficient of variation of per-iteration completion time × 100. | Secondary discriminator. Healthy ≤ 25% (typically 17–21%); degraded ≥ 40% (typically 47–64%). |
| `Iterations` | Total iterations completed in the duration. | Sanity check. Healthy ~221k–222k iters on 900s @ i5-1340P. A pathological PSU can drop to ~180k or lower (~12%+ less work). |

A fifth derived metric, `max/median iteration time` (per-iteration
worst-case-to-typical ratio), is logged but not classifier-input. Healthy
runs sit at 2.3–2.9×; pathological nodes have been observed at 725× (a
single multi-second stall in an otherwise 4ms-per-iter loop).

## The classifier (locked thresholds)

Source: `modules/win_fleetbench/files/fleetbench_baselines.json`,
hardware-type key `nuc13` (matched against `Win32_ComputerSystem.Model`
via the `model_match: "NUC13*"` glob). Authoritative classifier code:
`Get-FleetbenchVerdict` in `modules/win_scheduled_tasks/files/maintainsystem-hw.ps1`.

```
GOOD:     MinPct >= 75  AND TputCV <= 25  AND MeanPct >= 100
BAD:      MinPct <  50  OR  TputCV >  40  OR  MeanPct <  95
MARGINAL: anything else (the band between the two)
```

These thresholds were anchored on:

- **Canonical good cluster (7 nodes):** perf-debug 024/059/119 + alpha
  111/129/131/152. Re-baselined at 900s on perf-debug 024/059:
  min **84**, mean **108**, CV **17**, iters ~221.6k (RELOPS-2396 §3i,
  Confluence Intel NUC page v7).
- **Canonical bad cluster:** alpha 002/136 at 900s warm — 002 min 35 /
  CV 25 / max-median 8.0×; 136 min 19 / mean 93 / CV 44 (RELOPS-2396 §3i).
- **Validation run on all 70 alpha nodes (2026-06-08/09):** GOOD=4 / BAD=52
  / DOWN=14 / MARGINAL=0. Distribution is strongly bimodal with a wide
  dead-zone between the clusters (RELOPS-2396 §3c):
  - Min-frequency floor: BAD cluster max = 30%, gap, GOOD cluster min = 82%.
  - Throughput CV: GOOD cluster max = 20%, gap, BAD cluster min = 47%.

The classifier is intentionally OR-disjunctive on the BAD side (any one
failing criterion → BAD) and AND-conjunctive on GOOD (all three must hold
→ GOOD). The "MARGINAL" band is empty in practice on NUC13 because the
distribution is bimodal; it exists as a safety zone.

**The single best discriminator is `MinPct` (the frequency floor).** Some
degraded nodes have near-good mean and CV but a clearly bad floor — e.g.,
`nuc13-002` at min 35 / mean 99 / CV 25 in one run. Only the floor exposed
it. When triaging by eye, look at min first.

## Per-hardware-type baselines

The baselines file is keyed by hardware type so other models can be
classified by their own ranges. The structure is:

```
{
  "nuc13": {
    "model_match": "NUC13*",
    "thresholds": {
      "min_floor":  {"good_min": 75, "bad_max": 50},
      "mean":       {"good_min": 100, "bad_max": 95},
      "tput_cv":    {"good_max": 25, "bad_min": 40}
    },
    "reference":  {"min": 84, "mean": 108, "tput_cv": 17, "iterations": 221600},
    "drop_off":   {"mean": -5, "min": -10, "iter_pct": -10}
  }
}
```

`Get-FleetbenchHardwareBaseline` matches `Win32_ComputerSystem.Model`
against each entry's `model_match`. If no entry matches (new hardware), the
maintain-script **logs a WARN and continues** — it does NOT error / block
worker-runner startup. To onboard a new hardware class, add a new top-level
entry to the JSON; you do not need to change any PowerShell code.

## Variance / drift detection

`Get-FleetbenchVariance` compares the latest run against this node's
**FIRST** stored run (not a rolling median). Source: RELOPS-2396 §3h. The
deltas reported are `var_min_delta`, `var_mean_delta`, `var_iter_pct`.

`drop_off` in the baseline JSON sets the WARN thresholds: a drift of
mean -5, min -10, or iters -10% from the first stored run flips the
variance check from OK to WARN. This catches gradual decline *within the
absolute-good band* — a node going from min 84 → min 76 is still
absolute-GOOD but has lost half the headroom and is on the trajectory
toward BAD.

`drift_note: no_baseline` is emitted on a node's first run after reimage
(there's nothing to compare against). That is correct; it suppresses a
spurious "drift" the first time around.

If `defender_status.json` or any non-`*_cpu.json` sibling file lands in
`C:\fleetbench\results\`, both `Invoke-FleetbenchCheck` and
`Get-FleetbenchVariance` must continue to ignore it. The §4g fix tightened
both globs to `*_cpu.json`. If you ever add a new sibling file, name it
defensively (do NOT end in `_cpu.json`).

## PSU swap validation

After IT replaces a brick (IO-3705-style ticket), the node has to clear
**both** the active fleetbench classifier AND the passive 7-day Event 37
audit to be considered "confirmed clean". The three confirmed-clean
post-swap nodes (066, 108, 131) — see NOTES.md "Resolved" and
`nuc13_fleet_findings_20260422.md` PSU section — all showed:

- fleetbench (900s, post-reimage): GOOD by classifier.
- 7-day Event 37 P11+P15 audit (`cpu_audit.ps1`): ≤ historical good
  baseline (NUC13-049 frozen baseline 54 / 10.69 days → ~35 / 7 days).
- Stress test (`StressCPU.ps1` prime95 torture): CPU_Min ≥ ~99%.

A node that clears only one of those is NOT validated. Specifically: a node
can clear the passive audit (low Event 37 counts) while still showing
silent suppression under prime95 / fleetbench (the case for `nuc13-159`
historically — "silent suppression, no Ev37"). Both arms are required.

The reverse can also happen: a freshly-imaged node with no recent CI load
will have a low Event 37 count from sheer inactivity (cf. alpha pool 001-030
in NOTES.md "Fleet Structure Notes"). Don't read "low Event 37 in last
N days" as "healthy" without checking activity volume.

## Known blind spots

### 1. Pure-CPU torture does not exercise the iGPU

On the i5-1340P the CPU and iGPU share a single package power budget.
Speedometer 3 loads both; fleetbench `cpu` loads only the CPU. This means a
node that passes fleetbench can still throttle under SP3 — combined load
trips the firmware power limit, but pure-CPU does not.

Documented case: `nuc13-059` (RELOPS-2396 §3m, 2026-06-11). The node ran
fleetbench 900s on 2026-06-10 with full turbo held (no throttle, mean 108%).
On 2026-06-11 under SP3 the GeckoProfiler captured 4 Event 37 firings in
the run window, perf% averaged ~74%, min 25%. The same node was healthy
under pure-CPU torture and throttled under CPU+iGPU.

**Implication:** fleetbench is necessary but not sufficient for SP3
correlation. Options under consideration (RELOPS-2396 §3m, open):
- Add a combined CPU+iGPU torture mode (or a sidecar GPU loader running
  during the fleetbench window).
- Read Event 37 directly from the System log in the maintain script and
  feed it into the classifier as a third signal alongside fleetbench
  metrics.

Treat fleetbench-GOOD as "this node's CPU is delivering full performance
under pure-CPU sustained load". It does NOT guarantee "this node will hit
fleet-mean SP3 score under CI workload".

### 2. Cold-boot runs

A 120s run on a just-booted node can pass a node that throttles when
warm. The 900s duration was chosen specifically to self-warm the box —
do NOT shorten. The maintain script schedules the check after
`Test-ConnectionUntilOnline` (early-boot but post-network); the 900s
duration is the warm-up.

If you need to retrigger a benchmark on a node manually for ad-hoc
investigation, prefer a held-interactive SSH session on a stable
perf-debug node. Main-pool nodes reboot frequently (CI cycling) and a
15-min run will often be interrupted; SYSTEM-context detached execution
emits no output (RELOPS-2396 §3i).

### 3. The classifier is hardware-type-scoped

The thresholds above apply to NUC13 (i5-1340P). When new hardware lands
(e.g. the proposed LGA1851 Core Ultra Series 2 refresh in
`fxci-hw-perf-worker-spec.md`), the *method* generalizes but the
*numbers* don't. Add a new baseline entry to `fleetbench_baselines.json`
keyed by the new model_match before classifying.

## "When this is NOT the problem"

- The node is fleetbench-GOOD but SP3-low → the headline regression is
  probably not PSU. Walk the
  `references/perf-debug-investigation-playbook.md` ladder; in particular
  rule out code, environment (e.g. remote-settings / Nimbus flips), and
  the WdFilter active vs inactive boot race
  (`references/defender-realtime-disable.md`).
- The node won't SSH at all (`Connection timed out` across multiple
  attempts) → that is a separate "DOWN/DEAD" category, not BAD-PSU. The
  classifier records DOWN distinctly from BAD. A DOWN node needs network /
  KVM / on-site investigation, not a PSU swap (yet).
- Fleet-wide synchronous regression (every node drops together on the same
  day) → not PSU. PSU degradation is per-node and per-hour-of-day variable.
  A uniform fleet drop is environmental or code; see playbook §"Worked
  example, June 10 #50783".
- Event 37 counts are high but fleetbench is clean → could be a chronic
  firmware-floor condition that fleetbench's 900s doesn't trigger (see
  blind spot 1 above), or the 7-day audit window is reflecting a since-
  resolved condition. Re-run fleetbench and the audit together.
- The node passes fleetbench, passes Event 37 audit, but SP3 is still low →
  WdFilter boot race on that boot (see `references/defender-realtime-disable.md`).
  Confirm with `check_defender.ps1` output or live WdFilter state via
  `Get-Service WdFilter` / `fltmc filters`.

## Citations

- Theory: NOTES.md "PSU mix (2026-04-16)"; `nuc13_fleet_findings_20260422.md`;
  `perf_ops_windows_hw_timeline.md` 2026-04-08 through 2026-04-17;
  RELOPS-2323 / RELOPS-2341 / Bug 2004395 #22.
- Canonical invocation, metrics, thresholds: RELOPS-2396 §3b, §3c, §3d,
  §3i; `modules/win_fleetbench/files/fleetbench_baselines.json`;
  `Get-FleetbenchVerdict` / `Get-FleetbenchMetrics` /
  `Get-FleetbenchHardwareBaseline` in
  `modules/win_scheduled_tasks/files/maintainsystem-hw.ps1`.
- Validation 70-alpha run: RELOPS-2396 §3c.
- Variance / first-run baseline: RELOPS-2396 §3h.
- Cold-boot warm-up rationale: RELOPS-2396 §3h, §3i.
- iGPU blind spot: RELOPS-2396 §3m (nuc13-059 hi/lo GeckoProfiler).
- PSU swap validation: NOTES.md "Resolved";
  `nuc13_fleet_findings_20260422.md` PSU section; IO-3705 outcome.
- Cadence gate / `*_cpu.json` glob fix: RELOPS-2396 §4g, commit `e75fd9e7`.

## Volatile / dated facts

- **As of 2026-06-12:** canonical-good cluster is perf-debug 024/059/119 +
  alpha 111/129/131/152. Identity drifts whenever hardware swaps land.
- Fleetbench collector version pinned in hiera: **v0.4.0** as of 2026-06-08.
  Re-verify `data/os/Windows.yaml` `windows.fleetbench.version` before
  citing.
- Cadence: 72h production (commit `e1156872`), 1h test. Re-verify
  `$IntervalHours` in `maintainsystem-hw.ps1` and the comment marker.
- Baseline `reference: {min:84, mean:108, tput_cv:17, iterations:221600}` is
  the 2026-06-10 re-baseline on perf-debug 024/059 (RELOPS-2396 §3i). Re-
  baseline when the canonical-good cluster identity changes substantively.

## Structural / durable facts

- The classifier is data-driven via `fleetbench_baselines.json`. PS code
  is generic; thresholds live in JSON keyed by `model_match`.
- The detector belongs in the **downstream analysis layer**, never in the
  collector — that contract comes from fleetbench's design (RELOPS-2396 §3,
  fleetbench `docs/fleetbench_design_v2.md`).
- `MinPct` is the single best discriminator on NUC13. Mean and CV can both
  look near-good while the floor is clearly bad (the 002 case).
- The maintain script writes both a per-run envelope (`*_cpu.json`) and a
  summary (`fleetbench_status.json`); NSClient checks read the summary,
  the variance comparator reads the envelopes.
