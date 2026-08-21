# Remote diagnostics over SSH — Windows OpenSSH, EncodedCommand, host-key churn, PAT auth

The standard way to drive diagnostics on the hw fleet is SSH into each NUC13
and run PowerShell remotely. Every script in `nuc scripts/CLUADE-NUC/` —
`CollectHWInfo.ps1`, `cpu_audit.ps1`, `StressCPU.ps1`, `Compare-NUCHealth.ps1`,
the fleetbench retriggers in `fleetbench-runs-2026-06-08/` — uses some
variation of the same transport. This file documents the patterns, the
pitfalls, and the known-unreliable workarounds, so a new probe script does
not re-discover the same dead ends.

Audience: someone writing a new SSH-driven script, or debugging an existing
one that hangs / returns empty / fails after a reimage.

## Connection basics

The Windows side runs Microsoft's OpenSSH server (`sshd`) installed by
puppet. The client side is whatever you're driving from — typically a
PowerShell or bash shell on the operator workstation. Authentication is
via SSH key (`win_audit_id_rsa` is the standard fleet audit key);
`administrator` is the standard target user.

Standard connection options used across the diagnostic scripts:

```
-o BatchMode=yes
-o LogLevel=ERROR
-o ConnectTimeout=15
-o ServerAliveInterval=30
-o ServerAliveCountMax=3
-o StrictHostKeyChecking=accept-new
-o UserKnownHostsFile=<fresh temp file per run>
```

- **`BatchMode=yes`**: never prompt. Any auth issue → fast fail rather than
  hanging on a password prompt. Required for parallel batches.
- **`LogLevel=ERROR`**: suppress connection chatter so JSON-over-stdout
  parsing isn't polluted. (Without this, the connection banner can leak
  into the output stream depending on Windows OpenSSH version.)
- **`ConnectTimeout=15`** + **`ServerAlive*=30/3`**: lossy WAN paths and
  reimaging nodes need bounded waits. The aggregate keepalive timeout is
  ~90s; pair with a hard process-level timeout of `duration_secs + 90`
  on the outer wrapper (see `StressCPU.ps1` SSH wrapper).
- **`StrictHostKeyChecking=accept-new`** + **fresh temp known_hosts per
  run**: required because of host-key churn on reimage (see below).

## Host-key churn on PXE reimage

Every PXE reimage regenerates the host SSH key. A persistent
`~/.ssh/known_hosts` will trip on `WARNING: REMOTE HOST IDENTIFICATION
HAS CHANGED!` after any reimage and break unattended scripts.

Two stable patterns are in use in the audit scripts:

1. **Per-run temp known_hosts** (`cpu_audit.ps1`, `StressCPU.ps1`):

   ```
   $kh = New-TemporaryFile
   ssh -o UserKnownHostsFile=$kh -o StrictHostKeyChecking=accept-new ...
   Remove-Item $kh
   ```

   Each run starts with a clean known_hosts, accepts whatever key the
   server presents, and discards the file. Best for ad-hoc / batch
   probes; do NOT use for trust-sensitive operations.

2. **Wipe-on-mismatch in a controlled script** — read the current key
   and replace it if changed. More involved; only worth it when a
   per-run temp file isn't acceptable.

Do NOT add nodes to the operator's personal `~/.ssh/known_hosts` during
fleet probes — you'll trip on the next reimage and break the human's
interactive use too.

## Worker-images `pools.yml` fetch (PAT auth)

`CollectHWInfo.ps1`, `cpu_audit.ps1`, and the `maintainsystem-hw.ps1`
`CompareConfigBasic` step all need to read
`worker-images/provisioners/windows/MDC1Windows/pools.yml`. The file is in
a public repo but fetching it reliably with rate-limit headroom requires
a PAT.

- **Operator workstation:** PAT in env / config; pulled via the GitHub raw
  URL or `gh api`.
- **NUC13 nodes themselves:** PAT lives at `D:\Secrets\pat.txt`. This is
  read by `Invoke-DownloadWithRetryGithub` in `maintainsystem-hw.ps1` and
  by the bootstrap layer.
- The retry loop in `Invoke-DownloadWithRetryGithub` is 20 retries with
  exponential backoff. If a node can't fetch pools.yml in 20 retries it
  is genuinely network-isolated; treat as DOWN.

Do not hardcode tokens in scripts. The PAT path on nodes is part of the
expected disk layout; the operator workstation reads from a local
`~/.config/gh` / env / per-user file.

## Payload size limits and the `-EncodedCommand` ceiling

Windows OpenSSH delivers commands via Windows `CreateProcess`, which has
a 32 KB hard cap on the command line. Base64-encoded PS payloads larger
than ~24 KB will fail immediately with cryptic exit codes (the connection
opens, the command fails before reaching PowerShell).

Three transport patterns observed across the scripts (NOTES.md
"StressXperf.ps1 SSH transport issue (2026-05-05)"):

| Pattern | Status | When to use |
|---------|--------|-------------|
| `ssh host "powershell -EncodedCommand <payload-b64>"` direct | Works when payload ≤ ~24 KB base64. | Default for `CollectHWInfo.ps1`, `cpu_audit.ps1`, `StressCPU.ps1` payloads. |
| `ssh host "powershell -"` bare stdin | DOES NOT WORK on PS 5.1 — `-` is not a valid stdin mode on PowerShell 5.1 on Windows. Connects, runs for the full duration, returns empty. | Avoid. |
| `ssh host "powershell -EncodedCommand <loader-b64>"` + script over stdin | The loader is a tiny `Invoke-Expression ([Console]::In.ReadToEnd())` payload (base64 fits in 32 KB easily), and the full script is piped to stdin. | The standard escape hatch for payloads > 24 KB. Used in `StressXperf.ps1` but documented unreliable (see below). |
| `ssh host "powershell -Command 'Invoke-Expression…'" ` with stdin | DOES NOT WORK — embedded `"` in `$psi.Arguments` breaks Windows arg parsing. Connection fails immediately. | Avoid. |

### Stdin loader pattern (known issues)

`StressXperf.ps1`'s ~200-line PS payload is delivered via:

```
$loader = '[Console]::In.ReadToEnd() | Invoke-Expression'
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($loader))
$proc = "ssh $opts $host powershell.exe -NoProfile -EncodedCommand $encoded"
# write the full PS payload to stdin
```

As of 2026-05-05 this connects and runs the remote script for the full
duration but returns **empty output**. Root cause is suspected to be a
timing/buffering interaction between `[Console]::In.ReadToEnd()` and how
Windows OpenSSH forwards stdin in this configuration.

Workarounds that have not yet been validated end-to-end:
- Write the script to a temp file on the node (via `scp` or via a small
  base64-encoded preamble), execute it, then clean up. Two-step.
- Use a smaller payload (drop optional parsing / pretty-print steps).
- Open an async stdin writer *before* attaching async stdout readers.

For now: if your payload is > 24 KB base64, plan for a `scp` + execute
+ cleanup flow rather than fighting the stdin path. The
`fleetbench-runs-2026-06-08/` workflow used this approach successfully
(scp fleetbench binary + run via SSH + scp results back).

## Detecting a busy node before stress

Stress-tests that interfere with running CI tasks will produce bad data
*and* annoy the perf team. `StressCPU.ps1` and `cpu_audit.ps1` check
whether a `task_*` user is logged in before pushing load, using the
same `query user` parse `maintainsystem-hw.ps1` uses:

```
quser | Select-String 'task_'
```

Returning rows → node is busy with a CI task. The scripts then place the
node in a "busy queue" and re-poll every 120s until it drains, after
which the actual probe runs. `StressCPU.ps1` busy loop runs before the
SSH retry loop so busy and SSH-failed nodes don't conflate.

Equivalent check from PS:

```powershell
$busy = (quser 2>$null | Select-String 'task_') -ne $null
```

## Parallelism limits

- **`StressCPU.ps1` batch size: 3.** Higher concurrency saturated the SSH
  stack and produced unreliable returns (NOTES.md "Stress Test" section).
  Three is the documented working ceiling for prime95-style probes.
- **`cpu_audit.ps1` is sequential** by default (passive event-log read);
  parallelism doesn't help much because the bottleneck is per-node
  EventLog query latency, not network.
- **Fleetbench ad-hoc runs (`fleetbench-runs-2026-06-08`): 20 concurrent**
  succeeded on the 70-alpha sweep (~6.5 min for 56 nodes). The lighter
  payload (just invoke a binary) tolerates higher concurrency than the
  embedded-PS pattern of `StressCPU.ps1`.

Tune to the lighter of: SSH stack saturation, network IO, or the
node-side resource the probe stresses.

## Single-node helpers

For interactive ad-hoc debugging, the held-interactive session pattern is
the reliable way to run a 15-min fleetbench torture without it being
interrupted by CI reboots:

```
ssh -o ... administrator@nuc13-024.wintest2.releng.mdc1.mozilla.com
> cd C:\fleetbench
> .\fleetbench-v0.4.0-windows-x86_64.exe cpu --mode quick --duration 900s --json > out.json
> exit
```

The maintain-script will skip its scheduled fleetbench check (cadence
gate) once it sees the manual `*_cpu.json` you wrote — that's intended
behaviour. Just don't leave the file in `C:\fleetbench\results\` if you
want the next post-bootstrap fleetbench to run; manual ad-hoc runs
should write to `C:\Users\administrator\fleetbench-runs\` or similar
out-of-path location.

Main-pool nodes are unreliable for ad-hoc 15-min runs because CI reboots
will interrupt the session. Always prefer a perf-debug pool node
(currently 024/059/119) for ad-hoc fleetbench work.

SYSTEM-context detached execution emits no output (RELOPS-2396 §3i) —
do not try to `Start-Process -Detached` a fleetbench run and expect to
capture stdout later. Use held-interactive or scheduled-task patterns.

## Detecting reimage / freshly-rebooted state

Two facts useful for "is this node in a clean state":

- `(Get-CimInstance Win32_OperatingSystem).LastBootUpTime` — wall-clock
  of last boot. Use as `StartTime` for "since boot" event filters.
- `worker-status.json` (the maintain-script's bookkeeping) — presence
  of `bootstrap_stage == complete` means the boot sequence has run to
  end.
- The host SSH key fingerprint changes on every reimage. If yours
  doesn't match the previous known value, the node has reimaged.

## "When this is NOT the right reference"

- You're driving Linux Moonshots or macOS workers — those use different
  transports (Linux SSH is straightforward; macOS uses MDM + remote
  scripts). None of the Windows-specific gotchas apply.
- You're talking to azure / cloud Windows workers — those expose WinRM
  or generic-worker artifacts, not the persistent SSH listener that
  hardware nodes have.
- You're driving a build / publish step on Taskcluster — that's a
  worker-runner / generic-worker concern, not an operator-driven SSH
  probe.

## Citations

- SSH connection options: `cpu_audit.ps1`, `StressCPU.ps1` SSH wrappers;
  NOTES.md "cpu_audit.ps1" + "StressCPU.ps1".
- Payload size / EncodedCommand limit: NOTES.md "StressXperf.ps1 SSH
  transport issue (2026-05-05)".
- Busy detection (`task_*` user): `StressCPU.ps1` busy-queue handling;
  `maintainsystem-hw.ps1` `quser` parse.
- Per-run known_hosts: `cpu_audit.ps1` transport line.
- PAT location on nodes: `Invoke-DownloadWithRetryGithub` in
  `modules/win_scheduled_tasks/files/maintainsystem-hw.ps1`; NOTES.md
  "maintainsystem-hw.ps1" `D:\Secrets\pat.txt`.
- Held-interactive fleetbench preference: RELOPS-2396 §3i.

## Volatile / dated facts

- **As of 2026-06-08:** the 70-alpha sweep at 20 concurrent ran in
  ~6.5 min. Concurrency ceilings shift with network and OpenSSH version
  drift; re-measure if you're tuning a new probe.
- The PAT format and the GitHub PAT permissioning model have changed in
  the past (fine-grained tokens vs classic). The `D:\Secrets\pat.txt`
  file format is plain text; the *token* itself rotates.

## Structural / durable facts

- Windows `CreateProcess` 32 KB command-line cap is a platform fact.
  Base64-encoded UTF-16-LE doubles the byte count; effective PS payload
  ceiling is ~12 KB of source.
- PXE reimage regenerates the host SSH key. This is a property of the
  image build; no node-side configuration changes it.
- `BatchMode=yes` + `StrictHostKeyChecking=accept-new` + per-run
  known_hosts is the durable parallel-probe transport. Use it as the
  baseline for any new SSH-driven script.
- Held-interactive SSH is the reliable channel for long-running
  diagnostic sessions on this fleet. Detached / SYSTEM execution is not
  reliable for capturing stdout.
