Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Host "[browser-combustion-field-smoke] node scripts/run_browser_combustion_field_smoke_supervised.js"

Push-Location (Join-Path $PSScriptRoot "..")
try {
  node scripts/run_browser_combustion_field_smoke_supervised.js
  if ($LASTEXITCODE -ne 0) {
    throw "run_browser_combustion_field_smoke_supervised.js exited with code $LASTEXITCODE"
  }
} finally {
  Pop-Location
}
