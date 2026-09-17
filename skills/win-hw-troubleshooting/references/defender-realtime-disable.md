# Windows Defender real-time disable — Tamper Protection, WdFilter, and the boot race

The NUC13 fleet must run with Defender real-time / on-access scanning
effectively off — leaving it active inflates CI task CPU and is a documented
contributor to bimodal SP3 scores. The disable mechanism is constrained by
Windows 11 24H2's **Tamper Protection**, which is enforced and not
disableable from inside the OS. This file documents how Defender is wired
on the hw fleet, the WdFilter boot race that produces per-node, per-boot
intermittency, and the lever inventory under Tamper.

This material is RELOPS-2396 §4a–§4f territory. The mechanism is durable
even as commits churn; the file names and line numbers change.

## How it's wired (ronin_puppet)

Role `roles_profiles::roles::win116424h2hw` includes
`profiles::disable_services`. The hw branch (datacenter case) of that
profile, after RELOPS-2396 §4e, **explicitly** includes both:

- `win_disable_services::disable_windows_defender_schtask` — the `.sys`
  rename mechanism (works under Tamper).
- `win_disable_services::disable_windows_defender` — the registry-policy
  path (effective only when Tamper is off).

Before §4e, the schtask include rode on a `release_id in ['2004','2009']`
gate intended for the ref image. That gate fires on the Win11 24H2 hw
fleet by coincidence — Win11 freezes `ReleaseId` at 2009 (confirmed live
on 059/119/024). The §4e fix decoupled the hw fleet from that coincidence
by adding an explicit `include` in the datacenter branch.

A separate include `disable_defender_smartscreen` (datacenter,
unconditional) handles SmartScreen — that is a **different feature** from
the AV engine. SmartScreen disable does NOT affect Defender real-time
scanning.

Note: `win_disable_services::disable_windows_defender` was historically
dead code (never `include`d, exec commented out). §4e rewrote it as a
registry-only manifest and wired it in.

## What's writable under Tamper Protection (verified live, RELOPS-2396 §4e-bis)

The "all the levers we can pull in puppet" probe on `nuc13-119` produced:

| Lever | Writable under Tamper? | Notes |
|-------|------------------------|-------|
| `HKLM\…\Policies\Microsoft\Windows Defender\Exclusions\Paths` (GP path exclusions) | YES | Re-asserted by `Invoke-DefenderRealtimeGuard` every boot — neutralises on-access scan cost during the WdFilter-loaded window even before the reboot. |
| `HKLM\…\Services\Sense\Start = 4` (EDR service) | YES | The only Defender-family service whose `Start` value is writable. |
| Defender scheduled tasks (`Scan`, `Cleanup`, `Cache`, `Verification`) | YES | Disabled via exec with `onlyif` guard. |
| `WinDefend / WdFilter / WdNisSvc / WdBoot / WdNisDrv` service `Start` | **NO** | `sc config <name> start= disabled` → "Access denied" (5). |
| `Set-MpPreference` cmdlet | **NO** | Returns "Provider load failure" once `WdFilter.sys` is renamed. Defender becomes unmanageable via standard cmdlets. |
| `HKLM\…\Features\TamperProtection = 0` | **NO** | "Requested registry access is not allowed" (self-protecting). |
| `fltmc unload WdFilter` | **NO** | `0x801f0010` "Do not detach the filter from the volume at this time". |
| `HKLM\…\Policies\Microsoft\Windows Defender\DisableAntiSpyware = 1` (and related `Real-Time Protection\*` values) | YES (writable) | But **Defender ignores them while Tamper is on**. Effective only on Tamper-off images. Set as best-effort intent. |

Net under Tamper: the **only** mechanisms that change real-time scanning
state are (a) renaming the driver `.sys` files via takeown (which is below
Tamper's purview because Tamper protects the running process / registry,
not the filesystem), and (b) rebooting after the rename.

## The rename mechanism (`disable_windows_defender_schtask`)

The schtask, installed by `disable_windows_defender_schtask.pp`, runs at
boot and uses `takeown /F <path> /A` + ACL changes to gain write access on
the protected driver files, then renames:

- `C:\Windows\System32\drivers\WdFilter.sys` → `WdFilter.sys.bak`
- (And similarly `WdBoot.sys` / `WdNisDrv.sys` per RELOPS-2396 §4e.)

On the next boot the driver fails to load → on-access scanning is off
fleet-wide and `Set-MpPreference` returns "provider load failure".

The catch is the **timing**: the schtask runs *after* boot (typically ~12s
into boot — verified on nuc13-119: LastBootUpTime 05:47:13, schtask 05:47:25),
but `WdFilter.sys` is a **boot-start minifilter**. It loads at boot,
*before* the schtask runs and renames the `.sys`. The rename only affects
the *next* boot.

## The boot race (RELOPS-2396 §4c, key finding)

If `WdFilter.sys` exists at boot, it loads and attaches to the volume
filters; the schtask then renames the `.sys` but the driver is already
loaded → **real-time scanning is active for that session despite the
`.sys` being renamed**. Cleared on the next boot (when the rename takes
effect at boot-time).

This produces per-node, per-boot intermittency. Documented live state on
2026-06-12 (RELOPS-2396 §4c):

- `nuc13-119`: WdFilter RUNNING, 38 instances, attached to C:, D:,
  `\Device\Mup`. On-access scanning ACTIVE.
- `nuc13-059`: WdFilter STOPPED (clean).

The difference: whether a Defender platform update (delivered via Windows
Update / cloud) restored `WdFilter.sys` between the last boot and this
one. The schtask is run-once-per-boot; if the update lands mid-session,
the next boot resurrects WdFilter. CI nodes self-correct on each reboot
(absent a fresh restore).

**Perf relevance:** WdFilter active vs inactive flips per boot exactly
like SP3 fast/slow path → this is a *strong candidate contributor to the
bimodal scores* and run-to-run variance. The 119(active) vs 059(clean)
pairing is a natural A/B and is exactly what RELOPS-2396 §3m used for the
GeckoProfiler hi/lo investigation.

## `Invoke-DefenderRealtimeGuard` (maintain script, after RELOPS-2396 §4e)

Lives in `modules/win_scheduled_tasks/files/maintainsystem-hw.ps1`. Called
once per boot after `Test-ConnectionUntilOnline`, before the user-init
wait / fleetbench / worker-runner. The function:

1. **GP exclusions step (always):** asserts the blanket `C:\` and `D:\`
   path exclusions in
   `HKLM\…\Policies\Microsoft\Windows Defender\Exclusions\Paths`,
   `Exclusions_Paths = 1`. Reduces on-access scan cost even while
   WdFilter is loaded.
2. **Rename step:** re-renames any restored `WdFilter.sys` / `WdBoot.sys` /
   `WdNisDrv.sys` via takeown. This ensures the *next* boot is clean.
3. **Unload step:** attempts `fltmc unload WdFilter`. Succeeds only if
   Tamper happens to be off (image-side); blocked under Tamper.
4. **Reboot step:** if WdFilter is still running and Tamper is on, reboots
   the node ONCE to clear the live minifilter. Boot-loop guarded with a
   marker file: **MaxReboots=1, CooldownMin=60**. Without the guard, a
   newly-restored `.sys` would cause every boot to reboot again.
5. Writes `C:\fleetbench\results\defender_status.json` with the action /
   reboot history. Never throws.

The status file is consumed by NSClient `check_defender.ps1`
(authoritative live check: CRITICAL if WdFilter is running OR the `.sys`
was restored). Surfaced in Marlin and Grafana ("Windows Fleetbench"
dashboard, Defender column).

## File-naming gotcha (RELOPS-2396 §4g)

`defender_status.json` lives in `C:\fleetbench\results\` alongside the
fleetbench envelopes (`<UTC-ts>_<COMPUTERNAME>_cpu.json`). When
`Invoke-FleetbenchCheck` and `Get-FleetbenchVariance` globbed `*.json`,
they treated `defender_status.json` as "newest fleetbench result" and
the cadence gate skipped forever (age 0h ≪ 72h). The §4g fix tightened
both globs to `*_cpu.json` (commit `e75fd9e7`).

**Rule:** any new sibling status file in `C:\fleetbench\results\` must NOT
match the `*_cpu.json` glob. Name it like `<feature>_status.json` or
`<feature>_<host>.json`. Do not name it `<ts>_<host>_<anything>_cpu.json`
or you'll trip the cadence gate again.

## What still needs an image-side fix (RELOPS-2396 §4f)

The cleanest disable is **Tamper Protection off in the image**
(osdcloud / MDM). With Tamper off, the supported registry policy and
`Set-MpPreference` paths work, Defender is manageable via standard
cmdlets, and the WdFilter boot race goes away (the `.sys` rename + reboot
dance is unnecessary). This requires image-team action; the in-OS
mitigation (`Invoke-DefenderRealtimeGuard` + reboot guard) is the
workaround until then.

Open work item: image-team ticket for "disable Tamper Protection in the
NUC13 hw image". As of 2026-06-12 not yet filed.

## Operational triage

Symptom → first move:

- **`check_defender.ps1` reporting CRITICAL on a node** → Defender real-time
  is active *right now*. Verify with `Get-Service WdFilter` (Status =
  Running) and `fltmc filters` (lists WdFilter). The maintain-script's
  reboot guard handles this on next boot if applicable; the live session
  cannot be cleared (Tamper blocks `fltmc unload`).
- **Reboot loop on a node** → check `defender_status.json` and the marker
  file. The `MaxReboots=1, CooldownMin=60` guard should prevent a true
  loop; if it's looping, the marker file isn't being honoured (file
  permissions, path drift) — that's a code bug, not an expected state.
- **Bimodal SP3 within-build, same node** → the WdFilter flip is the
  leading candidate. Confirm via the boot-time `defender_status.json`
  history for that boot pair, OR the `check_defender` NRPE timeseries in
  Marlin around the run windows.
- **`Set-MpPreference` errors with "Provider load failure"** → expected
  state when `WdFilter.sys` is renamed. Defender is unmanageable via
  cmdlets in this state; do not treat the error as a problem.
- **Defender platform update appears to have restored `WdFilter.sys`** →
  the schtask + maintain guard will catch it on the next boot. If it
  doesn't (next boot still shows WdFilter running), inspect the schtask
  execution log and confirm the rename completed.

## "When this is NOT the problem"

- The node has Tamper Protection OFF (e.g., a future image change) →
  Defender is manageable via standard cmdlets, the rename mechanism is
  unnecessary, and the schtask should ideally be neutralized. Verify
  Tamper state via `Get-MpComputerStatus` (works if Tamper is off and
  WdFilter is loaded as the provider).
- SP3 regression is fleet-wide synchronous → WdFilter flips are
  per-node, per-boot. A fleet-uniform regression is not a Defender
  problem.
- The node shows Defender clean (`check_defender` OK) but throttles → it's
  a separate issue (PSU / Event 37 / environment). Defender being clean
  does not rule out throttle; they are orthogonal mechanisms.
- The node is azure / cloud (`custom_win_location != datacenter`) → this
  entire file does not apply. Azure images use a different Defender
  policy chain and do not include the schtask or the maintain-script
  guard.

## Citations

- Wiring + datacenter branch + ReleaseId=2009 coincidence: RELOPS-2396 §4a.
- Live state on 059 / 119 / 024 + WdFilter boot race: RELOPS-2396 §4b, §4c.
- Tamper Protection enforcement / lever inventory: RELOPS-2396 §4d, §4e-bis.
- `Invoke-DefenderRealtimeGuard` design + reboot guard: RELOPS-2396 §4e.
- Cadence-glob regression from `defender_status.json`: RELOPS-2396 §4g
  (commit `e75fd9e7`).
- Image-side Tamper-off requirement: RELOPS-2396 §4f.

## Volatile / dated facts

- **As of 2026-06-12:** `Invoke-DefenderRealtimeGuard` is present and live
  in `modules/win_scheduled_tasks/files/maintainsystem-hw.ps1` after
  commit `d945f0bd`; `check_defender.ps1` registered as the `defender`
  NRPE alias. Marlin reporting as designed.
- WdFilter restore frequency depends on the Defender platform-update
  cadence pushed via Windows Update / cloud. That cadence is outside our
  control and varies week-to-week.

## Structural / durable facts

- Tamper Protection on Win11 24H2 is enforced and self-protecting; it
  cannot be toggled from inside the running OS. This is a Microsoft
  decision and not expected to change.
- `WdFilter.sys` is a boot-start minifilter; any "disable" mechanism that
  runs *after* boot only affects the *next* boot.
- The `.sys` rename via takeown sits below Tamper's purview because Tamper
  protects the running Defender services, registry, and live process —
  not the underlying file paths. This is why the rename works.
- The schtask + maintain-script guard are run-once-per-boot. If a fresh
  WdFilter.sys lands mid-session, the guard cannot clear it; the user
  gets one session of active scanning until the next reboot.
