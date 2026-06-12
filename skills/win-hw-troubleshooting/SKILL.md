---
name: win-hw-troubleshooting
description: |
  Troubleshooting playbook for Mozilla's Firefox CI Windows hardware fleet — Intel NUC13
  (Raptor Lake i5-1340P) nodes in the MDC1 datacenter, FQDN pattern
  `*.wintest2.releng.mdc1.mozilla.com`, worker pools `win11-64-24h2-hw*`.

  Use when investigating: Speedometer 3 (SP3) regressions on `windows11-64-24h2-shippable`
  or `…-nightlyasrelease`; bimodal / per-worker SP3 scores; Perfherder alerts pinned to
  the `win11-64-24h2-hw` pool; perf-debug / alpha / main pool reassignments; chronic CPU
  throttling on NUC13 hardware (Kernel-Processor-Power Event 37/55/48/51 / "limited by
  system firmware"); PSU degradation, brick replacement, or IO-3683/3697/3705-style
  hardware tickets; fleetbench cpu torture envelopes and the GOOD/MARGINAL/BAD classifier
  (RELOPS-2402); Windows Defender / Tamper Protection / WdFilter behaviour on the hw
  fleet; ronin_puppet `win_fleetbench`, `win_nsclient`, `win_disable_services`, or
  `win_scheduled_tasks/maintainsystem-hw.ps1` changes; Marlin (Icinga2) "Windows
  Fleetbench" / "Windows Fleetbench Variance" checks; the Grafana "Windows Fleetbench"
  yardstick dashboard.

  Also use when someone asks: "is this node bad?", "why is SP3 dropping on hw?", "is
  this a hardware regression or a code regression?", "what's RELOPS-2396 / RELOPS-2402
  status?", "how do I read a fleetbench JSON?", "what does Event 37 mean?", "how do
  I disable Defender on the NUC fleet?", or any question that mentions Marlin perf
  worker hardware, NUC13, perf-debug pool, or Speedometer 3 on shippable hw workers.

  Keywords: NUC13, NUC13 i5-1340P, perf-debug, perf-sheriff, win11-64-24h2-hw,
  win11-64-24h2-hw-alpha, win11-64-24h2-hw-perf-debug, win11-64-24h2-hw-ref,
  releng-hardware, MDC1, wintest2, fleetbench, PSU degradation, power brick,
  Kernel-Processor-Power, Event 37, Event 55, Event 48, Event 51, WdFilter,
  Tamper Protection, Defender real-time, Speedometer 3, SP3, Marlin, Yardstick,
  RELOPS-2396, RELOPS-2402, RELOPS-2323, RELOPS-2341, RELOPS-2344, IO-3683,
  IO-3697, IO-3705, Perfherder alert 50783, ronin_puppet, worker-images,
  pools.yml, maintainsystem-hw.ps1.

  DO NOT USE FOR:
    - Cloud / Azure Windows worker images (`win11-64-24h2` non-`hw`, `win10-64*`,
      `…azure`, anything where `custom_win_location == aws|azure`). Those go through
      the Packer / Azure SIG image pipeline in `worker-images/` and are unrelated
      to PSU / firmware throttling concerns.
    - Linux Moonshot / `gecko_t_linux_*` workers or any `linux_*` ronin_puppet module.
    - macOS / mac-mini / Bitbar / LambdaTest workers (`macos_*` modules,
      `gecko_t_osx_*`).
    - Non-perf hardware repairs (KVM, networking, NIC failure, switch / VLAN /
      Infoblox / PXE-server-side issues). PXE *behaviour from the node side* —
      reimage triggers, `Set-PXE`, hash-mismatch reboots — is in scope; the PXE
      server, DHCP, TFTP, and helper-IP plumbing is not.
    - Talos / Raptor / Browsertime test authoring or harness debugging (that is a
      gecko-test problem, not a worker problem). In-scope here: deciding whether
      a perf regression is *worker-caused* vs code-caused.
---

## Overview

The Firefox CI Windows hardware fleet (`releng-hardware/win11-64-24h2-hw*`) is
~160 Intel NUC13 nodes (`nuc13-001` … `nuc13-160.wintest2.releng.mdc1.mozilla.com`)
in racks IT46/IT47 at MDC1. The fleet has a known, ongoing **PSU-degradation /
firmware-throttle** failure mode (RELOPS-2323 / RELOPS-2396, IO-3683/3697/3705)
that produces bimodal Speedometer 3 scores, intermittent stalls under load, and
chronic accumulation of `Microsoft-Windows-Kernel-Processor-Power` Event 37
("limited by system firmware") records. RELOPS-2402 adds a proactive in-fleet
detector (`fleetbench cpu --duration 900s` driven from `maintainsystem-hw.ps1`,
results reported via NSClient++ → Marlin → Grafana).

This skill captures the durable knowledge needed to triage any
`win11-64-24h2-hw*` performance / hardware ticket: where in ronin_puppet the
relevant code lives, what the per-failure-mode signals look like, the
fleetbench-derived GOOD/MARGINAL/BAD thresholds, the WdFilter boot-race
mechanism, and the disambiguation playbook for "hardware vs code" perf
regressions.

## Repos involved

This work lives across three Mozilla repos. Most edits happen in `ronin_puppet`;
`worker-images` is the deployment lever; `marlin` exposes the monitoring side.

| Repo | Path / scope | Role in this domain |
|------|--------------|---------------------|
| `mozilla-platform-ops/ronin_puppet` | masterless puppet for FXCI workers; modules in `modules/`, hiera in `data/`. Hardware nodes detected by `custom_win_location == 'datacenter'` (custom fact in `modules/win_shared/facts.d/`). | All in-OS configuration of NUC13 nodes: package install, hardware-only profiles (`profiles/hardware.pp`, `profiles/hardware_observability.pp`, `profiles/nuc_management.pp`, `profiles/nuc_bios.pp`), Defender handling, fleetbench install + execution, NSClient++ → Marlin checks, BIOS pin (`modules/win_bios/manifests/nuc13.pp`). Edit branch is typically `RELOPS-2396` for current work. |
| `mozilla-platform-ops/worker-images` | `provisioners/windows/MDC1Windows/pools.yml` — per-pool `src_Repository` / `src_Branch` / `hash` pins and per-pool node lists. | The *only* lever that picks which ronin_puppet commit each `win11-64-24h2-hw*` pool runs. Bumping the `hash:` for a pool causes nodes in that pool to detect the mismatch on next maintain pass and PXE-reimage onto the new commit. Also the source of truth for pool membership (moving a node between perf-debug / alpha / main is an edit here, not in ronin). |
| `mozilla-platform-ops/marlin` | Ansible-driven Icinga2 config; `services-win.j2` defines per-host service applies, NRPE-style aliases match NSClient++ aliases set in `modules/win_nsclient/files/nsclient.ini.epp`. | Hardware monitoring surface. The NSClient++ → Marlin → InfluxDB → Grafana ("Yardstick") chain is how `check_fleetbench`, `check_fleetbench_variance`, `check_thermal*`, and `check_defender` results land on dashboards and (where wired) page. Landing changes runs through `./marlin.sh run-icinga2`. |

## When to use

Concrete triggers — any of these should make this skill the first stop:

- A Perfherder alert or autoland dashboard scrutiny lands on
  `windows11-64-24h2-shippable` or `…-nightlyasrelease` and someone is asking
  whether the cause is the workers.
- A ticket mentions NUC13, MDC1, `wintest2.releng.mdc1.mozilla.com`,
  `releng-hardware/win11-64-24h2-hw*`, or any of the pools listed in
  `references/fleet-topology.md`.
- A node is being added to, removed from, or moved between the perf-debug /
  alpha / main / ref / relops1213 hardware pools.
- A node won't reimage, repeatedly PXEs, or fails to come back online after a
  worker-images `hash:` bump.
- A `fleetbench_status.json` is reported as MARGINAL or BAD, or
  `check_fleetbench` is firing on Marlin, or the Grafana "Windows Fleetbench"
  panels show a host as BAD / drifted / UNKNOWN.
- Someone is mining Papertrail for `Kernel-Processor-Power` /
  "limited by system firmware" / Event 37 records, especially across the
  shippable vs nightly-as-release channel split.
- A PSU brick replacement is being scheduled, validated, or RMA'd
  (IO-3683/3697/3705 pattern).
- Windows Defender / WdFilter / Tamper Protection behaviour is being debated on
  the hw fleet, or a `defender_status.json` reboot loop / WdFilter active
  warning is showing up.

## Quick orientation — references/

Each `references/*.md` is a focused topic with its own signals, thresholds,
"When this is NOT the problem" subsection, and citations back to the worklog
sections / source MDs. Read the one that matches your trigger first; don't
read them all up front.

| Topic | File | Read when |
|-------|------|-----------|
| Pool/worker-type/role layout, hiera hierarchy for `Windows`, hardware-only profiles, perf-debug / alpha / main / ref split, FQDN convention | `references/fleet-topology.md` | First contact with the fleet, deciding which pool a node belongs in, or you need to know where in ronin_puppet a change should land. |
| PSU degradation theory of the fleet, fleetbench `cpu --duration` interpretation, frequency-floor / throughput-CV / max-median classifier, the 7-node canonical-good cluster, validation against alpha pool | `references/psu-fleetbench-detection.md` | A node has SP3 / SP2 / fleetbench anomaly and you need to decide PSU-degraded vs healthy, OR you're tuning thresholds / adding a new hardware-type baseline. |
| `Microsoft-Windows-Kernel-Processor-Power` Event 37 / 55 / 48 / 51 semantics, P11+P15 symmetry, Papertrail mining, shippable vs NaR channel pitfalls, "limited by system firmware" interpretation | `references/throttle-event-analysis.md` | Someone is reading throttle-event counts and reaching for a conclusion — especially if they're equating high event counts with code regressions, or treating a query-result cap as a true onset. |
| Tamper Protection enforcement, WdFilter boot-race (`.sys` rename below Tamper), `Set-MpPreference` "provider load failure", what is writable under Tamper, in-OS lever inventory | `references/defender-realtime-disable.md` | A node is producing inconsistent SP3 within-build, OR you're auditing the Defender disable path, OR `Invoke-DefenderRealtimeGuard` is rebooting / `defender_status.json` is showing CRITICAL. |
| SSH transport patterns (Windows OpenSSH `-EncodedCommand` 32KB limit, base64 loader + stdin trick, host-key churn on PXE reimage, BatchMode + per-run known_hosts, PAT auth for the worker-images `pools.yml` pull) | `references/remote-diagnostics-ssh.md` | Writing a new SSH-driven script against the fleet, or an existing one is hanging / returning empty / failing on host-key changes. |
| Disambiguating hardware regression vs code regression vs environmental/runtime config change vs Defender-flip — the §3k–§3q reasoning chain from RELOPS-2396, what evidence rules each one in or out | `references/perf-debug-investigation-playbook.md` | A SP3 regression is on the table and the next step is deciding which subsystem owns the investigation. Read this BEFORE concluding "hardware" or "code" from a single signal. |

## Fleet at a glance

- ~160 NUC13 nodes (Intel i5-1340P, Raptor Lake; 16 logical / 12 physical cores;
  base 1900 MHz). Hostnames `nuc13-001` … `nuc13-160`, FQDN suffix
  `.wintest2.releng.mdc1.mozilla.com`. Racks IT46 / IT47 at MDC1.
- Six `win11-64-24h2-hw*` worker types share the same NUC13 hardware class but
  differ in pool membership, image pin, and ronin_puppet branch/hash:
  `win11-64-24h2-hw` (MAIN), `…-hw-alpha` (quarantine / poorly-performing /
  validation), `…-hw-perf-debug` (small reference set, currently 024/059/119 as
  of 2026-06-12), `…-hw-ref`, `…-hw-perf-sheriff`, `…-hw-relops1213`.
  See `references/fleet-topology.md` for full topology and the worker-type ↔
  role-name mapping.
- BIOS / firmware pinned in hiera under `windows.bios.NUC13` and applied by
  `modules/win_bios/manifests/nuc13.pp`. Aggressive fan curve was rolled out
  fleet-wide ~2026-03 (had little perf effect, see RELOPS-2323 timeline).
- t-nuc12 nodes share the same MDC1 datacenter but are a separate hardware
  class and a separate FQDN root (`t-nuc12-NNN.wintest2…`). They are NOT in
  scope for fleet-wide NUC13 conclusions; they're the natural "same DC, other
  hardware" control group (used to rule out facility-wide power/cooling events).
- Hardware-vs-cloud detection is via custom fact `custom_win_location ==
  'datacenter'` (`modules/win_shared/facts.d/facts_win_location.ps1`). All this
  skill cares about is the datacenter branch.

## Common starting points

Short triage links by symptom — each forwards to the right reference. None of
these should be answered from this file alone.

- **"Node X is slow / scoring low on SP3"** — first check whether it's actually
  the hardware: pull a current `fleetbench cpu --mode quick --duration 900s
  --json` envelope and read against the classifier. See
  `references/psu-fleetbench-detection.md` §"Classifier" and the
  `scripts/fleetbench-classify.ps1` helper.
- **"Fleet-wide SP3 step / Perfherder alert on `win11-64-24h2-hw*`"** — do NOT
  start from the throttle-event count. Walk the hardware-vs-code-vs-environment
  ladder in `references/perf-debug-investigation-playbook.md`. The June-10 /
  Perfherder alert #50783 / NaR Jun-1 worked-example is in §"Worked example".
- **"Lots of Event 37 in Papertrail since <date>"** — that's almost always a
  retention/query-cap artifact rather than a true onset; read
  `references/throttle-event-analysis.md` §"Papertrail mining" and the
  "shippable vs NaR" pitfall. Confirm with the per-host Event 37 count from
  the System log directly (see `scripts/check-throttle-events.ps1`).
- **"Need to validate a PSU swap"** — see
  `references/psu-fleetbench-detection.md` §"PSU swap validation"; the
  canonical post-swap signature is fleetbench GOOD (min ≥ 75% base, tput CV
  ≤ 25%, mean ≥ 100%) plus 7-day Event 37 P11+P15 returning to
  alpha/non-production rates.
- **"Need to move a node between pools"** — that's a `worker-images`
  `provisioners/windows/MDC1Windows/pools.yml` edit, not ronin_puppet. See
  `references/fleet-topology.md` §"Pool moves" for the exact procedure
  (direct-to-main is the established pattern; bump only the pool you intend
  to change).
- **"WdFilter is still running on `nuc13-XXX` and the schtask says it's
  disabled"** — the .sys rename is next-boot only; Tamper Protection blocks
  `fltmc unload`; read `references/defender-realtime-disable.md` §"Boot race"
  and §"Tamper-on lever inventory".
- **"My SSH-driven probe hangs / returns empty / fails after reimage"** — the
  combination of `pools.yml` PAT auth, host-key churn on PXE reimage, the
  32KB `-EncodedCommand` limit, and Windows OpenSSH stdin buffering is in
  `references/remote-diagnostics-ssh.md` §"Transport patterns". The stdin-
  loader pattern in `StressXperf.ps1` is documented there as a known
  unreliable workaround.
- **"Is RELOPS-2402 done?"** — the detector (fleetbench + maintain-script
  cadence + NSClient → Marlin) is live; thresholds / pool wiring covered in
  `references/psu-fleetbench-detection.md`. Watch items (retention of result
  files, auto-quarantine on sustained BAD, combined CPU+GPU torture for SP3
  parity) are open per RELOPS-2396 worklog §3m and §4.
