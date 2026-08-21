# Fleet topology — NUC13 hardware, pools, ronin_puppet wiring

Durable structural reference for the `win11-64-24h2-hw*` worker fleet. Pool
membership and the active ronin_puppet HEAD change frequently; the structure
described here is stable.

## Hardware class

- Intel NUC13 Pro / Performance kit. CPU: **i5-1340P** (Raptor Lake, 16 logical
  / 12 physical, base 1900 MHz, 4 P-cores + 8 E-cores). Boost ceiling is the
  i5-1340P stock 4.6 GHz. iGPU: Iris Xe (96 EU / 12 Xe-cores). 16 GB DDR4
  SO-DIMM, NVMe SSD.
- Procs 11 and 15 are the two highest-numbered P-cores in `Win32_Processor` ID
  ordering and are the pair flagged in every Event 37 "limited by system
  firmware" record on this hardware. See `references/throttle-event-analysis.md`
  §"P11+P15 symmetry".
- Power: external 19V/120W or 19V/90W brick (Mozilla fleet shipped with a mix —
  IO-3697 / RELOPS-2341 documents the mix as the underlying degradation
  driver). The 90W bricks are the failure-prone subset. Standardisation on
  120W is the operational fix (RELOPS-2341, RELOPS-2396).
- Approximate fleet size: ~160 NUC13 (`nuc13-001` … `nuc13-160`), plus a
  separate, smaller `t-nuc12-NNN` (NUC12) population also in MDC1. The NUC12
  nodes are a **different hardware class** and a separate FQDN root; they
  share the datacenter and PDU plane but not the PSU model and do NOT exhibit
  the firmware throttle. They are the canonical "same DC, other hardware"
  control group (see `references/perf-debug-investigation-playbook.md` §"Fleet
  scope").
- Location: MDC1, racks IT46 and IT47. Exhaust fans installed 2026-03-31
  (IO-3684); perforated tiles 2026-04-02 (IO-3685). Neither materially
  changed perf (RELOPS-2323 timeline).

## FQDN convention

```
nuc13-NNN.wintest2.releng.mdc1.mozilla.com
t-nuc12-NNN.wintest2.releng.mdc1.mozilla.com
```

The `wintest2` subdomain is shared with `t-nuc12-*` (the NUC12 nodes).
Historical name `maas.releng.mdc1.mozilla.com` was renamed to `wintest2.…`
under IO-2736 (2024-02). Any tooling that constructs hostnames should generate
the `wintest2…` FQDN, not the bare `nucNN-NNN`.

## Worker types and role/profile mapping

All six hw worker types share the NUC13 hardware class. They differ in pool
membership, image pin (in `worker-images/provisioners/windows/MDC1Windows/pools.yml`),
and the ronin_puppet branch/hash they apply.

| Taskcluster worker type | Ronin role class | Purpose |
|------------------------|------------------|---------|
| `win11-64-24h2-hw` | `roles_profiles::roles::win116424h2hw` | MAIN production CI pool (largest). Default destination for healthy nodes. |
| `win11-64-24h2-hw-alpha` | `roles_profiles::roles::win116424h2hwalpha` | Quarantine / "poorly-performing" / staging for validation. Nodes move here when fleetbench classifies BAD, or when SP3 autoland deficits track per-node (see RELOPS-2396 §1.4). |
| `win11-64-24h2-hw-perf-debug` | `roles_profiles::roles::win116424h2hwperfdebug` | Small reference set (3–5 nodes) used as the canonical-good baseline for fleetbench and as the proving ground for new ronin_puppet branches before they reach MAIN. As of 2026-06-12: `nuc13-024, -059, -119` (RELOPS-2396 §4h). |
| `win11-64-24h2-hw-perf-sheriff` | `roles_profiles::roles::win116424h2hwperfsheriff` | Perf-sheriff regression-bisect pool. Same hardware, different image / ronin pin lifecycle. |
| `win11-64-24h2-hw-ref` | `roles_profiles::roles::win116424h2hwref` | "Reference" hardware — historically the SP3-only pool; reduced test set, runs `browsertime-benchmark` only. (Historically used NUC12 hardware in some configurations; verify current pin in `pools.yml` before assuming.) |
| `win11-64-24h2-hw-relops1213` | `roles_profiles::roles::win116424h2hwrelops1213` | RelOps-only test/burn-in pool. Not pinned to production code, used as a staging area for hardware that's just come back online. |

The `worker-images` `pools.yml` pool name maps to the worker type one-to-one
(hyphenated). The role class name is the underscored form with no hyphens.

## Source-of-truth files in ronin_puppet

Paths are repo-relative.

### Roles & profiles

- `modules/roles_profiles/manifests/roles/win116424h2hw.pp` — MAIN role.
  Includes the hardware-only profiles below.
- `modules/roles_profiles/manifests/roles/win116424h2hwalpha.pp`,
  `…hwperfdebug.pp`, `…hwperfsheriff.pp`, `…hwref.pp`, `…hwrefalpha.pp`,
  `…hwrelops1213.pp` — the six other roles. All include
  `profiles::hardware_observability` (so all hw nodes get NSClient/Marlin +
  fleetbench).

### Hardware-only profiles

Present in the hw roles, absent from any `azure` worker role:

- `modules/roles_profiles/manifests/profiles/hardware.pp` — firmware
  assertions, power-plan / Core Parking / USB selective-suspend bits.
- `modules/roles_profiles/manifests/profiles/hardware_observability.pp` —
  installs/configures NSClient++ for the Marlin/Icinga2 path, includes
  `win_fleetbench::init`.
- `modules/roles_profiles/manifests/profiles/nuc_management.pp` — maintenance
  scripts (PXE reinstall trigger, pool audits, fleet roll).
- `modules/roles_profiles/manifests/profiles/nuc_bios.pp` — NUC13 BIOS
  update mechanism (sources / hashes / target date pinned in hiera).
- `modules/roles_profiles/manifests/profiles/disable_services.pp` — Defender,
  SmartScreen, sync-from-cloud disables. Datacenter branch is the hw-only
  case; see `references/defender-realtime-disable.md` §"How it's wired".

### Modules that this skill touches most often

| Module | What it does | Key files |
|--------|--------------|-----------|
| `win_fleetbench` | Installs the fleetbench cpu binary, ships the wrapper + baselines JSON to `C:\fleetbench\`. | `manifests/init.pp`, `files/run_fleetbench.ps1` (manual-run wrapper, superseded by maintain-script for scheduled runs), `files/fleetbench_baselines.json` (per-hardware-type thresholds, see `references/psu-fleetbench-detection.md`). |
| `win_scheduled_tasks` | The startup-task PowerShell scripts. The hardware fleet runs `maintainsystem-hw.ps1`; azure uses `maintainsystem.ps1`; reftester uses its own. | `files/maintainsystem-hw.ps1` — contains `Invoke-FleetbenchCheck`, `Get-FleetbenchVerdict`, `Get-FleetbenchVariance`, `Invoke-DefenderRealtimeGuard`, `CompareConfigBasic`, `Set-PXE`, `Write-Log`. Cadence gate currently 72h (production, set in `e1156872` per RELOPS-2396 §3i). |
| `win_nsclient` | NSClient++ → Marlin (NRPE) check scripts. | `files/check_fleetbench.ps1`, `check_fleetbench_variance.ps1`, `check_defender.ps1`, `check_thermal.ps1`, `check_thermal_hp.ps1`, `worker_pool_id.ps1`, `worker_bootstrap_stage.ps1`. `templates/nsclient.ini.epp` registers the NRPE aliases. |
| `win_disable_services` | Defender / SmartScreen / sync-from-cloud disables. | `manifests/disable_windows_defender.pp` (registry-only; effective only when Tamper is off), `disable_windows_defender_schtask.pp` (the `.sys` rename via takeown; the Tamper-on lever), `disable_defender_smartscreen.pp`. |
| `win_bios` | NUC13 BIOS pin and updater. | `manifests/nuc13.pp`. BIOS version + source URL pinned in `data/os/Windows.yaml` under `windows.bios.NUC13`. |
| `win_hw_profiling` | xperf kernel tracing on hw for perf data collection. | `files/xperf_kernel_start.ps1` (last touched by RELOPS-2321, `edef6331`). |
| `win_shared` | Custom facts. | `facts.d/facts_win_location.ps1` returns `aws` / `azure` / `datacenter`. The `datacenter` branch is what this skill cares about. |

### Hiera

Windows uses a separate hiera hierarchy from Linux/macOS — keyed by the custom
fact `custom_win_gw_workertype` (`win_hiera.yaml`). For hw nodes the relevant
files are:

```
data/os/Windows.yaml                                          # global Windows defaults — fleetbench install_dir / results_dir / pinned version, BIOS pin (windows.bios.NUC13), package versions
data/os/Windows/worker/win11-64-24h2-hw.yaml                  # MAIN overrides
data/os/Windows/worker/win11-64-24h2-hw-alpha.yaml            # alpha overrides
data/os/Windows/worker/win11-64-24h2-hw-perf-debug.yaml       # perf-debug overrides
data/os/Windows/worker/win11-64-24h2-hw-ref.yaml              # ref overrides
data/os/Windows/worker/win11-64-24h2-hw-perf-sheriff.yaml     # perf-sheriff overrides
data/os/Windows/worker/win11-64-24h2-hw-relops1213.yaml       # relops1213 overrides
data/secrets/vault.yaml                                       # vault-managed secrets
data/common.yaml                                              # global defaults
```

Rule (durable): **Hiera lookups happen only in profiles**, then values are
passed as class parameters to modules. Do not add `lookup()` calls inside
component modules. Roles cannot include other profiles directly (except base
OS profiles).

## Worker-images: how pool wiring works

The only repo that determines which ronin_puppet commit each pool runs is
`mozilla-platform-ops/worker-images`. The file is
`provisioners/windows/MDC1Windows/pools.yml`. For each `win11-64-24h2-hw*`
pool you'll see:

```
- pool: win11-64-24h2-hw-perf-debug
  image: win11-24H2-NUC-01-16-2025
  src_Repository: ronin_puppet
  src_Branch: <branch>
  hash: <git short sha>
  openvox_version: 8.19.2
  puppet_version: 8.10.0
  git_version: 2.50.0
  nodes:
    - nuc13-024
    - nuc13-059
    - nuc13-119
```

How a hash bump propagates to nodes: `maintainsystem-hw.ps1` runs
`CompareConfigBasic` at every boot, downloads `pools.yml` via authenticated
GitHub raw URL (using the PAT at `D:\Secrets\pat.txt`), and compares the
pool's `hash:` against the value in HKLM registry. On mismatch it calls
`Set-PXE` to set the UEFI next-boot to PXE and reboots → the next boot
rebuilds the image and applies puppet at the new hash. CI nodes reboot
frequently, so a hash bump propagates fleet-wide within a normal CI cycle.

### Pool moves

Moving a node between pools (e.g., perf-debug → alpha, alpha → main) is a
`pools.yml` edit only — remove from the source `nodes:` list, insert in the
destination `nodes:` list at the numerically correct position, push direct to
`main` (the established pattern: RELOPS-2396 §1.8, §4h). Branch-protection
bypass is the documented pattern for these inventory edits.

Do NOT also edit the source/destination pool's `src_Branch` / `hash` in the
same commit unless that's the explicit intent — those two edits are
independent and conflating them makes the change history hard to read.

## Bootstrap & maintain flow (hw branch)

Reading `modules/win_scheduled_tasks/files/maintainsystem-hw.ps1` is the
fastest way to understand what a hardware node does at each boot. The
`bootstrap_stage == complete` branch (steady-state, post-first-boot) does, in
order:

1. `CompareConfigBasic` — downloads `pools.yml`, validates worker pool ID +
   git hash + image dir against HKLM. PXE-reboots on mismatch.
2. `Run-MaintainSystem` — purges `C:\logs\old` of files older than 7 days.
3. Confirms a `task_*` user is logged in (3 retries).
4. `Test-ConnectionUntilOnline` — waits up to 120s for network.
5. `Invoke-DefenderRealtimeGuard` (added per RELOPS-2396 §4e in commit
   `d945f0bd`) — re-renames any restored `WdFilter/WdBoot/WdNisDrv` `.sys`,
   attempts `fltmc unload`, reboots ONCE under Tamper if WdFilter still
   running (boot-loop guarded by marker file, MaxReboots=1, CooldownMin=60).
   Writes `C:\fleetbench\results\defender_status.json`.
6. `Get-LatestGoogleChrome` — Chocolatey upgrade if outdated; PXE on failure.
7. `Wait-ForUserInitReady` — polls `MOZ_GW_UI_READY` env up to 1200s.
8. `Invoke-FleetbenchCheck` — cadence-gated (72h prod, 1h test). Runs
   `fleetbench cpu --mode quick --duration 900s --json`, writes
   `<UTC-ts>_<COMPUTERNAME>_cpu.json` to `C:\fleetbench\results\`, runs
   `Get-FleetbenchMetrics` → `Get-FleetbenchVerdict` → `Get-FleetbenchVariance`,
   writes `fleetbench_status.json`. Never throws.
9. `StartWorkerRunner` — checks user-profile corruption events (1511/1515),
   starts the `worker-runner` service.

Key invariants:

- Steps 5 (Defender), 8 (fleetbench), 9 (worker-runner) all run *to completion*
  before any CI task is dispatched. fleetbench's 900s torture therefore runs
  on an idle node, not over a live task.
- `Invoke-FleetbenchCheck` and `Get-FleetbenchVariance` both glob
  `C:\fleetbench\results\*_cpu.json` (not `*.json`). This is the §4g fix
  (`e75fd9e7`) — globbing `*.json` would also match the `defender_status.json`
  / `fleetbench_status.json` sibling files and trip the cadence gate forever.
  Any new sibling status file in that directory must NOT match `*_cpu.json`.

## Marlin / NSClient++ wiring

- NSClient++ on each hw node listens on TCP 12489 (NRPE-style). Aliases are
  registered in `nsclient.ini.epp`. Current relevant aliases:
  `worker_pool_id`, `worker_bootstrap_stage`, `screen_res`, `thermal`,
  `thermal_hp`, `fleetbench`, `fleetbench_variance`, `defender`.
- Each alias is implemented by a PS1 in `modules/win_nsclient/files/`.
- `check_fleetbench.ps1` reads `C:\fleetbench\results\fleetbench_status.json`
  (does NOT run the benchmark itself) and emits Nagios state + perfdata
  (`health` 0/1/2/3, `min_pct`, `mean_pct`, `tput_cv`, `iters`, `age_h`).
- `check_fleetbench_variance.ps1` likewise reads the variance fields
  (`var_min_delta`, `var_mean_delta`, `var_iter_pct`, `first_run`).
- `check_defender.ps1` is **live authoritative** — it queries WdFilter
  service / driver state directly, returning CRITICAL if WdFilter is running
  or the `.sys` was restored.
- Marlin (`mozilla-platform-ops/marlin`, branch typically `RELOPS-2402-*`)
  registers the matching service apply in `services-win.j2`. Landing is via
  PR + `./marlin.sh run-icinga2`. PRs #18 (health), #19 (variance) are merged
  as of 2026-06-12.
- Grafana / Yardstick "Windows" folder hosts the combined "Windows Fleetbench"
  dashboard (`windows-fleetbench-health-v1`). Per-pool rows are collapsed by
  default; the rightmost column is `Variance Δ (min %base)` (color-graded,
  negative=worse). Data flows from NSClient → Icinga2 → InfluxDB
  (`marlin-icinga2`) → Grafana.

## When this is NOT the right reference

- You're chasing a Talos / Raptor / Browsertime harness bug — that's gecko-test
  code, not worker. The harness paths and SP3 task structure are out of scope
  here; see `testing/raptor/` / `testing/talos/` in mozilla-central.
- You're trying to understand the *PXE server* (DHCP option-66 / TFTP /
  helper-IP / MDT / MAAS) side of provisioning. That's IO-2628 / IO-2505 /
  IO-2523 territory, networking team owns it. This skill only covers
  *triggering* a reimage from the node side (`Set-PXE`, hash-mismatch,
  CompareConfigBasic).
- You're touching the Azure / cloud Windows worker image
  (`win11-64-24h2`-non-hw, `…azure`). Those go through Packer
  (`worker-images/azure.pkr.hcl` / `gcp.pkr.hcl`), have no `custom_win_location
  == datacenter` profile chain, and don't run `maintainsystem-hw.ps1`. None
  of this skill's signals apply.

## Citations

- Repo layout, hiera split, hw-only profiles, custom_win_location:
  ronin_puppet `CLAUDE.md` and `modules/win_shared/facts.d/facts_win_location.ps1`.
- Worker types and pool composition: RELOPS-2396 worklog §1.4, §1.7, §1.8,
  §4h; `worker-images/provisioners/windows/MDC1Windows/pools.yml`.
- maintainsystem-hw flow: NOTES.md "maintainsystem-hw.ps1" entry;
  RELOPS-2396 §3e, §3f, §3h, §4e, §4g; `modules/win_scheduled_tasks/files/maintainsystem-hw.ps1`.
- BIOS pin: RELOPS-2396 §2.4, §2.6; `modules/win_bios/manifests/nuc13.pp`.
- NSClient → Marlin: NOTES.md, RELOPS-2396 §2.5, §3g, §3j, §4e.
- FQDN convention: `cpu_audit.ps1` / `StressCPU.ps1` hostname construction;
  IO-2736 (rename); NOTES.md "Fleet Structure Notes".
- t-nuc12 as control: `win11-64-24h2-hw-cpu-throttle-regression-2026-06.md`
  §"Control group"; RELOPS-2396 §3k.
- PSU mix (90W / 120W): NOTES.md "PSU mix (2026-04-16)"; perf-ops timeline
  2026-04-16; RELOPS-2341.

## Volatile / dated facts (re-verify before quoting)

- As of 2026-06-12: ronin `RELOPS-2396` HEAD = `e75fd9e7`; worker-images
  `main` HEAD = `d96b8fdf`; perf-debug pool = `nuc13-024, -059, -119`;
  cadence gate set to 72h production. These all change frequently — re-read
  the relevant `pools.yml` and `git log` before acting.
- The canonical-good fleetbench reference cluster is currently 7 nodes
  (perf-debug 024/059/119 + alpha 111/129/131/152). When you add or replace
  nodes, the baseline in `fleetbench_baselines.json` is the source of truth
  for thresholds; the *identity* of the reference nodes is volatile.
- The "good" baseline cluster identity drifts when (a) hardware swaps land,
  (b) Defender platform updates flip WdFilter back on, (c) any node fails
  out. Treat any specific node name in this file as illustrative.
