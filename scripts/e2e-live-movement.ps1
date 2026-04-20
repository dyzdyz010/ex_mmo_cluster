param(
  [string]$Username = "e2e_live",
  [string]$GateAddr = "127.0.0.1:29000",
  [string]$AuthAddr = "http://127.0.0.1:4000",
  [string]$ObserveDir = ".demo/e2e-live",
  [double]$DriftTolerance = 8.0
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$observeDirAbs = Join-Path $repoRoot $ObserveDir
New-Item -ItemType Directory -Force -Path $observeDirAbs | Out-Null

$clientExe = Join-Path $repoRoot "clients\bevy_client\target\debug\bevy_client.exe"
if (-not (Test-Path $clientExe)) {
  throw "bevy_client.exe not found at $clientExe (run: cargo build --bin bevy_client inside clients/bevy_client)"
}

$clientOut = Join-Path $observeDirAbs "client-stdio.out.log"
$clientErr = Join-Path $observeDirAbs "client-stdio.err.log"
$clientObserve = Join-Path $observeDirAbs "client-observe.log"
Remove-Item $clientOut,$clientErr,$clientObserve -ErrorAction SilentlyContinue

# Prepare a scripted stdin sequence that exercises:
#   - initial snapshot (sanity after scene join)
#   - four direction bursts (w/d/s/a), each 600 ms
#   - between each move, one reconcile_stats + diag_render sample
#   - one long run (1500 ms) to force multi-tick replay
#   - final position + snapshot before quit
$commands = @(
  "snapshot",
  "transport",
  "reconcile_stats",
  "diag_render",
  "move w 600",
  "reconcile_stats",
  "diag_render",
  "move d 600",
  "reconcile_stats",
  "diag_render",
  "move s 600",
  "reconcile_stats",
  "diag_render",
  "move a 600",
  "reconcile_stats",
  "diag_render",
  "move d 1500",
  "reconcile_stats",
  "diag_render",
  "stop",
  "reconcile_stats",
  "diag_render",
  "position",
  "snapshot",
  "quit"
)

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $clientExe
$psi.WorkingDirectory = Join-Path $repoRoot "clients\bevy_client"
$psi.Arguments = "--headless --stdio --username $Username --wait-for-scene-ms 20000"
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.Environment["BEVY_CLIENT_GATE_ADDR"] = $GateAddr
$psi.Environment["BEVY_CLIENT_AUTH_ADDR"] = $AuthAddr
$psi.Environment["BEVY_CLIENT_OBSERVE_LOG"] = $clientObserve

$client = New-Object System.Diagnostics.Process
$client.StartInfo = $psi
$client.Start() | Out-Null

$sw = [Diagnostics.Stopwatch]::StartNew()

# Wait up to 25s for scene_ready observe event before driving commands
$sceneReadyDeadline = (Get-Date).AddSeconds(25)
while ((Get-Date) -lt $sceneReadyDeadline) {
  if ((Test-Path $clientObserve) -and ((Get-Content $clientObserve -Raw) -match 'event="scene_ready"')) {
    break
  }
  Start-Sleep -Milliseconds 250
}

foreach ($cmd in $commands) {
  $client.StandardInput.WriteLine($cmd)
  $client.StandardInput.Flush()
  # Pace commands to give sim time to advance between samples
  if ($cmd -like "move *") {
    $parts = $cmd -split ' '
    $ms = [int]$parts[2]
    Start-Sleep -Milliseconds ($ms + 300)
  } else {
    Start-Sleep -Milliseconds 150
  }
}

$client.StandardInput.Close()
$client.WaitForExit(30000) | Out-Null
$sw.Stop()

$clientStdout = $client.StandardOutput.ReadToEnd()
$clientStderr = $client.StandardError.ReadToEnd()
Set-Content $clientOut $clientStdout
Set-Content $clientErr $clientStderr

# Required patterns — scene join, transport, at least one reconcile_stats with counters
$requiredPatterns = @(
  'client_stdio event="snapshot".*scene_joined="true"',
  'client_stdio event="transport".*movement_transport=',
  'client_stdio event="reconcile_stats".*total_corrections=',
  'client_stdio event="diag_render".*',
  'client_stdio event="move_done".*local_position=',
  'client_stdio event="position".*local_position=',
  'client_stdio event="quit".*final_status='
)
foreach ($pattern in $requiredPatterns) {
  if ($clientStdout -notmatch $pattern) {
    throw "client stdio missing expected pattern: $pattern"
  }
}

# Parse reconcile_stats counters (last sample)
$reconcileMatches = [regex]::Matches(
  $clientStdout,
  'client_stdio event="reconcile_stats" total_corrections="(?<tc>\d+)" total_replays="(?<tr>\d+)" total_hard_snaps="(?<ths>\d+)" total_window_trims="(?<twt>\d+)" last_replayed_frames="(?<lrf>\d+)" last_pending_inputs="(?<lpi>\d+)" last_correction_distance="(?<lcd>[\d\.]+)"'
)
if ($reconcileMatches.Count -eq 0) {
  throw "reconcile_stats output did not match expected schema"
}

$lastRec = $reconcileMatches[$reconcileMatches.Count - 1].Groups
$hardSnaps = [int]$lastRec["ths"].Value
$totalReplays = [int]$lastRec["tr"].Value
$totalCorrections = [int]$lastRec["tc"].Value
$lastCorrectionDistance = [double]$lastRec["lcd"].Value

if ($hardSnaps -ne 0) {
  throw "unexpected hard-snap count after routine movement E2E: $hardSnaps (should be 0 under normal drift)"
}

if ($lastCorrectionDistance -gt $DriftTolerance) {
  throw "final correction_distance too large: $lastCorrectionDistance > $DriftTolerance"
}

# Parse final local_position
$positionMatches = [regex]::Matches(
  $clientStdout,
  'client_stdio event="position" local_position="(?<pos>[-0-9\.,]+|n/a)"'
)
if ($positionMatches.Count -eq 0) {
  throw "no position samples captured from stdio output"
}
$finalPos = $positionMatches[$positionMatches.Count - 1].Groups["pos"].Value

Write-Host ""
Write-Host "=============================================="
Write-Host "E2E LIVE MOVEMENT (real TCP link) PASSED"
Write-Host "=============================================="
Write-Host "Elapsed:                      $($sw.Elapsed.TotalSeconds)s"
Write-Host "Total reconcile corrections:  $totalCorrections"
Write-Host "Total replays:                $totalReplays"
Write-Host "Total hard_snaps:             $hardSnaps  (expected 0)"
Write-Host "Last correction_distance:     $lastCorrectionDistance  (tol $DriftTolerance)"
Write-Host "Final local_position:         $finalPos"
Write-Host "Client stdout log:            $clientOut"
Write-Host "Client observe log:           $clientObserve"
Write-Host ""
Write-Host "--- LAST CLIENT STDIO LINES ---"
$clientStdout -split "`r?`n" | Select-String 'client_stdio' | Select-Object -Last 30 | ForEach-Object { $_.Line }
