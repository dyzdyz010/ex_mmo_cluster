# Movement sync smoke test runner (Windows).
#
# Exercises the in-process end-to-end path
#   client -> PlayerCharacter (real GenServer + movement timer) -> AoiItem -> back
# against the scenarios the rubber-band fix was designed to address.
#
# Run from the repo root:
#   powershell.exe -ExecutionPolicy Bypass -File scripts/smoke-movement.ps1

param(
  [switch]$NoBuild
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
Push-Location (Join-Path $repoRoot "apps/scene_server")

try {
  if (-not $NoBuild) {
    Write-Host "==> Ensuring deps & compiled" -ForegroundColor Cyan
    cmd /c "set HEX_HTTP_CONCURRENCY=1&& set HEX_HTTP_TIMEOUT=120&& mix deps.get"
    if ($LASTEXITCODE -ne 0) { throw "mix deps.get failed" }
    cmd /c "mix compile"
    if ($LASTEXITCODE -ne 0) { throw "mix compile failed" }
  }

  Write-Host "==> Running movement smoke (--only smoke --no-start)" -ForegroundColor Cyan
  cmd /c "mix test --only smoke --no-start test/smoke/movement_smoke_test.exs"

  if ($LASTEXITCODE -ne 0) {
    throw "Movement smoke failed with exit code $LASTEXITCODE"
  }

  Write-Host ""
  Write-Host "Movement smoke PASSED." -ForegroundColor Green
}
finally {
  Pop-Location
}
