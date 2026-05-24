$ErrorActionPreference = "Stop"

Write-Host "[browser-movement-smoke] node scripts/run_browser_movement_smoke_supervised.js"

$RepoRoot = Split-Path -Parent $PSScriptRoot
Push-Location $RepoRoot
try {
  node scripts/run_browser_movement_smoke_supervised.js
  if ($LASTEXITCODE -ne 0) {
    throw "run_browser_movement_smoke_supervised.js exited with code $LASTEXITCODE"
  }
}
finally {
  Pop-Location
}
