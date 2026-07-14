param(
  [ValidateSet("movement-proxy", "live-movement", "ws-dual")]
  [string]$Mode = "movement-proxy",
  [string]$ObserveDir = ".demo/e2e-stdio",
  [int]$BotCount = 1,
  [int]$ServerExitAfter = 24,
  [double]$FinalPositionTolerance = 5.0,
  [string]$Username = "e2e_live",
  [string]$GateAddr = "127.0.0.1:20002",
  [string]$AuthAddr = "http://127.0.0.1:20000"
)

$ErrorActionPreference = "Stop"

throw 'archived_client_default_disabled: this generic E2E wrapper includes archived bevy_client modes and is disabled by default. Active Voxia entry: node clients/Voxia/scripts/voxia_stdio_cli.js --cmd "...". Explicit archived-client work must use its own README.'

$repoRoot = Split-Path -Parent $PSScriptRoot

function Warn-IfCustom {
  param(
    [string]$Name,
    [object]$Value,
    [object]$DefaultValue,
    [string]$Reason
  )

  if ($Value -ne $DefaultValue) {
    Write-Warning "Parameter -$Name is ignored in Mode=${Mode}: $Reason"
  }
}

Write-Warning "scripts/e2e-stdio.ps1 is a compatibility wrapper. The old mix demo.run full-cluster stdio smoke is archived."

switch ($Mode) {
  "movement-proxy" {
    Warn-IfCustom -Name "BotCount" -Value $BotCount -DefaultValue 1 -Reason "movement-proxy runs bevy_client cargo tests, not demo bots."
    Warn-IfCustom -Name "ServerExitAfter" -Value $ServerExitAfter -DefaultValue 24 -Reason "movement-proxy does not start a server process."
    Warn-IfCustom -Name "Username" -Value $Username -DefaultValue "e2e_live" -Reason "movement-proxy does not log in."
    Warn-IfCustom -Name "GateAddr" -Value $GateAddr -DefaultValue "127.0.0.1:20002" -Reason "movement-proxy does not connect to gate."
    Warn-IfCustom -Name "AuthAddr" -Value $AuthAddr -DefaultValue "http://127.0.0.1:20000" -Reason "movement-proxy does not connect to auth."

    & "$PSScriptRoot\e2e-stdio-movement.ps1" `
      -ObserveDir $ObserveDir `
      -DriftTolerance $FinalPositionTolerance
  }

  "live-movement" {
    Warn-IfCustom -Name "BotCount" -Value $BotCount -DefaultValue 1 -Reason "live-movement uses one Bevy headless client against an already-running server."
    Warn-IfCustom -Name "ServerExitAfter" -Value $ServerExitAfter -DefaultValue 24 -Reason "live-movement does not own the server lifecycle."

    & "$PSScriptRoot\e2e-live-movement.ps1" `
      -Username $Username `
      -GateAddr $GateAddr `
      -AuthAddr $AuthAddr `
      -ObserveDir $ObserveDir `
      -DriftTolerance $FinalPositionTolerance
  }

  "ws-dual" {
    Warn-IfCustom -Name "BotCount" -Value $BotCount -DefaultValue 1 -Reason "ws-dual seeds and drives ws_smoke_a/ws_smoke_b."
    Warn-IfCustom -Name "ServerExitAfter" -Value $ServerExitAfter -DefaultValue 24 -Reason "ws-dual has its own supervised timeout."
    Warn-IfCustom -Name "FinalPositionTolerance" -Value $FinalPositionTolerance -DefaultValue 5.0 -Reason "ws-dual validates its own movement summary assertions."
    Warn-IfCustom -Name "Username" -Value $Username -DefaultValue "e2e_live" -Reason "ws-dual seeds and drives ws_smoke_a/ws_smoke_b."
    Warn-IfCustom -Name "GateAddr" -Value $GateAddr -DefaultValue "127.0.0.1:20002" -Reason "ws-dual chooses free ports automatically."
    Warn-IfCustom -Name "AuthAddr" -Value $AuthAddr -DefaultValue "http://127.0.0.1:20000" -Reason "ws-dual chooses free ports automatically."
    Warn-IfCustom -Name "ObserveDir" -Value $ObserveDir -DefaultValue ".demo/e2e-stdio" -Reason "ws-dual writes to .demo/observe."

    Push-Location $repoRoot
    try {
      node scripts/run_ws_dual_smoke_supervised.js
      if ($LASTEXITCODE -ne 0) {
        throw "run_ws_dual_smoke_supervised.js exited with code $LASTEXITCODE"
      }
    }
    finally {
      Pop-Location
    }
  }
}
