# Start one bevy_client connected to a locally running umbrella server.
#
# Usage (from repo root):
#   powershell.exe -ExecutionPolicy Bypass -File scripts/dev-client.ps1
#
# Common variants:
#   ... -Username alice            # auto-login as alice (needs DEV_AUTO_LOGIN=true on server)
#   ... -Stdio                     # run in stdio control mode (scriptable; no window)
#   ... -Release                   # use release build (faster; requires `cargo build --release` once)
#   ... -SkipBuild                 # don't run `cargo build` before launching
#   ... -GateAddr 127.0.0.1:29000 -AuthAddr http://127.0.0.1:4000
#   ... -ObserveLog .demo/client.observe.log

[CmdletBinding()]
param(
  [string]$Username = "dev_user",
  [switch]$Stdio,
  [switch]$Release,
  [switch]$SkipBuild,
  [string]$GateAddr = "127.0.0.1:29000",
  [string]$AuthAddr = "http://127.0.0.1:4000",
  [string]$ObserveLog,
  [string]$Script,
  [double]$MovementSpeed,
  [int]$MoveIntervalMs
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$clientRoot = Join-Path $repoRoot "clients\bevy_client"

if (-not (Test-Path $clientRoot)) {
  throw "bevy_client directory not found at $clientRoot"
}

Push-Location $clientRoot

try {
  if (-not $SkipBuild) {
    Write-Host "==> cargo build" -ForegroundColor Cyan
    if ($Release) {
      cargo build --release
    }
    else {
      cargo build
    }
    if ($LASTEXITCODE -ne 0) { throw "cargo build failed" }
  }

  $buildProfile = if ($Release) { "release" } else { "debug" }
  $exe = Join-Path $clientRoot "target\$buildProfile\bevy_client.exe"
  if (-not (Test-Path $exe)) {
    throw "client exe not found at $exe (did the build succeed? try without -SkipBuild)"
  }

  # --- env vars the bevy_client reads at startup (see clients/bevy_client/src/config.rs)
  $env:BEVY_CLIENT_GATE_ADDR = $GateAddr
  $env:BEVY_CLIENT_AUTH_ADDR = $AuthAddr
  if ($ObserveLog) { $env:BEVY_CLIENT_OBSERVE_LOG = $ObserveLog }
  if ($PSBoundParameters.ContainsKey("MovementSpeed")) {
    $env:BEVY_CLIENT_SPEED = "$MovementSpeed"
  }
  if ($PSBoundParameters.ContainsKey("MoveIntervalMs")) {
    $env:BEVY_CLIENT_MOVE_INTERVAL_MS = "$MoveIntervalMs"
  }

  # --- command line
  $argsList = @()
  if ($Username) { $argsList += @("--username", $Username) }
  if ($Stdio) { $argsList += "--stdio" }
  if ($Script) { $argsList += @("--script", $Script) }

  Write-Host ""
  Write-Host "==> Launching $exe" -ForegroundColor Green
  Write-Host "    gate=$GateAddr  auth=$AuthAddr  username=$Username  stdio=$Stdio" -ForegroundColor DarkGray
  if ($ObserveLog) {
    Write-Host "    observe log: $ObserveLog" -ForegroundColor DarkGray
  }
  Write-Host ""

  & $exe @argsList
  exit $LASTEXITCODE
}
finally {
  Pop-Location
}
