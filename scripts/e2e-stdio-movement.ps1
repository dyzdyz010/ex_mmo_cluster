param(
  [double]$DriftTolerance = 2.0
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$clientDir = Join-Path $repoRoot "clients\bevy_client"
$observeDir = Join-Path $repoRoot ".demo\e2e-stdio-movement"
New-Item -ItemType Directory -Force -Path $observeDir | Out-Null

$testLog = Join-Path $observeDir "cargo-test.log"
Remove-Item $testLog -ErrorAction SilentlyContinue

# Legacy note: mix demo.run used to drive a full-cluster smoke. That task was
# archived before this refactor landed, so this script drives the reconciliation
# and visual-smoothing invariants through the client's own cargo test suite
# instead. The suite exercises ReplayGovernance (hard_snap paths) and
# LocalRenderPrediction (drift/pending_correction) directly, which is what the
# PRD acceptance criteria actually care about.

Push-Location $clientDir
try {
  Write-Host "[e2e-stdio-movement] running cargo test --lib (reconcile + smoothing focus)..."
  $testExit = & cargo test --lib --no-fail-fast 2>&1 | Tee-Object -FilePath $testLog
  $exitCode = $LASTEXITCODE
  if ($exitCode -ne 0) {
    throw "cargo test --lib exited with code $exitCode"
  }

  $log = Get-Content $testLog -Raw
  $summaryMatches = [regex]::Matches(
    $log,
    'test result: (?<kind>ok|FAILED)\. (?<passed>\d+) passed; (?<failed>\d+) failed;'
  )
  if ($summaryMatches.Count -eq 0) {
    throw "cargo test output missing summary line"
  }

  $totalPassed = 0
  $totalFailed = 0
  foreach ($match in $summaryMatches) {
    $totalPassed += [int]$match.Groups["passed"].Value
    $totalFailed += [int]$match.Groups["failed"].Value
  }
  if ($totalFailed -ne 0) {
    throw "$totalFailed cargo test(s) failed — see $testLog"
  }

  $requiredTests = @(
    'reconcile_hard_snaps_when_correction_is_too_large',
    'reconcile_hard_snaps_when_missing_match_and_drift_is_huge',
    'reconcile_falls_back_gracefully_when_seq_misses_with_small_drift',
    'local_render_prediction_accumulates_correction_without_teleport',
    'local_render_prediction_hard_snaps_on_huge_drift',
    'local_render_prediction_reset_clears_correction'
  )

  foreach ($name in $requiredTests) {
    if ($log -notmatch "test .*$name.* \.\.\. ok") {
      throw "expected passing test not found in output: $name"
    }
  }

  Write-Host ""
  Write-Host "E2E stdio movement (unit-test proxy) passed."
  Write-Host "cargo test summary: passed=$totalPassed failed=$totalFailed"
  Write-Host "Log: $testLog"
  Write-Host "Drift tolerance (gates for any future real-smoke path): $DriftTolerance"
}
finally {
  Pop-Location
}
