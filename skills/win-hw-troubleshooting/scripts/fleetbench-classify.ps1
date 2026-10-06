# fleetbench-classify.ps1
# Classify a fleetbench cpu envelope (JSON) per the RELOPS-2402 NUC13 thresholds.
# Self-contained — paste into an SSH session OR pass -Path for local file.
#
# Thresholds (NUC13 i5-1340P, locked per RELOPS-2396 §3i; mirror of
# Get-FleetbenchVerdict in modules/win_scheduled_tasks/files/maintainsystem-hw.ps1):
#   GOOD     = MinPct  >= 75  AND TputCV <= 25  AND MeanPct >= 100
#   BAD      = MinPct  <  50  OR  TputCV >  40  OR  MeanPct <  95
#   MARGINAL = everything else (in practice empty on NUC13 — distribution is bimodal)
#
# The single best discriminator is MinPct (the frequency floor). Some degraded
# nodes have near-good mean/CV but a clearly bad floor. Read floor first.
#
# Authoritative thresholds live in
#   modules/win_fleetbench/files/fleetbench_baselines.json
# keyed by hardware type. THIS SCRIPT HARDCODES THE NUC13 VALUES — if the
# baselines file is updated for new hardware, update here too OR read JSON.

[CmdletBinding(DefaultParameterSetName='Path')]
param(
    [Parameter(ParameterSetName='Path', Mandatory)]      [string]$Path,
    [Parameter(ParameterSetName='Stdin', Mandatory)]     [switch]$FromStdin,
    [Parameter(ParameterSetName='InMemory', Mandatory)]  [string]$Json
)

# ---- thresholds (NUC13 i5-1340P, base 1900 MHz) -----------------------------
$NUC13_MIN_GOOD = 75   # MinPct >= this => GOOD condition met
$NUC13_MIN_BAD  = 50   # MinPct <  this => BAD
$NUC13_MEAN_GOOD = 100 # MeanPct >= this => GOOD condition met
$NUC13_MEAN_BAD  = 95  # MeanPct <  this => BAD
$NUC13_CV_GOOD   = 25  # TputCV <= this => GOOD condition met
$NUC13_CV_BAD    = 40  # TputCV >  this => BAD
$BASE_MHZ        = 1900

# ---- input loading ----------------------------------------------------------
if ($FromStdin) {
    $raw = [Console]::In.ReadToEnd()
} elseif ($PSCmdlet.ParameterSetName -eq 'Path') {
    $raw = Get-Content -LiteralPath $Path -Raw
} else {
    $raw = $Json
}
$env = $raw | ConvertFrom-Json

# ---- metric extraction (mirrors Get-FleetbenchMetrics) ----------------------
# frequency_series is per-core samples in "% of base clock" (the Windows PDH
# counter \Processor Information(*)\% Processor Performance, 100 == base).
$freq = @($env.frequency_series | ForEach-Object { $_.samples } | ForEach-Object { $_ })
if ($freq.Count -eq 0) {
    Write-Error "envelope has no frequency_series samples — not a fleetbench cpu envelope, or 'inspect' mode"
    exit 2
}
$minPct  = ($freq | Measure-Object -Minimum).Minimum
$meanPct = [math]::Round((($freq | Measure-Object -Average).Average), 2)

# Per-iteration throughput CV (coefficient of variation of seconds-per-iter, ×100)
$iters = @($env.results.prime_sieve_mt.iterations | ForEach-Object { [double]$_.seconds })
if ($iters.Count -lt 2) {
    Write-Error "envelope has <2 iterations — too short to compute throughput CV"
    exit 2
}
$mean = ($iters | Measure-Object -Average).Average
$sd   = [math]::Sqrt((($iters | ForEach-Object { ($_ - $mean) * ($_ - $mean) } | Measure-Object -Sum).Sum) / ($iters.Count - 1))
$tputCV = [math]::Round(100 * $sd / $mean, 2)
$iterCount = $iters.Count

# Per-iteration max/median (logged for context, not classifier input)
$sorted = $iters | Sort-Object
$median = $sorted[[int]($sorted.Count / 2)]
$maxMed = [math]::Round((($iters | Measure-Object -Maximum).Maximum) / $median, 2)

# ---- classification ---------------------------------------------------------
$reasons = @()
$good = ($minPct -ge $NUC13_MIN_GOOD) -and ($tputCV -le $NUC13_CV_GOOD) -and ($meanPct -ge $NUC13_MEAN_GOOD)
$bad  = ($minPct -lt $NUC13_MIN_BAD)  -or  ($tputCV -gt $NUC13_CV_BAD)  -or  ($meanPct -lt $NUC13_MEAN_BAD)
if ($bad)      { $verdict = 'BAD' }
elseif ($good) { $verdict = 'GOOD' }
else           { $verdict = 'MARGINAL' }
if ($minPct  -lt $NUC13_MIN_BAD)  { $reasons += "min<$NUC13_MIN_BAD%base" }
if ($tputCV  -gt $NUC13_CV_BAD)   { $reasons += "tputCV>$NUC13_CV_BAD%" }
if ($meanPct -lt $NUC13_MEAN_BAD) { $reasons += "mean<$NUC13_MEAN_BAD%base" }

# ---- output ---------------------------------------------------------------
[pscustomobject]@{
    Host       = $env.host.name
    Model      = $env.host.model
    Verdict    = $verdict
    MinPct     = $minPct
    MeanPct    = $meanPct
    TputCV     = $tputCV
    Iterations = $iterCount
    MaxMedian  = $maxMed
    BaseMHz    = $BASE_MHZ
    Reasons    = ($reasons -join ',')
} | Format-List
