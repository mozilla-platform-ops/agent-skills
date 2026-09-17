# Perf-debug investigation playbook — hardware vs code vs environment

When a Speedometer 3 / Speedometer 2 / Talos / Raptor regression lands on
`win11-64-24h2-hw*`, the first non-trivial question is which subsystem
owns it: hardware, code, or runtime/environment. The wrong answer wastes
investigator time and (worse) can trigger needless PSU swaps, branch
reverts, or pool quarantines. This file is the disambiguation ladder.

Audience: a future LLM session triaging a regression that has been
attributed (perhaps incorrectly) to the hw fleet.

## The three buckets

| Bucket | What "owns" the regression | Signal shape |
|--------|---------------------------|--------------|
| **Hardware** | PSU degradation, thermal, firmware throttle, WdFilter active | Per-node bimodal: a varying subset of nodes is bad, the rest are fine. Throttle event counts vary 7× across the fleet. fleetbench bimodal. PSU swap recovers the affected node. |
| **Code** | Gecko source change (compiler / harness / a landed patch) | Uniform: every active node drops on the same day. Same-binary retrigger of an old build now scores HEALTHY (proves the variable is the build, not the runtime). Perfherder finds a culprit push range. |
| **Environment / runtime** | Remote Settings, Nimbus, feature gate, server-side config, a runtime-fetched blocklist, OS-level change | Same shape as code (uniform fleet drop) BUT same-binary retrigger of an old build now scores LOW (proves the build is constant and the runtime config has changed). |

These are mutually exclusive at the *cause* level but can coexist as
*symptoms*. A chronic per-node throttle problem and a uniform code drop
can be happening simultaneously and look superficially similar in a
fleet dashboard; they need to be separated before either is acted on.

## The disambiguation ladder

In order, fastest to slowest:

### Step 1 — Pull the active-node list and look at the distribution

For the regression window, pull every task on `win11-64-24h2-hw*` shippable
(or NaR if that's the channel) and group by `worker_id`. The shape of the
per-node distribution is diagnostic:

- **Tight band, 100% of active nodes below threshold** → uniform fleet
  regression. Goes to Step 2 (rule out hardware, then code-vs-env).
- **Bimodal: ~5–20% of nodes scoring low, the rest fine** → per-node
  hardware. Goes to Step 4 (fleetbench + Event 37 + PSU history). Move on
  the bad nodes; do not investigate code.
- **Some nodes degraded over time, recent days different** → could be
  progressive hardware degradation (NUC13-049 case). Goes to Step 4.

This is a 5-minute query against `mozdata.taskclusteretl.*` or
Perfherder API. Always do it first.

### Step 2 — Cross-check against t-nuc12

`t-nuc12-*` nodes share MDC1, the PDU plane, and the cooling zone with
the NUC13 fleet but use different hardware (NUC12) and different bricks.
If a fleet-wide regression is real *and* hardware-caused (e.g. PDU
outage, cooling event, fleet BIOS push), it should hit t-nuc12 too.

t-nuc12 NOT throttling during the regression window → **not a
facility-wide hardware event**. Documented as the key control in
`win11-64-24h2-hw-cpu-throttle-regression-2026-06.md` §"Control group":
800/800 throttle events Jun 4–11 were from nuc13 hosts.

### Step 3 — Run fleetbench against a representative subset

If Step 1 says "uniform" and Step 2 rules out facility-wide hardware,
that *almost* proves not-hardware. Sanity check by running fleetbench
900s torture against a few of the affected nodes. Healthy fleetbench
(GOOD per classifier) under pure-CPU sustained load while SP3 is uniformly
low → not hardware, full stop.

Worked example (RELOPS-2396 §3k, 2026-06-10):
- SP3 dropped uniformly across all 54 active nodes on Jun 10.
- Fleetbench 900s on perf-debug 024/059 the same day: full turbo held,
  mean 108%, no throttle. Bad alpha nodes (002/136) throttled as always.
- **Hardware health was per-node bimodal; SP3 drop was uniform across
  the fleet → not hardware.**

### Step 4 — If hardware suspected per-node, run the standard hardware battery

Per node:
- `fleetbench cpu --mode quick --duration 900s --json` + apply the
  classifier (`references/psu-fleetbench-detection.md`). GOOD/BAD verdict
  is the discriminator.
- 7-day Event 37 P11+P15 count from System log
  (`scripts/check-throttle-events.ps1` or `cpu_audit.ps1`). Compare
  against the historical baselines.
- Check PSU replacement history for that node (NOTES.md PSU history
  table, IO-3683/3697/3705).
- Defender state — is WdFilter running this session?
  (`references/defender-realtime-disable.md`).

Sources of confounding: cold-boot runs (the 900s must warm the box), CI
busy-state (`quser` shows `task_*`), recent reimage state. All covered in
the cited references.

### Step 5 — Same-binary retrigger to separate code from environment

When Step 1 → Step 3 has ruled out hardware, separate code from
environment by **retriggering an old build (pre-regression) on a node
that's NOT currently throttling, *now***:

- **Old build re-run NOW = HEALTHY** → cause is in the *build*. Code
  regression. Find the culprit push via Perfherder culprit range / git
  bisect. Worked example: RELOPS-2396 §3q — task
  `UzKOQIH4SMqk9Ytqa4PItQ`, a June-4 build re-run June 11 (nuc13-119)
  scored 24.52 (healthy), confirming Regression B = CODE (#50783).
- **Old build re-run NOW = LOW** → cause is in the *runtime* environment
  (Remote Settings, Nimbus, server-side feature gate, OS-level change).
  No Gecko culprit will be findable in Perfherder. Worked example: the
  NaR Regression A (~Jun 1) — the m-c rev 71e37c87 (May 31, originally
  fast) re-run on a node now scored LOW; same-binary identical, the
  variable is the runtime config.
- **Old build re-run NOW = MIXED** → some runs healthy, some low → likely
  an intermittent runtime condition (e.g. graphics fast-path vs slow-path,
  sync timing of remote-config fetch). The NaR signature 5273122 case —
  bimodal within-revision, fast cluster vanished by Jun 3.

The retrigger should be the SAME revision, the SAME worker pool, the
SAME task label — the only intentional variable is wall-clock time.

### Step 6 — Verify the culprit (only after Step 5)

- **For code culprits:** confirm the Perfherder culprit range (`alert
  id`); if it's a tight range, the patch is identifiable. If it's wide,
  bisect. *Do not* assume the Perfherder alert is the cause without the
  same-binary retrigger from Step 5 — Perfherder time-pins a step to
  whatever push landed at the wall-clock time, and an *environmental*
  step gets misattributed to a coincident push.
- **For env culprits:** Remote Settings is the leading candidate. Other
  candidates: Nimbus / experimental feature gate, server-side
  feature-flag service, OS-driver auto-update, a Defender platform-update
  flipping WdFilter on. Ownership is fuzzy; surface to the perf team
  with the same-binary retrigger evidence.

## Worked example: the June-10 SP3 shippable step

This is the most fully-investigated case to date. Walk through it as a
template:

- **Symptom:** SP3 shippable on `windows11-64-24h2-hw` stepped 24.4 →
  22.3 on Jun 10. Perfherder alert #50783, 8.51% regression, culprit
  range autoland 1941906→1941961.
- **Concurrent claim:** Papertrail showed `Kernel-Processor-Power
  "limited by system firmware"` events ramping from 0 (through Jun 3)
  to ≥500/day from Jun 4 onward. Two external MDs (Jonathan Moss,
  cited as `win11-64-24h2-hw-cpu-throttle-regression-2026-06.md` and
  `nar-win11-24h2-hw-firmware-throttle-investigation-2026-06-11.md`)
  argued this was nuc13 firmware/PSU throttling (hardware).
- **Step 1 (distribution):** Jun 10 = 50/50 active nodes scored <23 in a
  tight 1.7-pt band. 100% uniform, not bimodal. ⇒ Not per-node hardware.
- **Step 2 (t-nuc12 control):** t-nuc12 in same DC was clean. ⇒ Not
  facility-wide hardware. (This is the cited MDs' own control.)
- **Step 3 (fleetbench cross-check):** fleetbench 900s on perf-debug
  024/059 the same window held full turbo, no throttle. Bad nodes
  throttled as always (per-node bimodal hardware). ⇒ Confirmed:
  not hardware.
- **Throttle "onset" date analysis:** The Papertrail "0 → ≥500" cliff
  on Jun 4 is a query / retention artifact (Pitfall 2 in
  `references/throttle-event-analysis.md`). The same Event 37 / P11+P15
  pattern is present in the local `cpu_audit.ps1` archive from
  2026-03 / 04, hundreds of events per node. Throttle is chronic, not
  new.
- **Step 5 (same-binary retrigger):** A June-4 shippable build re-run
  on Jun 11 scored 24.52 (HEALTHY, task `UzKOQIH4SMqk9Ytqa4PItQ`,
  nuc13-119). Old build re-run NOW = HEALTHY ⇒ cause is in the build
  ⇒ **CODE.** Perfherder alert #50783 is valid.
- **Net:** Regression B = code. Hardware throttle is real and chronic
  but is a separate, coexisting issue. NaR Regression A (~Jun 1) is
  separately environmental (see below).

## Worked example: the NaR Regression A (~Jun 1)

- **Symptom:** SP3 `windows11-64-24h2-nightlyasrelease`, mozilla-central
  signature 5273122. The high-cluster runs (≥23.5) faded out ~Jun 2;
  last fast run Jun 2 21:44 (rev e4f9cbec7226). Mean didn't move (NaR
  mean ~22.5 throughout) so no Perfherder alert was filed.
- **Bimodality within-revision:** rev 71e37c8757f8 (May 31) had 2 fast
  runs and 13 slow runs → bimodality is a *per-run runtime condition*,
  not a code diff.
- **Step 5 (same-binary retrigger):** an old May-31 NaR build re-run on
  Jun 11 scored LOW (RELOPS-2396 §3p / §3q). Old build re-run NOW =
  LOW ⇒ cause is in the *runtime* ⇒ **ENVIRONMENT.**
- **Footprint analysis:** subtests show cpuTime +191%, Charts +64%,
  Stockcharts +42%, MajorGC +44%, DOM/JS flat. Near-identical to
  Regression B's footprint (RELOPS-2396 §3o). Mechanism: graphics-render
  CPU work ~3× normal; DOM/JS unaffected.
- **Leading candidate:** Remote Settings / Nimbus / server-side feature
  gate change — runtime-fetched, channel-targeted, no Gecko landing
  ⇒ no clean Perfherder culprit.
- **Net:** Regression A = environmental. Cause not yet root-caused as
  of 2026-06-12 but proven not-hardware and not-build.

## Common traps

### Trap: equating high Event 37 counts with a regression cause

A node can have 400 Event 37 records in 7 days and still hold its SP3
score in the fleet-median band; conversely, a fleet-uniform SP3 step
can happen with no change in fleet-wide Event 37 rates. Throttling is a
chronic per-node condition; a step regression is a fleet event. Don't
project from one to the other.

### Trap: reading throttle as cause when it's symptom

A code change that increases CPU work per SP3 run will itself raise
package temps and trigger more firmware-throttle events. cpuTime +83%
on the same-binary case (Regression B comparison) is exactly that
shape. Throttle events can be a *symptom* of a software regression,
not its cause. Use Step 5's same-binary retrigger to break the
direction of causality.

### Trap: Perfherder alert ≠ root cause confirmation

Perfherder pins a time-series step to whatever push ran at that
wall-clock time. An environmental step that flips at, say,
2026-06-10 14:00Z will be pinned to whatever code landed in the
nearest culprit window. Without the Step 5 same-binary retrigger, a
Perfherder alert is *circumstantial* evidence of a code regression,
not proof.

### Trap: Within-build bimodality assumed to be hardware

Same build, same node, two scores 22 and 24.7 — looks like the node
is intermittently failing. Causes seen in practice:
- WdFilter active vs inactive that session
  (`references/defender-realtime-disable.md`).
- Intermittent runtime condition (gfx fast-path / fallback, runtime-
  fetched config sync timing).
- Genuine throttle that fires during one run window but not the other.

Rule out all three before concluding "this hardware unit is bad". The
nuc13-059 GeckoProfiler hi/lo analysis (RELOPS-2396 §3m) is the
canonical example of this disambiguation: both runs throttled equally
(Event 37 = 4 each), backend was WebRender/ANGLE/D3D11 in both, the
low run simply did ~2.7× more CPU work — purely software /
workload nondeterminism, not hardware.

### Trap: shippable vs NaR conflation

The combined `os=windows&repository=autoland` view sums two channels
with very different baselines. Always split the view before reasoning
about percentages. NaR runs ~22.5 fleet-wide as a build/config
characteristic; you cannot read "X% of runs <23" from a combined view
and learn anything about node health.
See `references/throttle-event-analysis.md` Pitfall 4.

### Trap: PSU swap as a default action

PSU swap stock is finite (IO-3697 sourcing has been a recurring
bottleneck). Every brick used on a misdiagnosed node is one not
available for a confirmed-bad node. Validate with **both** fleetbench
AND Event 37 audit before recommending a swap.

## Definitive Step 5 procedure

When you need to settle hardware-vs-code-vs-environment, the
same-binary retrigger is the cleanest discriminator. The exact recipe:

1. Pick a pre-regression revision (one known to score in the healthy
   band, ideally from a Perfherder daily-trend chart).
2. Pick a candidate node — for "is this hardware?", pick the affected
   node; for "is this code or environment?", pick a node that's NOT
   currently throttling (perf-debug 024/059/119 are the
   canonical-good).
3. Retrigger the SAME task label on that node, NOW. (Tools: `mach try`
   `--worker-override` to pin to perf-debug, or Treeherder
   retrigger-with-different-revision.)
4. Read the result:
   - HEALTHY (old build now = original-era score) → variable is the
     build → code regression. Confirm with Perfherder culprit range.
   - LOW (old build now = current low score) → variable is the
     runtime → environmental. Look for runtime-fetched config /
     Remote Settings / Nimbus.
   - MIXED → intermittent runtime condition; needs more retriggers /
     deeper investigation.

The retrigger must be the SAME revision. If the underlying build
artifact (target.zip) is gone (Taskcluster artifact expiry), grab the
same Gecko rev from try and re-build, then retrigger.

## When this is NOT the right reference

- You already know it's hardware (a specific node has a fleetbench BAD
  verdict and a high Event 37 count) → skip the playbook, go to
  `references/psu-fleetbench-detection.md` §"PSU swap validation".
- You're triaging a non-perf regression (test failures, timeouts,
  tooltool errors) → that's a worker reliability issue, not a perf
  regression. RELOPS-2185 (tooltool failures) and RELOPS-2186 (Google
  Docs browsertime timeouts) are non-perf-debug tickets.
- You're triaging a regression on Linux Moonshots or macOS workers —
  the *shape* of the ladder generalizes but the tools (fleetbench works
  on Linux, but Event 37 is Windows-specific; t-nuc12 is not the right
  Linux control) do not.

## Citations

- Three-bucket framework + worked examples: RELOPS-2396 §3k, §3l, §3m,
  §3n, §3o, §3p, §3q. Read those sections in order to follow the
  evolution of the June-10 investigation.
- t-nuc12 as control: `win11-64-24h2-hw-cpu-throttle-regression-2026-06.md`
  §"Control group".
- Same-binary retrigger discrimination logic: RELOPS-2396 §3p, §3q.
- Within-build bimodality (Defender / runtime / throttle separation):
  RELOPS-2396 §3m (nuc13-059 GeckoProfiler hi/lo).
- Perfherder alert as time-pin, not cause confirmation: RELOPS-2396
  §3p ("wall-clock artifact").
- Channel-mix pitfall: RELOPS-2396 §1.3.

## Volatile / dated facts

- **As of 2026-06-12:** Regression A's environmental cause is not yet
  root-caused — leading candidate is Remote Settings or Nimbus runtime
  config. Regression B (#50783) culprit range is documented in
  Perfherder, attribution to the specific patch within autoland push
  range 1941906→1941961 is still ongoing.
- The June-10 worked example is the most recent and best-instrumented
  case; future regressions will follow the same ladder but their
  resolution will become the new worked example.

## Structural / durable facts

- The ladder (distribution → t-nuc12 control → fleetbench →
  hardware battery → same-binary retrigger) is fleet-shape-independent.
  It will work for the next NUC13-class hardware refresh too — only
  the control hardware identity changes.
- The same-binary retrigger is the only definitive separator of code
  vs environment. Without it, you have correlation only.
- Hardware regressions are per-node-bimodal; code/env are uniform.
  This signature distinction is robust across the documented history
  of this fleet.
- Treating Perfherder alerts as causation-confirming without a
  retrigger has been the most common error in this domain.
