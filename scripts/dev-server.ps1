# Start the full umbrella server stack (auth + gate + scene + world + beacon +
# data_service + visualize) in one interactive iex session.
#
# Usage (from repo root):
#   powershell.exe -ExecutionPolicy Bypass -File scripts/dev-server.ps1
#
# Common variants:
#   ... -SkipBuild            # skip `mix deps.get` + `mix compile`
#   ... -SkipMigrate          # skip `mix ecto.migrate`
#   ... -NoVsDevCmd           # don't source VsDevCmd (assume env already set)
#   ... -NodeName foo@127.0.0.1 -Cookie mmo
#   ... -GateTcpPort 29000 -GateUdpPort 29001 -AuthPort 4000 -VisualizePort 4001

[CmdletBinding()]
param(
  [switch]$SkipBuild,
  [switch]$SkipMigrate,
  [switch]$NoVsDevCmd,
  [switch]$DisableDevAutoLogin,
  [string]$NodeName = "dev@127.0.0.1",
  [string]$Cookie = "mmo",
  [int]$GateTcpPort = 29000,
  [int]$GateUdpPort = 29001,
  [int]$AuthPort = 4000,
  [int]$VisualizePort = 4001,
  [string]$DbHost = $env:MMO_DB_HOST,
  [string]$DbName = $env:MMO_DB_NAME,
  [string]$DbUser = $env:MMO_DB_USER,
  [string]$DbPassword = $env:MMO_DB_PASSWORD
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
Push-Location $repoRoot

function Find-VsDevCmd {
  $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
  if (Test-Path $vswhere) {
    $installPath = & $vswhere -latest -products * -property installationPath 2>$null
    if ($installPath -and (Test-Path "$installPath\Common7\Tools\VsDevCmd.bat")) {
      return "$installPath\Common7\Tools\VsDevCmd.bat"
    }
  }

  $candidates = @(
    "${env:ProgramFiles}\Microsoft Visual Studio\2022\Community\Common7\Tools\VsDevCmd.bat",
    "${env:ProgramFiles}\Microsoft Visual Studio\2022\Professional\Common7\Tools\VsDevCmd.bat",
    "${env:ProgramFiles}\Microsoft Visual Studio\2022\Enterprise\Common7\Tools\VsDevCmd.bat",
    "${env:ProgramFiles}\Microsoft Visual Studio\2022\BuildTools\Common7\Tools\VsDevCmd.bat"
  )
  foreach ($c in $candidates) {
    if (Test-Path $c) { return $c }
  }

  return $null
}

function Import-VsDevCmdEnv {
  param([string]$VsDevCmdPath)

  Write-Host "==> Sourcing VsDevCmd into PowerShell env: $VsDevCmdPath" -ForegroundColor Cyan

  $tmp = [System.IO.Path]::GetTempFileName()
  try {
    cmd /c "`"$VsDevCmdPath`" -arch=x64 >NUL && set > `"$tmp`""
    if ($LASTEXITCODE -ne 0) { throw "VsDevCmd.bat failed with exit code $LASTEXITCODE" }

    Get-Content $tmp | ForEach-Object {
      if ($_ -match "^([^=]+)=(.*)$") {
        [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], "Process")
      }
    }
  }
  finally {
    Remove-Item $tmp -ErrorAction SilentlyContinue
  }
}

try {
  if (-not $NoVsDevCmd) {
    $vsDevCmd = Find-VsDevCmd
    if ($vsDevCmd) {
      Import-VsDevCmdEnv -VsDevCmdPath $vsDevCmd
    }
    else {
      Write-Warning "VsDevCmd.bat not found; continuing without it. Pass -NoVsDevCmd to silence this warning, or install VS Build Tools if NIF / bcrypt_elixir compilation fails."
    }
  }

  # --- Hex / Phoenix / gate / DB env vars (Process scope only)
  $env:HEX_HTTP_CONCURRENCY = "1"
  $env:HEX_HTTP_TIMEOUT = "120"
  $env:PHX_SERVER = "true"
  if (-not $DisableDevAutoLogin) { $env:DEV_AUTO_LOGIN = "true" }

  $env:GATE_TCP_PORT = "$GateTcpPort"
  $env:GATE_UDP_PORT = "$GateUdpPort"
  $env:AUTH_PORT = "$AuthPort"
  $env:VISUALIZE_PORT = "$VisualizePort"

  if ($DbHost) { $env:MMO_DB_HOST = $DbHost }
  if ($DbName) { $env:MMO_DB_NAME = $DbName }
  if ($DbUser) { $env:MMO_DB_USER = $DbUser }
  if ($DbPassword) { $env:MMO_DB_PASSWORD = $DbPassword }

  if (-not $SkipBuild) {
    Write-Host "==> mix deps.get" -ForegroundColor Cyan
    cmd /c "mix deps.get"
    if ($LASTEXITCODE -ne 0) { throw "mix deps.get failed" }

    Write-Host "==> mix compile" -ForegroundColor Cyan
    cmd /c "mix compile"
    if ($LASTEXITCODE -ne 0) { throw "mix compile failed" }
  }

  if (-not $SkipMigrate) {
    Write-Host "==> mix ecto.migrate -r DataService.Repo" -ForegroundColor Cyan
    cmd /c "mix ecto.migrate -r DataService.Repo"
    if ($LASTEXITCODE -ne 0) {
      Write-Warning "ecto.migrate failed. If the DB isn't running you can re-run with -SkipMigrate."
      throw "mix ecto.migrate failed"
    }
  }

  Write-Host ""
  Write-Host "==> Starting iex --name $NodeName --cookie $Cookie -S mix" -ForegroundColor Green
  Write-Host "    gate tcp=$GateTcpPort  udp=$GateUdpPort" -ForegroundColor DarkGray
  Write-Host "    auth http=$AuthPort     visualize http=$VisualizePort" -ForegroundColor DarkGray
  Write-Host "    ctrl-c twice to stop."
  Write-Host ""

  # Hand the current console off to iex so the user can talk to it interactively.
  cmd /c "iex --name $NodeName --cookie $Cookie -S mix"
  exit $LASTEXITCODE
}
finally {
  Pop-Location
}
