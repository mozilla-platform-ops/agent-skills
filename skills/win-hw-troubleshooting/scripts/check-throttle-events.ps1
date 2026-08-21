# check-throttle-events.ps1
# Count Microsoft-Windows-Kernel-Processor-Power Event 37 ("limited by system
# firmware") since LastBootUpTime on a single NUC. Self-contained, runnable
# over SSH.
#
# Emits a single JSON line on stdout suitable for collection by an outer
# fleet-walker. Returns counts per-processor with P11+P15 highlighted (the
# canonical NUC13 throttle pair — see references/throttle-event-analysis.md
# §"P11/P15 symmetry").
#
# Usage (single node, SSH):
#   ssh -o BatchMode=yes -o LogLevel=ERROR \
#       -o UserKnownHostsFile=$(mktemp) -o StrictHostKeyChecking=accept-new \
#       administrator@nuc13-024.wintest2.releng.mdc1.mozilla.com \
#       powershell -NoProfile -EncodedCommand $(base64 < check-throttle-events.ps1)
#
# Usage (last 7 days, ignoring LastBootUpTime):
#   .\check-throttle-events.ps1 -DaysBack 7
#
# Usage (specific window):
#   .\check-throttle-events.ps1 -StartTime '2026-06-04T00:00:00Z'
#
# Thresholds for orientation (from cpu_audit.ps1, see
# references/throttle-event-analysis.md):
#   Good baseline:  NUC13-049 (historical) = 35.35 P11+P15 events / 7 days
#   Bad baseline:   NUC13-066 (historical) = 255.34 P11+P15 events / 7 days
#   BAD threshold:  >= 145.35 P11+P15 events / 7 days (midpoint)
# Always normalize to per-day before comparing across nodes with different
# uptimes or lookback windows.

[CmdletBinding(DefaultParameterSetName='SinceBoot')]
param(
    [Parameter(ParameterSetName='SinceBoot')]
        [switch]$SinceBoot,
    [Parameter(ParameterSetName='DaysBack', Mandatory)]
        [int]$DaysBack,
    [Parameter(ParameterSetName='AtTime', Mandatory)]
        [datetime]$StartTime,
    [int]$EventId = 37
)

# ---- resolve start window ---------------------------------------------------
if ($PSCmdlet.ParameterSetName -eq 'DaysBack') {
    $start = (Get-Date).AddDays(-$DaysBack)
    $windowKind = "$DaysBack`d"
} elseif ($PSCmdlet.ParameterSetName -eq 'AtTime') {
    $start = $StartTime
    $windowKind = "from $($StartTime.ToString('s'))Z"
} else {
    $start = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    $windowKind = "since boot"
}

# ---- query the System log via the indexed filter (fast) --------------------
# Provider name MUST be exact: Microsoft-Windows-Kernel-Processor-Power.
# The unrelated provider Microsoft-Windows-Kernel-Power (no "Processor") covers
# ACPI / battery events and is the wrong source for CPU throttle.
$evts = @()
try {
    $evts = Get-WinEvent -FilterHashtable @{
        LogName      = 'System'
        ProviderName = 'Microsoft-Windows-Kernel-Processor-Power'
        Id           = $EventId
        StartTime    = $start
    } -ErrorAction Stop
} catch {
    # Get-WinEvent throws on zero matches in some Windows versions
    if ($_.Exception.Message -notmatch 'No events were found') { throw }
}

# ---- bucket by processor index ---------------------------------------------
# Event 37's Properties[0] is the processor index as uint32. P11 and P15 are
# the NUC13 i5-1340P throttle pair; they fire symmetrically (RELOPS-2396 §3l).
$byProc = @{}
foreach ($e in $evts) {
    $p = [int]$e.Properties[0].Value
    if (-not $byProc.ContainsKey($p)) { $byProc[$p] = 0 }
    $byProc[$p]++
}
$p11 = if ($byProc.ContainsKey(11)) { $byProc[11] } else { 0 }
$p15 = if ($byProc.ContainsKey(15)) { $byProc[15] } else { 0 }

# ---- emit one JSON line ----------------------------------------------------
$now = Get-Date
$hours = [math]::Round(($now - $start).TotalHours, 2)
$out = [ordered]@{
    host         = $env:COMPUTERNAME
    lastBoot     = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString('s')
    windowStart  = $start.ToString('s')
    windowHours  = $hours
    windowKind   = $windowKind
    eventId      = $EventId
    totalAll     = ($evts | Measure-Object).Count
    p11          = $p11
    p15          = $p15
    p11_plus_p15 = $p11 + $p15
    byProcessor  = $byProc
}
$out | ConvertTo-Json -Compress -Depth 4
