$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
Write-Host '[deprecated] run_ws_dual_smoke.ps1 -> node scripts/run_ws_dual_smoke_supervised.js'

Push-Location $root
try {
  node scripts/run_ws_dual_smoke_supervised.js
  exit $LASTEXITCODE
}
finally {
  Pop-Location
}
